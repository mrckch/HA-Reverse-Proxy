# Runbook — Betrieb des Proxys

## Tägliche Checks

- Statusseite prüfen: alle Backends grün, Zertifikate > 30 Tage Restlaufzeit
- `/api/health` von beiden Nodes externes Monitoring (UptimeRobot, Uptime Kuma, Healthchecks.io)

## Häufige Aufgaben

### Manuelles Deployment erzwingen

```bash
ssh root@proxy01 "systemctl start proxy-deploy.service"
ssh root@proxy02 "systemctl start proxy-deploy.service"
```

Logs:
```bash
journalctl -u proxy-deploy --since "1 hour ago"
tail -f /var/log/proxy-deploy.log
```

### nginx-Config testen ohne Reload

```bash
nginx -t
```

### Aktive Configs anzeigen

```bash
nginx -T | less
```

### Zertifikate manuell renewen

```bash
# Auf MASTER
certbot renew --dry-run    # Test
certbot renew              # Echtes Renewal
```

Cert-Sync läuft danach automatisch via deploy-hook.

### Service temporär ausschalten

```bash
# Auf beiden Nodes
rm /etc/nginx/sites-enabled/<service>.conf
systemctl reload nginx
```

### Logs eines Services anschauen

```bash
tail -f /var/log/nginx/<service>-access.log
tail -f /var/log/nginx/<service>-error.log
```

### Top-IPs (z.B. bei Verdacht auf DoS)

```bash
awk '{print $1}' /var/log/nginx/access.log | sort | uniq -c | sort -rn | head -20
```

### IP über fail2ban bannen

```bash
fail2ban-client set nginx-http-auth banip <ip>
fail2ban-client status nginx-http-auth
```

## Eskalationen

### nginx will nicht starten

```bash
nginx -t                          # Syntax?
journalctl -xeu nginx             # systemd-Log
ss -tulpn | grep -E ':(80|443)'   # Port-Konflikt?
```

Bei Syntax-Fehler nach Deploy:
```bash
git -C /opt/reverse-proxy log -5 --oneline
git -C /opt/reverse-proxy revert HEAD
git -C /opt/reverse-proxy push    # falls Push-Rechte vorhanden
# oder lokal revert + push, dann systemctl start proxy-deploy
```

### keepalived flappt

Symptom: Statusseite wechselt ständig MASTER/BACKUP.

```bash
journalctl -u keepalived --since "30 min ago" | grep -i "transition\|state"
# Health-Check zu aggressiv?
# Backend zu langsam?
```

Quick-Fix: `interval 5; fall 3` in keepalived.conf — mehr Toleranz.

### Cert-Renewal fehlgeschlagen

```bash
journalctl -u certbot.timer
cat /var/log/letsencrypt/letsencrypt.log
```

Häufige Ursachen:
- DNS zeigt nicht mehr auf Floating-IP
- Port 80 von außen nicht erreichbar
- Rate-Limit erreicht (LE: 5 Fails/Stunde pro Domain)

### Beide Nodes sind weg

Worst case. Zugriff über Tailscale-SSH probieren (funktioniert auch ohne dass nginx läuft).

```bash
tailscale ssh root@proxy01
systemctl status nginx keepalived proxy-status
```

Falls VMs hängen: über Proxmox-Webinterface Konsole/Reset.

## Patchday

Wegen HA: erst eine Node patchen, testen, dann die andere.

```bash
# 1. BACKUP patchen
ssh root@proxy02
apt update && apt upgrade -y
reboot
# Warten bis online, Statusseite prüfen

# 2. MASTER patchen — Floating-IP wandert kurz zu proxy02
ssh root@proxy01
apt update && apt upgrade -y
reboot
# Warten bis online, Floating-IP kommt zurück
```

## Backup

Was muss gesichert werden:
- `/etc/proxy-config/values.env` (auf jeder Node, hat Secrets)
- `/etc/letsencrypt/` (Zertifikate, ist auf MASTER + via Sync auch BACKUP)
- Repo selbst → liegt auf GitHub

Empfehlung: einmal täglich `tar` über `/etc/letsencrypt` und `/etc/proxy-config` per cron auf einen NAS oder restic-Repository.
