# Nginx Proxy Manager (NPM) — Setup für Nicht-Sysadmins

Diese Anleitung führt dich Klick für Klick. Du brauchst **keine Linux- oder
nginx-Kenntnisse**. Alle Befehle stehen zum Kopieren bereit, alle UI-Schritte
mit der genauen Beschriftung.

## Was du am Ende hast

- **Eine VM** mit dem Nginx Proxy Manager
- **Web-UI im Browser** auf http://&lt;deine-vm-ip&gt;:81
- Klick-Workflow für neue Sites: Domain + Backend-IP + SSL-Häkchen → fertig
- Eingebauter **Let's Encrypt** (NPM macht das selbst, kein Cert-Sync)
- Eingebauter **Backup-Export** (Settings → Backups)

## Was du vorher brauchst

```
□ Proxmox-Host mit freiem Speicher (~20 GB)
□ 1 freie IP in deinem LAN-Subnetz (z.B. 192.168.1.20)
□ Eine Domain, deren A-Record auf diese VM-IP zeigt — pro Site eine
   (z.B. pihole.beispiel.de, ha.beispiel.de). Falls dein Router NAT macht:
   Port 80 + 443 vom Internet auf die VM-IP weiterleiten.
□ Default-NPM-Passwort merken: admin@example.com / changeme
   → musst du beim ersten Login ändern.
```

## Phase 1 — VM auf Proxmox anlegen

Auf dem **Proxmox-Host** als root in der Proxmox-Shell:

```bash
# Repo holen (git ist auf Proxmox eh vorhanden)
git clone https://github.com/mrckch/Reverse-Proxy-VM.git /opt/repo
cd /opt/repo

# VM anlegen (Defaults sind sinnvoll — 2 vCPU, 2 GB RAM, 20 GB Disk,
# Bridge vmbr0, ISO-Storage 'local'. Anpassbar via Flags, siehe --help)
./scripts/proxmox-create-vm.sh --name npm
```

Das Script lädt bei Bedarf das aktuelle Debian-13-netinstall-ISO (mit
SHA256-Verifikation), legt die VM mit dem passenden Hardware-Profil an
und gibt die nächsten Schritte aus.

In der Proxmox-Web-UI: VM starten, **Debian-13-netinstall** durchklicken:
- Sprache: deutsch (oder englisch, egal)
- „Standard-System" + „SSH-Server" reichen — nichts anderes anhaken
- Single root-Passwort genügt, einen weiteren Benutzer brauchst du nicht

## Phase 2 — Bootstrap in der VM (1 Befehl)

Per SSH oder Proxmox-Konsole **als root**:

```bash
apt-get update && apt-get install -y git
git clone https://github.com/mrckch/Reverse-Proxy-VM.git /opt/npm-bootstrap
cd /opt/npm-bootstrap
./scripts/npm-bootstrap.sh
```

Der Wizard fragt dich:
- **Hostname**: Default „npm" — kannst du so lassen
- **Netzwerk-Interface**: vorausgewählt (das mit der Default-Route)
- **Statische IP**: deine geplante IP, z.B. `192.168.1.20/24`
- **Gateway**: deine Router-IP, z.B. `192.168.1.1`

Bestätige mit „OK". **Wenn die statische IP von der aktuellen abweicht**:
die VM rebootet, du loggst dich nach ~60 s mit der **neuen IP** wieder ein.
Phase B läuft beim Boot **automatisch weiter** — du musst nichts tun, nur
warten und beim Wieder-Einloggen `tail -f /var/log/npm-bootstrap.log`
ausführen falls du den Fortschritt sehen willst.

Phase B installiert (alles automatisch):
1. System-Updates + Basis-Pakete
2. Docker Engine + Docker-Compose-Plugin
3. Firewall (ufw) — erlaubt SSH, 80, 443, 81
4. NPM-Container starten

Am Ende zeigt das Script:

```
================================================================
 NPM-Bootstrap abgeschlossen.
================================================================
  Web-UI:    http://192.168.1.20:81
  Default-Login:
      E-Mail:    admin@example.com
      Passwort:  changeme
  *** SOFORT EINLOGGEN UND PASSWORT ÄNDERN! ***
```

## Phase 3 — Erstes Login (Browser)

1. Öffne im Browser: **http://&lt;deine-vm-ip&gt;:81**
2. Login: `admin@example.com` / `changeme`
3. NPM zwingt dich, **sofort** Name + E-Mail + Passwort zu ändern.
   Wähle ein **starkes Passwort** — die Web-UI ist im LAN erreichbar
   und steuert deinen Reverse-Proxy.

## Phase 4 — Erste Site einrichten (Klick-Workflow)

**Beispiel: Pi-hole, das auf 192.168.1.30:80 in deinem LAN läuft, soll
unter `pihole.beispiel.de` mit HTTPS erreichbar sein.**

Voraussetzung: A-Record `pihole.beispiel.de` zeigt auf die NPM-VM-IP
(oder bei NAT: auf deine externe IP, mit Port-Forwarding 80/443 auf die VM).

**Schritte in der NPM-Web-UI:**

1. Oben: **Hosts → Proxy Hosts**
2. Rechts: **Add Proxy Host** klicken
3. Tab **Details**:
   - Domain Names: `pihole.beispiel.de` (Enter drücken nach der Eingabe!)
   - Scheme: `http`
   - Forward Hostname / IP: `192.168.1.30`
   - Forward Port: `80`
   - „Block Common Exploits" anhaken
   - „Websockets Support" anhaken (falls Backend WebSockets nutzt)
4. Tab **SSL**:
   - SSL Certificate: **Request a new SSL Certificate**
   - „Force SSL" anhaken
   - „HTTP/2 Support" anhaken
   - „HSTS Enabled" anhaken
   - E-Mail Address for Let's Encrypt: deine E-Mail
   - „I agree to the Let's Encrypt Terms of Service" anhaken
5. **Save** klicken
6. NPM holt automatisch ein Let's-Encrypt-Cert (5-30 Sekunden)
7. Im Browser: https://pihole.beispiel.de — sollte mit gültigem Cert antworten

**Wenn der SSL-Schritt fehlschlägt** (rote Box):
- A-Record stimmt nicht oder DNS noch nicht propagiert? → `nslookup pihole.beispiel.de` prüfen
- Port 80 nicht öffentlich erreichbar? → Router-NAT prüfen (80 + 443 auf VM-IP)
- Let's Encrypt Rate-Limit (selten)? → 1 h warten

## Phase 5 — Backup einrichten

NPM bietet kein Auto-Backup, aber Export ist trivial. Auf der VM **als root**:

```bash
# Manuelles Backup (lokale tar.gz)
tar czf /root/npm-backup-$(date +%F).tar.gz -C /opt/npm data letsencrypt

# Automatisches täglich um 03:00 (cron):
echo "0 3 * * * root tar czf /root/npm-backup-\$(date +\%F).tar.gz -C /opt/npm data letsencrypt && find /root/npm-backup-*.tar.gz -mtime +14 -delete" \
    > /etc/cron.d/npm-backup
```

(Letztere Zeile macht täglich Backup um 03:00, behält 14 Tage.)

Die Backup-Datei kannst du regelmäßig auf einen anderen Rechner / NAS ziehen.

## Phase 6 — Update von NPM

Wenn eine neue NPM-Version draußen ist (siehe https://github.com/NginxProxyManager/nginx-proxy-manager/releases):

```bash
cd /opt/npm
docker compose pull
docker compose up -d
```

Daten und Certs bleiben erhalten (liegen im persistenten Volume).

## Häufige Fragen

### Wie viele Sites kann NPM verwalten?

Praktisch unbegrenzt für Homelab — mehrere hundert hostet NPM ohne Probleme.

### Wo liegen die Daten?

- `/opt/npm/data/` — NPM-Konfiguration, SQLite-DB
- `/opt/npm/letsencrypt/` — alle Let's-Encrypt-Zertifikate
- `/opt/npm/docker-compose.yml` — der Container

Beides kannst du backuppen (siehe Phase 5).

### Wie melde ich mich von außerhalb an?

Standardmäßig **gar nicht** — die Web-UI auf Port 81 ist nur im LAN
erreichbar. Das ist die empfohlene Default-Variante: vom Sofa aus
konfigurieren, von außerhalb gar nicht erreichbar.

Wenn du das später ändern willst (z.B. „mal von unterwegs einloggen"):

1. **VPN ins Heimnetz** — empfohlen. Z.B. WireGuard auf dem Router (FritzBox, OPNsense, etc.) oder als eigener Container neben NPM. Damit landest du im LAN und erreichst alles, inkl. NPM-Web-UI.
2. **Tailscale** auf der VM (`apt install tailscale && tailscale up --ssh`). Geräte mit Tailscale-Client können dann die VM über die Tailscale-IP ansprechen. Komfortabler als Wireguard, aber abhängig vom Tailscale-SaaS.
3. **Web-UI über NPM selbst publizieren** — wäre möglich (eigener Proxy-Host mit Access-List/Basic-Auth), ist aber für die Admin-Oberfläche eines Reverse-Proxys ein vermeidbares Risiko. Lieber Variante 1 oder 2.

### Was passiert, wenn die VM ausfällt?

Reverse-Proxy ist down, bis die VM wieder läuft (Reboot, Restore aus Backup).
Im Homelab ist das meist akzeptabel — fällt selten vor und die Recovery
ist mit einem Backup eine Frage von Minuten.

Falls du HA willst (mehrere Nodes mit Failover): das ist genau das
ursprüngliche HA-Setup in diesem Repo (Verzeichnisse `nginx/`, `keepalived/`
etc. + `bootstrap.sh`). Deutlich komplexer in Verwaltung — daher nicht
empfohlen wenn du gerade NPM mit Web-UI gewählt hast.

## Troubleshooting

### NPM-Container läuft nicht

```bash
cd /opt/npm
docker compose ps           # Status
docker compose logs npm     # Logs
docker compose restart      # Neustart
```

### „502 Bad Gateway" beim Aufruf einer Site

Das Backend (z.B. Pi-hole) ist nicht erreichbar.
- IP/Port stimmen?
- Backend läuft?
- Firewall am Backend lässt die Verbindung zu?

### SSL-Cert läuft ab

NPM erneuert automatisch (alle 60 Tage). Wenn nicht, manuell:
- Hosts → Proxy Hosts → drei Punkte → SSL → Renew

### „Reset" — alles neu

```bash
cd /opt/npm
docker compose down
rm -rf /opt/npm/data /opt/npm/letsencrypt
docker compose up -d
# UI wieder unter http://<ip>:81 mit Default-Login
```
