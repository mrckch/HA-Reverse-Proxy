# Recovery — drei Szenarien Schritt-für-Schritt

Diese Recipes sind so geschrieben, dass du sie **mitten in der Nacht im Krisenmodus**
durcharbeiten kannst. Jeder Schritt macht eins, du hakst ab.

> **Vorbedingung für alle Szenarien:** Du hast SSH-Zugang via Tailscale zu
> mindestens einer überlebenden Node. Falls beide Nodes komplett tot sind:
> Proxmox-Konsole nutzen.

---

## Szenario A — MASTER ist tot, BACKUP läuft

**Symptom:** Statusseite des BACKUP zeigt sich selbst als `MASTER`,
`peer.available = false`. Floating-IP wandert auf BACKUP. Services laufen weiter.

### Phase 1 — Erstmal stabilisieren (5 Min)

1. **Verifizieren:** `tailscale ssh root@proxy02 "ip addr | grep <floating-ip>"`.
   Die Floating-IP MUSS auf proxy02 stehen.
2. **Externe Erreichbarkeit testen:** `curl -I https://<eine-deiner-domains>/` von
   außen — sollte 200 oder 301 liefern.
3. **Health-Check externes Monitoring** prüfen — kommen wieder grüne Pings?

Wenn Phase 1 OK: **Service ist online. Du hast Zeit für Phase 2.**

### Phase 2 — proxy01 diagnostizieren

1. Versuche SSH via Tailscale: `tailscale ssh root@proxy01`.
   - Klappt → weiter mit Schritt 2.
   - Klappt nicht → Proxmox-Konsole, VM-Status prüfen.
2. `systemctl status nginx keepalived proxy-status`
3. `journalctl -u nginx -u keepalived --since "30 min ago"`
4. Disk voll? `df -h`.  RAM voll? `free -m`.

Häufige Ursachen:
- **Kernel-Panic / OOM-Kill** → reboot, dann Memory-Limits prüfen.
- **Disk voll** (Logs!) → `journalctl --vacuum-size=200M`, `apt clean`.
- **nginx-Config kaputt** durch falschen Push → siehe Szenario B.

### Phase 3 — proxy01 wieder online bringen

1. Sobald proxy01 antwortet: `systemctl start nginx keepalived proxy-status`.
2. **VRRP-Preempt:** keepalived-Default ist `preempt` — proxy01 kommt automatisch
   wieder zum MASTER, sobald er gesund ist (~3 s).
3. Beobachte 5 Minuten: Statusseite beider Nodes, externes Monitoring.
4. **Wenn alles stabil:** `journalctl --since "1 hour ago" -u nginx > /tmp/incident.log`
   für die Post-Mortem aufheben.

### Phase 4 — Wenn proxy01 unrettbar ist

VM komplett neu aufsetzen:

1. Neue Debian-13-VM mit identischem Hostnamen (`proxy01`) und identischer IP
   (am einfachsten mit `./scripts/proxmox-create-vm.sh --name proxy01`).
2. `git clone …` + `sudo ./scripts/bootstrap.sh` mit Rolle MASTER.
3. **WICHTIG:** GitHub-Deploy-Key auf proxy01 ist verloren — neuer SSH-Key wird
   im Bootstrap generiert. **Trage den neuen Public-Key in GitHub ein** und
   **lösche den alten** (Repo → Settings → Deploy keys).
4. Nach Bootstrap: Cert-Sync von proxy02 nach proxy01 manuell anstoßen, falls
   proxy02 inzwischen Cert-Renewals gemacht hat. Da proxy02 dafür aber kein
   Source-of-Truth ist, ist's sauberer, MASTER selbst die Certs renewen zu
   lassen — `sudo certbot renew --force-renewal` (Vorsicht Rate-Limit!).

---

## Szenario B — Bad Config gepusht, beide Nodes verweigern Reload

**Symptom:** Beide Status-Seiten zeigen `nginx: inactive`, externes Monitoring
rot. Services down. Du hast vor 5 Minuten gepusht und dachtest, das sei harmlos.

### Sofort-Stop des Auto-Deploys (verhindert weitere Schäden)

```bash
# Auf BEIDEN Nodes:
tailscale ssh root@proxy01 "systemctl stop proxy-deploy.timer"
tailscale ssh root@proxy02 "systemctl stop proxy-deploy.timer"
```

### Bad Commit identifizieren

```bash
tailscale ssh root@proxy01
cd /opt/reverse-proxy
git log --oneline -10                  # welche Commits sind drauf?
git log -p HEAD~3..HEAD nginx/         # was wurde an nginx geändert?
nginx -t -p /opt/reverse-proxy/nginx/  # was sagt nginx?
```

### Variante 1 — Repo-Revert (sauber)

Auf deinem Dev-Rechner:
```bash
git revert <bad-sha>
git push
```

Auf beiden Nodes:
```bash
systemctl start proxy-deploy.timer
systemctl start proxy-deploy.service   # sofort, statt auf Timer warten
```

Verifizieren:
```bash
nginx -t && systemctl status nginx
```

### Variante 2 — Lokal patchen (wenn Push gerade nicht geht)

Auf beiden Nodes:
```bash
cd /opt/reverse-proxy
nano nginx/sites-available/<broken>.conf   # fixen
sudo cp nginx/sites-available/<broken>.conf /etc/nginx/sites-available/
sudo nginx -t && sudo systemctl reload nginx
```

**WARNUNG:** Variante 2 ist transient — der nächste `git pull` (sobald
`proxy-deploy.timer` wieder läuft) überschreibt deine lokale Reparatur. Sobald
möglich richtig per Push fixen und Timer wieder anschalten.

---

## Szenario C — Beide Nodes neu aufsetzen aus dem Repo (Greenfield-Recovery)

**Wann:** Du machst ein größeres Hardware-Refresh, beide alten VMs werden
gelöscht, das Repo ist die einzige Quelle der Wahrheit.

### Vor dem Recovery — was du brauchst

- ✅ Repo-URL + GitHub-Account mit Schreibrechten auf Deploy-Keys
- ✅ Floating-IP (frei im LAN), VRRP-Passwort (8+ Zeichen) — schreibst du dir
  jetzt einmal auf, brauchst du auf beiden Nodes
- ✅ Tailscale-Authkey (optional, sonst manuelles `tailscale up`)
- ✅ ACME-Mail (deine, für Let's Encrypt-Notifications)
- ✅ DNS-Zugriff: alle Service-A-Records müssen auf Floating-IP zeigen — das ist
  vorhanden, weil DNS der gleiche bleibt

### Schritt 1 — proxy01 (MASTER) erstmalig hochziehen

```bash
# Frische Debian-13-VM (siehe scripts/proxmox-create-vm.sh), statische IP setzen oder DHCP
apt-get update && apt-get install -y git
git clone https://github.com/<USER>/HA-Reverse-Proxy-HomeLab.git /opt/reverse-proxy
cd /opt/reverse-proxy
sudo ./scripts/bootstrap.sh
```

TUI-Antworten siehe [setup.md](setup.md). Public-Key in GitHub eintragen.

### Schritt 2 — proxy02 (BACKUP) genauso

Identisch, aber Rolle BACKUP, andere statische IP, **identische** Floating-IP +
VRRP-Passwort.

### Schritt 3 — Erste Zertifikate

Auf proxy01:

```bash
sudo /opt/reverse-proxy/scripts/cert-request.sh service1.example.com
sudo /opt/reverse-proxy/scripts/cert-request.sh service2.example.com
# … pro Domain
```

Der `--deploy-hook` syncht jeweils sofort zu proxy02. Auf proxy02 prüfen:

```bash
ls /etc/letsencrypt/live/
```

Sollte alle Domains enthalten.

### Schritt 4 — Sites aktivieren

Auf **beiden** Nodes:

```bash
# pro Service:
sudo /opt/reverse-proxy/scripts/enable-site.sh <service-name>
```

### Schritt 5 — Failover-Test, dann ruhen lassen

Siehe [failover-test.md](failover-test.md). Wenn Failover sauber durchläuft,
hast du erfolgreich aus Repo + Bootstrap-Assistent ein vollständig funktionales
HA-Setup wiederhergestellt.

---

## Quick-Referenzen

| Symptom | Wo zuerst gucken |
|---|---|
| Externe 502/503 | `Ops → nginx-Test` und `Status` (Backend-Tabelle) |
| Cert kritisch | `Ops → cert-renew` auf MASTER |
| Status-Seite veraltet | `Ops → Status sofort sammeln` |
| keepalived flappt | `journalctl -u keepalived --since "30 min ago"` |
| Disk voll | `journalctl --vacuum-size=200M`, `apt clean`, Backup-Pfad checken |
