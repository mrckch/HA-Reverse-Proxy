#!/bin/bash
# scripts/cert-renewal-hook.sh
# Wird von certbot nach erfolgreichem Renewal aufgerufen.
# Synct /etc/letsencrypt/ via SSH/Tailscale zur BACKUP-Node und reloaded dort nginx.

set -euo pipefail

source /etc/proxy-config/values.env

LOG=/var/log/cert-sync.log

log() {
    echo "$(date -Iseconds) $*" >> "$LOG"
}

# Lokal nginx reloaden
systemctl reload nginx
log "MASTER: nginx reloaded nach Renewal"

# Sync zu BACKUP
if [[ -z "${PEER_TAILSCALE_IP:-}" ]]; then
    log "WARN: PEER_TAILSCALE_IP nicht gesetzt — kein Sync"
    exit 0
fi

# rsync via SSH (Tailscale-IP, key-basierter Auth, kein Passwort)
rsync -az --delete \
    -e "ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10" \
    /etc/letsencrypt/ \
    "root@${PEER_TAILSCALE_IP}:/etc/letsencrypt/" \
    2>>"$LOG"

log "Cert-Sync zu $PEER_TAILSCALE_IP abgeschlossen"

# nginx auf BACKUP reloaden
ssh -o StrictHostKeyChecking=accept-new "root@${PEER_TAILSCALE_IP}" \
    "systemctl reload nginx" 2>>"$LOG"

log "BACKUP: nginx reloaded"
