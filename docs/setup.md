# Setup — Initial-Aufbau der beiden Proxy-Nodes

## Voraussetzungen

- Zwei VMs auf zwei verschiedenen Proxmox-Hosts
- Beide im selben Layer-2-Netz (gleiches VLAN/Subnetz)
- Eine freie IP im selben Subnetz für die Floating-IP
- Tailscale-Account (Free-Tier reicht), optional: Authkey für automatisches Joining
- GitHub-Repo (privat) mit diesem Code, du musst Deploy-Keys eintragen können
- DNS: A-Records aller zu proxenden Domains zeigen auf die **Floating-IP**

## Schritt 1: VMs vorbereiten

Auf beiden Proxmox-Hosts je eine VM erstellen — am einfachsten mit dem
Helper-Script (auf dem Proxmox-Host als root, NICHT in der VM):

```bash
# Auf Proxmox-Host A:
./scripts/proxmox-create-vm.sh --name proxy01
# Auf Proxmox-Host B:
./scripts/proxmox-create-vm.sh --name proxy02
```

Das setzt automatisch das passende Profil:
- Debian 13 (trixie) netinstall
- 2 vCPU `host`, 2 GB RAM (Ballooning aus), 20 GB virtio-scsi
- OVMF/q35, VirtIO-NIC, qemu-guest-agent
- ISO wird, falls nötig, aus `cdimage.debian.org/current` mit SHA256-Check geholt

Defaults sind via Flags überschreibbar (`--memory`, `--cores`, `--disk-size`,
`--storage`, `--bridge`, `--vlan` …). VLAN-Tag NUR setzen, wenn dein LAN
VLAN-getaggt ist; bei einem flachen Homelab-LAN den Flag weglassen.

VM danach starten, Debian-Installer durchklicken (Standard-System + SSH-Server
reichen), nur einen User (root genügt, sudo ist optional).

**Anti-Affinity:** Falls Proxmox-Cluster mit HA — sicherstellen, dass die
VMs in einer HA-Group mit unterschiedlichen `restricted`-Nodes landen.

## Schritt 2: Repo herunterladen + Bootstrap starten

Auf **proxy01** (das wird gleich MASTER):

```bash
# Als root, sonst sudo:
apt-get update && apt-get install -y git
git clone https://github.com/<USER>/HA-Reverse-Proxy-HomeLab.git /opt/reverse-proxy
cd /opt/reverse-proxy
sudo ./scripts/bootstrap.sh
```

Der Bootstrap-Assistent führt dich durch 10 TUI-Dialoge. Jeder Dialog erklärt,
was er tut. Du brauchst:

- Rolle: **MASTER**
- Hostname: **proxy01** (Default)
- Statische IP, Gateway, Floating-IP
- VRRP-Passwort (8+ Zeichen — gleiches auch auf proxy02 verwenden!)
- E-Mail für Let's Encrypt
- Repo-URL (SSH-Format: `git@github.com:USER/REPO.git`)
- Optional: Tailscale-Authkey

Mittendrin generiert der Assistent einen SSH-Deploy-Key und zeigt ihn an —
**kopiere den Public-Key sofort als Deploy-Key (read-only) in GitHub** (Repo →
Settings → Deploy keys → Add). Erst danach klick OK weiter.

Falls die statische IP von der aktuellen abweicht: Die VM bootet automatisch
neu. Verbinde dich danach unter der NEUEN IP — Phase B läuft via systemd-Timer
automatisch weiter.

## Schritt 3: proxy02 — gleicher Workflow

```bash
git clone https://github.com/<USER>/HA-Reverse-Proxy-HomeLab.git /opt/reverse-proxy
cd /opt/reverse-proxy
sudo ./scripts/bootstrap.sh
```

Eingaben:
- Rolle: **BACKUP**
- Hostname: **proxy02**
- Eigene statische IP (anders als proxy01!)
- **Identische** Floating-IP, VRRP Router-ID und VRRP-Passwort
- Repo-URL identisch
- Peer-Tailscale-IP: die TS-IP von proxy01 (siehst du im Tailscale-Admin oder
  per `tailscale status` auf proxy01)

**Auch hier**: Public-Key in GitHub eintragen (zweiter Deploy-Key, separat).

## Schritt 4: Peer-Tailscale-IP nachtragen (auf proxy01)

Beim Bootstrap von proxy01 hattest du den TS-Peer evtl. noch leer gelassen.
Jetzt nachholen:

```bash
sudo nano /etc/proxy-config/values.env
# Zeile: PEER_TAILSCALE_IP=100.x.x.x
sudo systemctl restart proxy-status
```

## Schritt 5: Verifikation

```bash
# Welche Node hält die Floating-IP?
ip addr show | grep <floating-ip>

# nginx + keepalived OK?
systemctl status nginx keepalived proxy-status proxy-deploy.timer

# Status-API
curl http://$(tailscale ip -4):8080/api/health
```

Im Browser über Tailscale öffnen:
- `http://proxy01:8080` (Status / Operations / Admin)
- `http://proxy02:8080` (gleiche UI auf BACKUP)

## Schritt 6: Failover-Test

Siehe [failover-test.md](failover-test.md).

## Schritt 7: Erste Domain einrichten

Siehe [adding-a-service.md](adding-a-service.md).
