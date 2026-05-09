# Reverse Proxy mit Web-UI (Nginx Proxy Manager)

Setup für einen **Reverse Proxy mit Klick-bunter Web-UI** auf Basis von
[Nginx Proxy Manager](https://nginxproxymanager.com/) (NPM). Eine VM auf
Proxmox, Docker-Container, alles im Browser.

Gedacht für Homelab-Nutzer **ohne Linux-/Sysadmin-Erfahrung** — die zwei
Bootstrap-Scripts machen den ganzen Aufbau, anschließend nur noch Web-UI.

## Was du am Ende hast

- **Eine VM** mit Nginx Proxy Manager
- **Web-UI** auf http://&lt;vm-ip&gt;:81 (nur im LAN)
- Klick-Workflow: Domain + Backend-IP eintragen → SSL-Häkchen → fertig
- Eingebauter **Let's Encrypt** (NPM macht das selbst)
- Eingebauter **Backup-Export** (Settings → Backups)

## Schnellstart

```bash
# 1. Auf dem Proxmox-Host (Shell als root):
git clone https://github.com/mrckch/HA-Reverse-Proxy.git /opt/repo
cd /opt/repo
./scripts/proxmox-create-vm.sh --name npm

# 2. VM in der Proxmox-Web-UI starten, Debian 13 netinstall durchklicken,
#    dann in der VM (per SSH oder Proxmox-Konsole, als root):
apt-get update && apt-get install -y git
git clone https://github.com/mrckch/HA-Reverse-Proxy.git /opt/npm-bootstrap
cd /opt/npm-bootstrap
./scripts/npm-bootstrap.sh

# 3. Browser öffnen: http://<vm-ip>:81
#    Default-Login: admin@example.com / changeme  (sofort ändern!)
```

Vollständige Schritt-für-Schritt-Doku: **[docs/npm-setup.md](docs/npm-setup.md)**

## Was wo liegt

```
scripts/
  proxmox-create-vm.sh      # Anlage der VM auf Proxmox-Host (1 Befehl)
  npm-bootstrap.sh          # Setup in der VM: IP, Docker, NPM (interaktiv)
npm/
  docker-compose.yml        # NPM-Container-Definition
docs/
  npm-setup.md              # Klick-für-Klick-Anleitung für Nicht-Sysadmins
```

## Voraussetzungen

- Proxmox-Host mit ~20 GB freiem Speicher
- 1 freie IP im LAN (z.B. 192.168.1.20) außerhalb des DHCP-Pools
- Eine Domain pro Site, deren A-Record auf die VM-IP zeigt
- Bei NAT-Router: Port 80 + 443 vom Internet auf die VM-IP weiterleiten

## Was bewusst NICHT enthalten ist

- **HA / Failover**: Eine VM, fällt sie aus, ist der Proxy down. Im Homelab
  meist akzeptabel, Recovery aus Backup ist eine Sache von Minuten.
- **Externe Erreichbarkeit der Web-UI**: Nur LAN. Wenn du von unterwegs
  zugreifen willst, ist Tailscale oder ein VPN die richtige Lösung
  (siehe Doku, „Häufige Fragen").

## Lizenz

[MIT](LICENSE)
