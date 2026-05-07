# Projekt-Kontext für Claude Code

## Was ist das?
Hochverfügbares Reverse-Proxy-Setup mit zwei nginx-Nodes (proxy01 MASTER,
proxy02 BACKUP) auf zwei separaten Proxmox-Hosts im selben Layer-2-Netz.
Floating-IP via keepalived/VRRP. Admin-Zugriff über Tailscale.

## Architektur-Entscheidungen (nicht ohne Rückfrage ändern!)
- nginx läuft NATIV, nicht in Docker
- Repo ist Single Source of Truth, beide Nodes pullen via systemd-timer alle 2 Min
- sites-enabled wird NICHT über Git verteilt (manuelles Enable pro Node)
- Cert-Renewals nur auf MASTER, Sync zu BACKUP via Tailscale+rsync
- values.env liegt unter /etc/proxy-config/, niemals im Repo

## Konventionen
- Shell-Scripts: bash, set -euo pipefail, ShellCheck-clean
- nginx-Configs: 4 Spaces Einrückung, Snippets statt Wiederholung
- Python: PEP-8, Type Hints wo sinnvoll, keine zusätzlichen Abhängigkeiten
  ohne Rückfrage (Statusseite soll schlank bleiben)
- Commit-Messages: kurz und aussagekräftig, deutsch oder englisch konsistent

## Was nie ins Repo darf
- Echte Domains (nutze example.com in Beispielen)
- IPs der Backends (Platzhalter wie 10.0.0.50)
- Zertifikate, Keys, Passwörter
- values.env (nur values.env.example)

## Stand des Projekts
- [ ] VMs proxy01/proxy02 auf Proxmox erstellt
- [ ] Tailscale installiert und beide Nodes im Mesh
- [ ] Bootstrap-Script gelaufen
- [ ] values.env auf beiden Nodes konfiguriert
- [ ] Erster Test-Service deployed
- [ ] Failover-Test bestanden
- [ ] Erste Produktiv-Services migriert

(Diese Checkliste bei Fortschritt aktualisieren!)

## Nützliche Kommandos
- nginx -t && systemctl reload nginx
- journalctl -u keepalived -f
- tailscale status
- systemctl list-timers proxy-deploy.timer