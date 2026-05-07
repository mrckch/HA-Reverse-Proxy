# Service hinzufügen

## Workflow

Alle Änderungen passieren auf dem **lokalen Rechner** (Repo-Clone). Push zu GitHub → die VMs ziehen das Update binnen ~2 Minuten automatisch.

### 1. Service-Config erstellen

```bash
cd reverse-proxy
cp nginx/sites-available/example-service.conf nginx/sites-available/<servicename>.conf
```

In der neuen Datei anpassen:
- `server_name` → echte Domain(s)
- `proxy_pass` → Backend-IP:Port
- `ssl_certificate*` → Pfade an Domain anpassen (`/etc/letsencrypt/live/<domain>/...`)
- Optional: Rate-Limits, WebSocket-Snippet

### 2. Erst-Setup: HTTPS-Block auskommentieren

Beim allerersten Deploy gibt es noch kein Zertifikat — also den 443-Server-Block **auskommentieren** und nur den 80-Block (mit ACME-Challenge) committen:

```nginx
server {
    listen 80;
    server_name service1.example.com;
    include /etc/nginx/snippets/acme-challenge.conf;
    location / { return 200 "ok"; }
}
```

### 3. Commit + Push

```bash
git add nginx/sites-available/<servicename>.conf
git commit -m "Add <servicename> service"
git push
```

### 4. Auf MASTER aktivieren + Cert anfordern

Auf proxy01 (kann auch automatisiert werden, aber initial manuell sicherer):

```bash
ssh root@proxy01
cd /opt/reverse-proxy
# warten bis deploy.sh den Pull gemacht hat (max 2 Min) oder manuell:
./scripts/deploy.sh
./scripts/enable-site.sh <servicename>
./scripts/cert-request.sh service1.example.com
```

certbot fordert das Cert an, der Renewal-Hook synct es zu proxy02.

### 5. HTTPS-Block aktivieren

Lokal die auskommentierten 443-Zeilen einkommentieren und 80er auf Redirect umstellen (siehe `example-service.conf`):

```bash
git commit -am "Enable HTTPS for <servicename>"
git push
```

Nach max. 2 Min ist der Service auf beiden Nodes über HTTPS erreichbar.

### 6. Auf BACKUP aktivieren

```bash
ssh root@proxy02
/opt/reverse-proxy/scripts/enable-site.sh <servicename>
```

(Symlinks werden bewusst nicht über Git verteilt, damit du auf einem Node testen kannst, bevor der andere übernimmt.)

## Service deaktivieren

```bash
ssh root@proxy01 "rm /etc/nginx/sites-enabled/<servicename>.conf && systemctl reload nginx"
ssh root@proxy02 "rm /etc/nginx/sites-enabled/<servicename>.conf && systemctl reload nginx"
```

Die `.conf`-Datei in `sites-available/` bleibt (über Git verwaltet) — kann bei Bedarf wieder enabled werden.

## Service entfernen

1. Auf beiden Nodes deaktivieren (siehe oben)
2. Datei aus `sites-available/` löschen, committen, pushen
3. Optional Cert revoken: `certbot revoke --cert-name <domain>` auf MASTER
