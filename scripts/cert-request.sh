#!/bin/bash
# scripts/cert-request.sh
# Fordert ein Let's-Encrypt-Zertifikat per http-01 an.
# Nur auf MASTER ausführen — der Sync-Hook kopiert es auf BACKUP.

set -euo pipefail

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <domain> [<weitere-domain> ...]"
    echo "Beispiel: $0 service1.example.com www.service1.example.com"
    exit 1
fi

source /etc/proxy-config/values.env

if [[ "${NODE_ROLE:-}" != "MASTER" ]]; then
    echo "FEHLER: Zertifikate nur auf MASTER anfordern."
    exit 1
fi

DOMAINS=()
for d in "$@"; do
    DOMAINS+=("-d" "$d")
done

certbot certonly \
    --webroot -w /var/www/letsencrypt \
    --email "$ACME_EMAIL" \
    --agree-tos \
    --no-eff-email \
    --keep-until-expiring \
    --deploy-hook /opt/reverse-proxy/scripts/cert-renewal-hook.sh \
    "${DOMAINS[@]}"

echo ""
echo "→ Zertifikat gespeichert. Sync zu BACKUP via deploy-hook."
