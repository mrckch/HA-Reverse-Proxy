# Setup — Initial-Aufbau der beiden Proxy-Nodes

## Voraussetzungen

- Zwei VMs auf zwei verschiedenen Proxmox-Hosts
- Beide im selben Layer-2-Netz (gleiches VLAN/Subnetz)
- Eine freie IP im selben Subnetz für die Floating-IP
- Tailscale-Account (Free-Tier reicht)
- GitHub-Repo (privat) mit diesem Code
- DNS: A-Records aller zu proxenden Domains zeigen auf die **Floating-IP**

## Schritt 1: VMs vorbereiten

Auf beiden Proxmox-Hosts je eine VM erstellen:

- Debian 12 cloud-image
- 2 vCPU, 2 GB RAM, 20 GB Disk
- Bridge: `vmbr0` (oder eure Standard-Bridge)
- Statische IP setzen, Hostnames `proxy01` / `proxy02`

**Anti-Affinity:** Falls Proxmox-Cluster mit HA — sicherstellen, dass die VMs in einer HA-Group mit unterschiedlichen `restricted`-Nodes landen.

## Schritt 2: SSH einrichten

```bash
# Vom Admin-Rechner
ssh-copy-id root@proxy01
ssh-copy-id root@proxy02

# Zwischen den Nodes (für Cert-Sync)
ssh root@proxy01 "ssh-keygen -t ed25519 -N '' -f ~/.ssh/id_ed25519"
ssh root@proxy01 "cat ~/.ssh/id_ed25519.pub" | ssh root@proxy02 "cat >> ~/.ssh/authorized_keys"
```

## Schritt 3: Tailscale aktivieren

Auf beiden Nodes:

```bash
curl -fsSL https://tailscale.com/install.sh | sh
tailscale up --ssh
# Den ausgegebenen Link im Browser öffnen, Node autorisieren
tailscale ip -4   # Tailscale-IP notieren — kommt nachher in values.env
```

Optional in der Tailscale-Admin-UI ACL setzen, sodass nur deine Geräte die Status-Ports sehen.

## Schritt 4: Repo deployen

Auf beiden Nodes:

```bash
mkdir -p /opt
cd /opt
git clone https://github.com/<dein-user>/reverse-proxy.git
cd reverse-proxy
chmod +x scripts/*.sh keepalived/*.sh
```

Damit `git pull` ohne Login klappt, am besten Deploy Key in GitHub einrichten:

```bash
ssh-keygen -t ed25519 -N '' -f /root/.ssh/github_deploy
cat /root/.ssh/github_deploy.pub
# → in GitHub: Settings → Deploy keys → Add (read-only)
```

Dann SSH-Config:

```bash
cat >> /root/.ssh/config <<EOF
Host github-proxy
    HostName github.com
    User git
    IdentityFile /root/.ssh/github_deploy
EOF
```

Und Repo auf SSH-URL umstellen:

```bash
git remote set-url origin git@github-proxy:<dein-user>/reverse-proxy.git
```

## Schritt 5: Bootstrap

**Auf proxy01 (MASTER):**
```bash
cd /opt/reverse-proxy
sudo ./scripts/bootstrap.sh master
```

**Auf proxy02 (BACKUP):**
```bash
cd /opt/reverse-proxy
sudo ./scripts/bootstrap.sh backup
```

## Schritt 6: values.env auf beiden Nodes anpassen

`/etc/proxy-config/values.env` bearbeiten — ist beim Bootstrap aus dem Beispiel kopiert worden. Pro Node die Werte einsetzen:

- `NODE_ROLE` (MASTER bzw. BACKUP)
- `NODE_NAME`, `PEER_NAME`
- `PEER_TAILSCALE_IP` (jeweils die IP der anderen Node)
- `STATUS_BIND_IP` (eigene Tailscale-IP)
- `VRRP_INTERFACE` (z.B. `eth0`, prüfen mit `ip addr`)
- `FLOATING_IP`
- `VRRP_AUTH_PASS` (auf beiden Nodes identisch)

## Schritt 7: Services aktivieren und starten

```bash
# systemd-Units installieren
cp /opt/reverse-proxy/systemd/proxy-deploy.{service,timer} /etc/systemd/system/
cp /opt/reverse-proxy/status/systemd/proxy-status.service  /etc/systemd/system/

systemctl daemon-reload

# nginx
systemctl enable --now nginx

# keepalived
systemctl enable --now keepalived

# Statusseite
systemctl enable --now proxy-status

# Auto-Deploy
systemctl enable --now proxy-deploy.timer
```

## Schritt 8: Verifikation

```bash
# Welche Node hält gerade die Floating-IP?
ip addr show | grep <floating-ip>

# Statusseite
curl http://$(tailscale ip -4):8080/api/status.json | jq

# nginx-Health
curl http://127.0.0.1:8081/nginx_status

# keepalived-Log
journalctl -u keepalived -f
```

Im Browser über Tailscale: `http://proxy01:8080` und `http://proxy02:8080`

## Schritt 9: Erste Domain einrichten

Siehe [adding-a-service.md](adding-a-service.md).
