# Architektur — Designentscheidungen + Trade-offs

Dieses Dokument erklärt **warum** wir die Dinge so gebaut haben. Wenn du etwas
ändern willst, lies erst, warum es so ist — sonst trittst du eine alte Mine.

## Übersicht

```
                    ┌─────────────────┐
                    │  Floating-IP    │  ← keepalived (VRRP)
                    │  192.168.x.100  │
                    └────────┬────────┘
                             │
                ┌────────────┴────────────┐
                │                         │
        ┌───────▼────────┐       ┌────────▼───────┐
        │   proxy01      │       │   proxy02      │
        │   MASTER       │◄─────►│   BACKUP       │  VRRP-Heartbeat
        │   prio=100     │       │   prio=90      │
        └───┬──────┬─────┘       └────┬──────┬────┘
            │      │                  │      │
            │      └──── Tailscale ───┘      │  (Cert-Sync, Admin-SSH)
            │                                │
            └────────── Backend-LAN ─────────┘
                          │
                  ┌───────▼────────┐
                  │  pi-hole, NC,  │
                  │  HA, Plex, …   │
                  └────────────────┘
```

## Kern-Entscheidungen

### 1. nginx, nativ — kein Docker

**Entscheidung:** nginx läuft als Distro-Paket direkt auf der VM, nicht im Container.

**Warum:**
- TLS-Termination + VRRP-Floating-IP-Bind funktioniert mit Host-Networking
  zuverlässiger als mit Container-Bridges.
- `certbot --webroot` braucht direkten Filesystem-Zugriff auf `/var/www/letsencrypt`.
  Im Container-Setup wäre das ein zusätzlicher Volume-Mount mit denselben Bind-Mount-
  Risiken wie ohne Container.
- Reload via `systemctl reload nginx` ist ohne Container ein einfacher Signal-Send;
  im Container-Setup würden wir entweder `docker exec` brauchen oder `--restart`
  (was eine Connection-Drop bedeutet).
- Debug auf einer Reverse-Proxy-Node, die Production-Traffic hat, ist kritisch — je
  weniger Layers (Container, Bridge, Overlay) zwischen Problem und Operator, desto
  schneller das Fix.

**Trade-off:** Wir verlieren die Reproducibility eines Docker-Images. Das fangen
wir über das Repo + `nginx -t` im CI ab.

### 2. keepalived/VRRP statt DNS-Round-Robin oder Anycast

**Entscheidung:** Layer-3-VRRP mit einer Floating-IP, die zwischen den Nodes
hüpft (typisch ~1–3 Sekunden Failover).

**Warum:**
- DNS-Round-Robin: Browser-Caching, OS-Resolver-TTL-Verstöße — Failover dauert
  Minuten bis Stunden.
- Anycast: Braucht BGP, das hat unser Heimnetz nicht.
- VRRP: Reines Layer-2-Geschehen, kein DNS-Cache zu warten, transparenter
  Failover für Clients.

**Trade-off:** Beide Nodes müssen im **selben Subnetz** liegen. Standortverteiltes
Active-Active geht damit nicht.

### 3. Symmetrisches Pull-Deployment (statt Master pusht)

**Entscheidung:** Beide Nodes pullen alle 2 Minuten via systemd-Timer aus dem
Repo. Der Dev-Workflow ist `git push` zu GitHub — die Nodes finden Änderungen
selbst.

**Warum:**
- Wenn der Push-orchestrator (z.B. CI-Server, Dev-Rechner) ausfällt oder
  nicht erreichbar ist, deployen die Nodes weiter aktuelle Configs.
- Kein zentraler Push-Account mit Schreibrechten auf beide Nodes.
- Keine "Wer hat zuletzt deployed?"-Konflikte.
- Idempotent — wenn beide Nodes denselben Commit ziehen, ist der Endzustand
  garantiert identisch.

**Trade-off:** 2 Minuten Drift zwischen Push und Wirksamkeit. Für Notfälle
gibt es `Ops → Repo pullen + deployen` (Sofort-Action).

### 4. Cert-Renewal auf MASTER, rsync nach BACKUP

**Entscheidung:** Nur MASTER läuft `certbot renew`. Der `--deploy-hook`
syncht `/etc/letsencrypt/` per rsync via Tailscale-SSH zum BACKUP und
reloaded dort nginx.

**Warum:**
- `http-01`-Challenge lässt sich nur auf der Node durchführen, die gerade die
  Floating-IP hält — und das ist im Normalbetrieb MASTER.
- BACKUP würde bei eigenem `certbot renew` die ACME-Challenge nicht beantworten
  können (keine öffentliche IP).
- Beim Failover hat BACKUP bereits eine valide Cert-Kopie und kann sofort
  TLS terminieren.

**Trade-off:** SSH-Sync via Tailscale braucht symmetrische SSH-Setups (Hostkey
in `known_hosts` beidseitig). Wenn MASTER permanent down ist, müssen wir BACKUP
manuell zu MASTER promovieren (Rolle in `values.env` swappen).

### 5. Statusseite: Flask-App, Cron schreibt Snapshots

**Entscheidung:** `update-site-info.sh` läuft alle 5 Min via Cron als root,
sammelt System-/nginx-/Cert-/Backend-Daten in JSON-Files. Die Flask-App liest
nur aus den Files.

**Warum:**
- Subprocess-Forks (`systemctl is-active`, `openssl x509 -enddate`,
  `proxy_pass`-Parsen) werden bei jedem Browser-Request teuer.
- Cron + atomic-move (`tmp` → `final` via `mv`) gibt deterministisches
  Refresh-Intervall ohne Race.
- Frontend-Auto-Refresh (30 s) liest Files, kein Backend-Load.

**Trade-off:** Status ist max. 5 Min alt. "Status sofort sammeln"-Action
forciert ein manuelles Refresh.

### 6. Action-Catalog statt freier Befehl-API

**Entscheidung:** Vordefinierte ID→Befehl-Map in `app.py`. UI ruft via
`POST /api/actions/<id>` auf, nie freien Befehl.

**Warum:**
- Klar abgegrenzte Angriffsfläche — kein User-Input fließt in den Subprocess.
- Sudoers-Whitelist (`/etc/sudoers.d/proxy-status`) listet exakt dieselben
  Befehle. Doppelter Schutz.
- Auditierbar: jede Action hat label, category, description, optional confirm.

**Trade-off:** Kein "ich-führe-mal-eben-schnell"-Befehl in der UI. Für Sonderfälle
weiterhin SSH (über Tailscale).

### 7. Tailscale für Admin-Plane, nicht für Daten-Plane

**Entscheidung:** Status-Site bindet an die Tailscale-IP, ist *nicht* öffentlich
erreichbar. Cert-Sync läuft auch via Tailscale-IP. Aber: der reguläre
Reverse-Proxy-Traffic (Port 80/443) bleibt am LAN/öffentlichen Interface.

**Warum:**
- Tailscale ist managed, hängt an SaaS-Infrastruktur — nicht für Hot-Path.
- Public Traffic darf nicht von einem externen Service abhängen.
- Admin-Zugriff (Status, SSH, Cert-Sync) toleriert Tailscale-Latenz und -Outage.

**Trade-off:** Wenn Tailscale ausfällt, ist die Statusseite nicht mehr aus dem
Internet erreichbar. Reverse-Proxy selbst läuft weiter.

## Architektur-Negativliste — was wir bewusst NICHT machen

- **HAProxy + nginx**: Doppelte Layer wäre mehr Komplexität ohne Mehrwert für
  HTTP/S-Termination.
- **Caddy**: Schöne Auto-HTTPS, aber wir haben certbot und nginx-Erfahrung im
  Team, und nginx hat das stabilere Logging-Ökosystem.
- **Active-Active mit gemeinsamer IP per ECMP**: Setup-Komplexität explodiert,
  Performance-Gewinn für Homelab-Last marginal.
- **PostgreSQL/Redis-State für Status**: JSON-Files reichen, kein DB-Operating
  zusätzlich nötig.
- **Container für die Statusseite**: gunicorn als systemd-Service ist einfacher.
- **Kubernetes**: für 2 VMs ist k8s ein Witz.

## Wann diese Architektur an Grenzen stößt

- **>500 Domains**: nginx-Reload-Zeit wird spürbar. Lösung: pro-Tenant-Configs
  per `include`, weniger globale Reloads.
- **Geo-Verteiltes Setup**: VRRP geht nicht über Subnetz-Grenzen. Lösung: globalen
  Anycast-Provider davorziehen, beide Nodes als Origin.
- **>10 Mio. Requests/Tag**: Wahrscheinlich braucht es dann einen CDN davor —
  dieser Reverse-Proxy bleibt für Origin-only.
