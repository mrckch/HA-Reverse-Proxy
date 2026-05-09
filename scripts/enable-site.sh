#!/bin/bash
# scripts/enable-site.sh
# Aktiviert eine Service-Config durch Symlink von sites-available → sites-enabled

set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "Usage: $0 <service-name>"
    echo ""
    echo "Verfügbare Services:"
    ls /etc/nginx/sites-available/ | sed 's/\.conf$//' | sed 's/^/  /'
    exit 1
fi

SERVICE="$1"
AVAIL=/etc/nginx/sites-available/${SERVICE}.conf
ENABLED=/etc/nginx/sites-enabled/${SERVICE}.conf

if [[ ! -f "$AVAIL" ]]; then
    echo "FEHLER: $AVAIL existiert nicht"
    exit 1
fi

ln -sf "$AVAIL" "$ENABLED"
echo "→ $SERVICE aktiviert"

if nginx -t; then
    systemctl reload nginx
    echo "→ nginx reloaded"
else
    rm "$ENABLED"
    echo "FEHLER: Config-Test fehlgeschlagen, Symlink wieder entfernt"
    exit 1
fi
