# Runbook — Betrieb des Proxys

## Tägliche Checks (2 Min)

- [ ] **Statusseite** öffnen (Tailscale → `http://proxy01:8080`)
  - Cluster-Karte: ein MASTER, ein BACKUP, beide grün?
  - Memory < 70 %, Disk < 80 %?
  - Backends-Tabelle: alle online?
  - Zertifikate: alle ≥ 30 Tage Restlaufzeit?
- [ ] **Externes Monitoring** prüfen (UptimeRobot/Healthchecks.io/eigenes)

## Wöchentliche Checks (10 Min)

- [ ] **Patchstand:**
  Auf der Status-Seite → Tab `Operations` → `Security-Updates: Dry-Run` ausführen.
  Liste anschauen — wenn nichts kritisch dabei: warten bis nächster Patchday.
  Wenn etwas Sicherheitsrelevantes: siehe Abschnitt **Patchday** unten.
- [ ] **Failover-Test** (1× pro Woche, am besten Mo morgens):
  `tailscale ssh root@proxy01 "systemctl stop nginx"` → BACKUP übernimmt → 30 s
  beobachten → `systemctl start nginx` → MASTER kommt zurück.
- [ ] **Repo-Stand** auf beiden Nodes identisch?
  Status-Seite → `Repository`-Card: gleicher Commit-Hash auf proxy01 und proxy02.

## Monatliche Checks (30 Min)

- [ ] **Cert-Renewal-Logik** verifizieren:
  `sudo certbot renew --dry-run` auf MASTER — sollte für alle Certs OK sagen.
- [ ] **Backups** stichprobenartig restaurieren (siehe Backup-Sektion).
- [ ] **Logs durchscrollen:** `journalctl --since "30 days ago" | grep -iE "error|critical"`.
- [ ] **Disk-Trend:** `df -h` und Disk-Sparkline auf der Statusseite — wächst etwas
  unkontrolliert?

---

## Patchday — wegen HA: erst eine, dann die andere Node

> **Goldene Regel:** NIE beide Nodes gleichzeitig rebooten. Sonst sind alle Services
> für die Reboot-Dauer down.

```bash
# 1. BACKUP patchen (Floating-IP bleibt auf MASTER)
tailscale ssh root@proxy02
sudo apt-get update && sudo apt-get upgrade -y
sudo reboot

# Warten bis online (Statusseite proxy02 grün), dann:

# 2. MASTER patchen (Floating-IP wandert kurz zu BACKUP)
tailscale ssh root@proxy01
sudo apt-get update && sudo apt-get upgrade -y
sudo reboot

# Nach Reboot: Floating-IP kommt automatisch zurück zu proxy01
```

Alternativ: Operations-Tab → `Security-Updates installieren` (das ist
`unattended-upgrade -d`, ohne Reboot). Anschließend manuell `vm-reboot` falls
Kernel-Update gemacht wurde.

---

## Update via Operations-Tab (statt SSH)

Die meisten Routine-Tasks gehen über die UI, ohne SSH:

| Task | UI-Pfad |
|---|---|
| Repo pullen + deployen | `Operations → Repo pullen + deployen` |
| Status-Snapshot forcieren | `Operations → Status sofort sammeln` |
| nginx-Config testen | `Operations → nginx-Config testen` |
| nginx neu laden | `Operations → nginx neu laden` |
| Zertifikate auflisten | `Operations → Zertifikate auflisten` |
| Zertifikate erneuern | `Operations → Zertifikate erneuern` (nur MASTER!) |
| apt update | `Operations → apt update` |
| Sicherheitsupdates ansehen | `Operations → Security-Updates: Dry-Run` |
| Sicherheitsupdates installieren | `Operations → Security-Updates installieren` ⚠ |
| Reboot | `Operations → VM neu starten` ⚠⚠ |

Aktionen mit ⚠ haben Confirm-Dialog. Live-Output erscheint rechts.

**Sicherheits-Hinweis:** Die Operations-Tab ist nur über Tailscale erreichbar
(Status-Service bindet auf Tailscale-IP). Wer kein Tailscale-Gerät hat, hat
keinen Zugriff. Zusätzliche Auth (bcrypt) ist absichtlich nicht aktiviert —
Tailscale-Mesh ist hier die Auth-Schicht.

---

## Häufige Aufgaben (CLI)

### Service hinzufügen oder entfernen

Siehe [adding-a-service.md](adding-a-service.md).

### Aktive nginx-Configs anzeigen

```bash
sudo nginx -T | less
```

### Service temporär deaktivieren

Auf **beiden** Nodes:
```bash
sudo rm /etc/nginx/sites-enabled/<service>.conf
sudo systemctl reload nginx
```

(Im Repo bleibt `sites-available/<service>.conf` — du brauchst nur den Symlink.)

### Logs eines Services

```bash
tail -f /var/log/nginx/<service>-access.log
tail -f /var/log/nginx/<service>-error.log
```

### Top-IPs (DoS-Verdacht)

```bash
awk '{print $1}' /var/log/nginx/access.log | sort | uniq -c | sort -rn | head -20
```

### IP über fail2ban bannen

```bash
sudo fail2ban-client set nginx-http-auth banip <ip>
sudo fail2ban-client status nginx-http-auth
```

---

## Eskalationen

Siehe [recovery.md](recovery.md) für die drei Hauptszenarien (MASTER tot, Bad
Config gepusht, beide Nodes neu aufsetzen).

### nginx will nicht starten

```bash
sudo nginx -t                          # Syntax?
journalctl -xeu nginx                  # systemd-Log
ss -tulpn | grep -E ':(80|443)'        # Port-Konflikt?
```

Bei Syntax-Fehler nach Deploy: bad commit revert via Repo (siehe recovery.md
Szenario B).

### keepalived flappt

Symptom: Statusseite wechselt ständig zwischen MASTER/BACKUP.

```bash
journalctl -u keepalived --since "30 min ago" | grep -iE "transition|state"
```

Häufige Ursachen:
- Health-Check zu aggressiv → in `keepalived/keepalived-master.conf`
  `interval 5`, `fall 3` setzen, push, deploy.
- Backend zu langsam → nginx-Stub-Status auf 127.0.0.1 antwortet nicht in
  2 s. Backend tunen.

### Cert-Renewal fehlgeschlagen

```bash
sudo journalctl -u certbot.timer
sudo cat /var/log/letsencrypt/letsencrypt.log
```

Häufige Ursachen:
- DNS zeigt nicht mehr auf Floating-IP
- Port 80 von außen nicht erreichbar
- Rate-Limit erreicht (LE: 5 Fails/Stunde pro Domain)

---

## Backup

Was muss gesichert werden:

| Pfad | Wo | Wie oft | Methode |
|---|---|---|---|
| `/etc/proxy-config/values.env` | jede Node, Secrets | wöchentlich | `tar` auf NAS oder restic |
| `/etc/letsencrypt/` | MASTER (BACKUP-Kopie via Sync) | wöchentlich | `tar` auf NAS oder restic |
| Repo selbst | GitHub | bei jedem Push | automatisch |
| `/var/log/proxy-*` | jede Node, Audit-Trail | täglich (rotiert) | logrotate (vorhanden) |

**Empfehlung:** restic-Repo auf NAS, täglich:

```bash
# /etc/cron.daily/proxy-backup (manuell anlegen)
restic -r /mnt/nas/proxy-backups backup \
    /etc/proxy-config /etc/letsencrypt \
    --tag $(hostname)
restic -r /mnt/nas/proxy-backups forget --keep-daily 14 --keep-weekly 8 --prune
```
