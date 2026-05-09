# Reverse Proxy

Dieses Repo enthält **zwei alternative Setups** — wähle eins:

## Variante A: NPM (Nginx Proxy Manager) — Web-UI, einfach

Eine VM, klicki-bunt im Browser. Kein Linux-Wissen nötig.
Empfohlen für Homelab-Nutzer ohne Sysadmin-Hintergrund.

→ **Anleitung:** [docs/npm-setup.md](docs/npm-setup.md)
→ **Bootstrap-Script:** [scripts/npm-bootstrap.sh](scripts/npm-bootstrap.sh)

## Variante B: HA-Setup mit zwei nginx-Nodes — Profi-Pfad

Hochverfügbares Setup mit zwei Nodes, Floating-IP via keepalived,
GitOps-Workflow, eigener Status-Site. Deutlich höhere Lernkurve,
keine Web-UI für Konfiguration.

## Architektur

```
                    ┌─────────────────┐
                    │  Floating-IP    │  ← keepalived (VRRP)
                    └────────┬────────┘
                             │
                ┌────────────┴────────────┐
                │                         │
        ┌───────▼────────┐       ┌────────▼───────┐
        │   proxy01      │       │   proxy02      │
        │   MASTER       │◄─────►│   BACKUP       │
        └───────┬────────┘       └────────┬───────┘
                │                         │
                └────────────┬────────────┘
                             │
                    Backend-Services
```

- **proxy01 / proxy02:** Debian 13 (trixie), 2 vCPU, 2 GB RAM, je auf einem anderen Proxmox-Host
  (VM-Anlage: [`scripts/proxmox-create-vm.sh`](scripts/proxmox-create-vm.sh))
- **nginx:** nativ installiert (kein Docker)
- **keepalived:** VRRP für Floating-IP-Failover
- **Tailscale:** für Admin-Zugriff auf die Statusseite
- **certbot:** Let's Encrypt, Renewals nur auf MASTER, Sync zu BACKUP
- **GitHub:** Single Source of Truth, Pull-basiertes Deployment via systemd-timer

## Verzeichnisstruktur

```
.
├── nginx/                  # nginx-Konfiguration
│   ├── nginx.conf          # Hauptkonfiguration
│   ├── conf.d/             # globale Snippets
│   ├── snippets/           # wiederverwendbare Bausteine
│   └── sites-available/    # eine Datei pro Service
├── keepalived/             # VRRP-Konfiguration
├── status/                 # Flask-Statusseite
├── scripts/                # Deploy-, Sync-, Healthcheck-Scripts
├── systemd/                # systemd-Units und Timer
├── ansible/                # optional: Provisionierung
└── docs/                   # Setup-Anleitungen, Runbooks
```

## Erste Schritte

1. [Initial-Setup](docs/setup.md) — Bootstrap der beiden VMs (whiptail-TUI)
2. [Service hinzufügen](docs/adding-a-service.md) — neue Backends einbinden
3. [Failover testen](docs/failover-test.md) — VRRP-Wechsel verifizieren
4. [Runbook](docs/runbook.md) — tägliche/wöchentliche Checks + Eskalationen
5. [Recovery](docs/recovery.md) — drei Krisen-Szenarien Schritt-für-Schritt
6. [Architektur](docs/architecture.md) — Designentscheidungen + Trade-offs

## Deployment-Workflow

```
[Lokaler Rechner]                [proxy01 + proxy02]
      │                                  │
      ├── git commit                     │
      ├── git push                       │
      │                                  │
      │                              systemd-timer (alle 2 Min)
      │                                  │
      │                              git pull
      │                                  │
      │                              nginx -t
      │                                  │
      │                              systemctl reload nginx
```

## Sicherheit

- Statusseite lauscht **nur auf Tailscale-Interface** (nicht öffentlich)
- TLS 1.2 + 1.3, Mozilla "intermediate" Cipher-Suite
- HSTS, Security Headers zentral als Snippet
- Rate Limiting für sensible Endpoints
- fail2ban auf nginx-Logs
- ufw: nur 22/80/443 öffentlich, Status-Port nur via Tailscale
