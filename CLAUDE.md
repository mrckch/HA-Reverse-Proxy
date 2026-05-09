# Projekt-Kontext für Claude Code

## Was ist das?
Reverse-Proxy-Setup mit Web-UI auf Basis von Nginx Proxy Manager (NPM).
Eine VM auf Proxmox, Debian 13, NPM als Docker-Container, Konfiguration
ausschließlich über die Web-UI auf Port 81.

Zielgruppe: Homelab-Nutzer ohne Linux-/Sysadmin-Erfahrung. Daher zwei
Bootstrap-Scripts, die alles abnehmen.

## Architektur-Entscheidungen (nicht ohne Rückfrage ändern!)
- **Eine** VM, kein HA. Fällt sie aus, ist der Proxy down.
- NPM läuft als Docker-Container, persistente Daten unter `/opt/npm/`
- IP-Konfiguration via Debian-natives ifupdown (`/etc/network/interfaces`)
- Bootstrap-Pfad ist Two-Phase: Phase A interaktive Eingaben + IP-Wechsel
  mit systemd-run-Reboot, Phase B (auto-resume nach Reboot) installiert
  Docker + NPM
- Web-UI nur im LAN erreichbar (kein Tailscale by default, kein
  Public-Access)

## Konventionen
- Shell-Scripts: bash, `set -euo pipefail`, ShellCheck-clean
- IP-Wechsel-Mechanik: `systemd-run --on-active=5s` für Reboot,
  ifupdown statt networkd, `chattr +i` auf resolv.conf
- Doku auf Deutsch (Klartext, keine Sysadmin-Insider-Sprache)
- Commit-Messages: kurz und aussagekräftig, deutsch oder englisch konsistent

## Was nie ins Repo darf
- Echte Domains (nutze example.com / beispiel.de in Beispielen)
- Backend-IPs aus dem realen Heimnetz (Platzhalter wie 10.0.0.50 / 192.168.1.30)
- Zertifikate, Keys, Passwörter
- NPM-Datenbank (liegt unter `/opt/npm/data/`, nie im Repo)

## Stand des Projekts
- [ ] VM auf Proxmox erstellt
- [ ] Bootstrap durchgelaufen
- [ ] Erstes Login in NPM-Web-UI + Default-Passwort geändert
- [ ] Erste Site (Domain → Backend) erfolgreich angelegt
- [ ] Backup-Strategie eingerichtet (siehe docs/npm-setup.md Phase 5)

(Diese Checkliste bei Fortschritt aktualisieren!)

## Nützliche Kommandos
- `cd /opt/npm && docker compose ps` — Status des NPM-Containers
- `cd /opt/npm && docker compose logs npm` — Logs
- `cd /opt/npm && docker compose pull && docker compose up -d` — Update
- `tar czf /root/npm-backup-$(date +%F).tar.gz -C /opt/npm data letsencrypt` — Backup

## Historie
Frühere Repo-Versionen enthielten ein HA-Setup mit zwei nginx-Nodes,
keepalived/VRRP, GitOps-Workflow und einer eigenen Status-Site. Das
wurde im Mai 2026 zugunsten des einfachen NPM-Pfads aufgegeben — der
HA-Komplexität stand kein realer Bedarf in diesem Homelab gegenüber.
Wer das alte Setup nachschlagen will: Git-History vor Mai 2026.
