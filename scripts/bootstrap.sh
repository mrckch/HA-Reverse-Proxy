#!/bin/bash
# scripts/bootstrap.sh
#
# Initial-Setup einer frischen Debian-12-VM zu einem Proxy-Node.
# Idempotent — kann bei Bedarf erneut ausgeführt werden.
#
# Aufruf:
#   sudo ./bootstrap.sh master    # für proxy01
#   sudo ./bootstrap.sh backup    # für proxy02

set -euo pipefail

ROLE="${1:-}"
if [[ "$ROLE" != "master" && "$ROLE" != "backup" ]]; then
    echo "Usage: $0 master|backup"
    exit 1
fi

REPO_DIR=/opt/reverse-proxy
CONFIG_DIR=/etc/proxy-config

if [[ $EUID -ne 0 ]]; then
    echo "Bitte als root ausführen."
    exit 1
fi

echo "=== [1/9] System-Update ==="
apt-get update
apt-get upgrade -y

echo "=== [2/9] Pakete installieren ==="
apt-get install -y \
    nginx \
    keepalived \
    certbot python3-certbot-nginx \
    fail2ban \
    ufw \
    git \
    curl wget \
    python3 python3-venv python3-pip \
    rsync \
    openssl \
    jq \
    unattended-upgrades

echo "=== [3/9] Tailscale installieren ==="
if ! command -v tailscale >/dev/null 2>&1; then
    curl -fsSL https://tailscale.com/install.sh | sh
fi
echo "→ Bitte später manuell: tailscale up --ssh"

echo "=== [4/9] Verzeichnisse anlegen ==="
mkdir -p "$CONFIG_DIR"
mkdir -p /var/www/letsencrypt
mkdir -p /etc/nginx/ssl
mkdir -p /var/log/proxy-status

if [[ ! -f "$CONFIG_DIR/values.env" ]]; then
    if [[ -f "$REPO_DIR/values.env.example" ]]; then
        cp "$REPO_DIR/values.env.example" "$CONFIG_DIR/values.env"
        chmod 600 "$CONFIG_DIR/values.env"
        echo "!! ACHTUNG: $CONFIG_DIR/values.env aus Beispiel angelegt."
        echo "!! Bitte anpassen, bevor Services konfiguriert werden."
    fi
fi

echo "=== [5/9] DH-Parameter und Default-Cert ==="
if [[ ! -f /etc/nginx/ssl/dhparam.pem ]]; then
    openssl dhparam -out /etc/nginx/ssl/dhparam.pem 2048
fi
if [[ ! -f /etc/nginx/ssl/default.crt ]]; then
    openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
        -keyout /etc/nginx/ssl/default.key \
        -out    /etc/nginx/ssl/default.crt \
        -subj "/CN=default"
fi

echo "=== [6/9] User für Statusseite ==="
if ! id proxy-status >/dev/null 2>&1; then
    useradd -r -s /usr/sbin/nologin -d /opt/reverse-proxy/status proxy-status
fi
chown -R proxy-status:proxy-status /var/log/proxy-status

echo "=== [7/9] Python-venv für Statusseite ==="
if [[ -d "$REPO_DIR/status" ]]; then
    if [[ ! -d "$REPO_DIR/status/venv" ]]; then
        python3 -m venv "$REPO_DIR/status/venv"
    fi
    "$REPO_DIR/status/venv/bin/pip" install --upgrade pip
    "$REPO_DIR/status/venv/bin/pip" install -r "$REPO_DIR/status/requirements.txt"
    chown -R proxy-status:proxy-status "$REPO_DIR/status/venv"
fi

echo "=== [8/9] Firewall ==="
ufw default deny incoming
ufw default allow outgoing
ufw allow OpenSSH
ufw allow 80/tcp
ufw allow 443/tcp
# Tailscale
ufw allow in on tailscale0
ufw --force enable

echo "=== [9/9] keepalived-Helpers installieren ==="
install -m 0755 "$REPO_DIR/keepalived/check_nginx.sh"      /usr/local/bin/check_nginx.sh
install -m 0755 "$REPO_DIR/keepalived/notify_keepalived.sh" /usr/local/bin/notify_keepalived.sh

echo ""
echo "=========================================="
echo " Bootstrap abgeschlossen — Rolle: $ROLE"
echo "=========================================="
echo ""
echo "Nächste Schritte:"
echo "  1. tailscale up --ssh   (und Tailscale-IP in values.env eintragen)"
echo "  2. $CONFIG_DIR/values.env anpassen"
echo "  3. ./scripts/deploy.sh ausführen"
echo "  4. Erste Domain mit ./scripts/cert-request.sh <domain> anfordern"
