# Tailscale für Admin-Zugriff

## Warum Tailscale?

- Mesh-VPN auf WireGuard-Basis, kein eigener VPN-Server nötig
- Funktioniert von überall (LTE, fremdes WLAN) ohne Port-Forwarding
- Mobile Apps für iOS/Android — Statusseite vom Handy
- Free Tier (bis 100 Geräte, 3 User) reicht für Privat-Setups
- Keys werden über Tailscale-Coordinator verteilt, **Datenpfad geht direkt P2P**

## Setup pro Node

```bash
curl -fsSL https://tailscale.com/install.sh | sh
tailscale up --ssh
```

`--ssh` aktiviert Tailscale-SSH — du kannst dich dann via `tailscale ssh root@proxy01` einloggen, auch wenn der reguläre OpenSSH-Server mal Probleme macht.

## ACL-Empfehlung

In der Tailscale-Admin-UI (`tailscale.com/admin/acls`) etwa so:

```jsonc
{
  "tagOwners": {
    "tag:proxy":  ["dein-account@..."],
    "tag:admin":  ["dein-account@..."]
  },
  "acls": [
    // Admin-Geräte dürfen alles auf den Proxies
    {
      "action": "accept",
      "src":    ["tag:admin"],
      "dst":    ["tag:proxy:*"]
    },
    // Proxies dürfen sich gegenseitig erreichen (für Cert-Sync)
    {
      "action": "accept",
      "src":    ["tag:proxy"],
      "dst":    ["tag:proxy:22,80,443,8080"]
    }
  ],
  "ssh": [
    {
      "action": "accept",
      "src":    ["tag:admin"],
      "dst":    ["tag:proxy"],
      "users":  ["root"]
    }
  ]
}
```

Beim `tailscale up` jeweils Tag setzen:
```bash
tailscale up --ssh --advertise-tags=tag:proxy
```

Eigene Endgeräte (Laptop, Handy) bekommen `tag:admin`.

## Statusseite via Tailscale erreichbar machen

Die Statusseite bindet (gemäß `proxy-status.service`) auf `${STATUS_BIND_IP}` aus values.env. Das ist die Tailscale-IP der jeweiligen Node — dadurch ist Port 8080 nur über das Tailscale-Interface erreichbar, **nicht** über die öffentliche IP.

Verifikation:

```bash
# Sollte funktionieren (im Tailscale-Netz):
curl http://$(tailscale ip -4):8080/api/health

# Sollte NICHT funktionieren (von außen):
curl http://<public-ip>:8080/api/health
```

## DNS in Tailscale

Tailscale's MagicDNS (in der Admin-UI aktivieren) macht die Hostnames direkt nutzbar:

```bash
curl http://proxy01:8080/
curl http://proxy02:8080/
```

Sehr bequem für Bookmarks und Scripts.

## Alternative: Headscale

Wer keinen US-Coordinator möchte, kann [Headscale](https://github.com/juanfont/headscale) selbst hosten — kompatibel zu den Tailscale-Clients. Mehr Aufwand, mehr Kontrolle. Für Einzelpersonen meist Overkill, aber gut zu wissen.

## Ports übersicht

| Port  | Zweck             | Wo erreichbar |
|-------|-------------------|---------------|
| 22    | SSH (klassisch)   | öffentlich (besser einschränken via ufw auf Tailscale) |
| 80    | nginx HTTP        | öffentlich (Floating-IP) |
| 443   | nginx HTTPS       | öffentlich (Floating-IP) |
| 8080  | Statusseite       | **nur Tailscale** |
| 8081  | nginx stub_status | nur localhost |

Optional: SSH komplett auf Tailscale beschränken:

```bash
ufw delete allow OpenSSH
ufw allow in on tailscale0 to any port 22
```
