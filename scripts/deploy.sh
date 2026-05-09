#!/bin/bash
# scripts/deploy.sh
#
# Synct die Configs aus dem Git-Repo nach /etc/nginx und /etc/keepalived,
# testet die nginx-Config, reloaded bei Erfolg.
# Wird vom systemd-timer alle 2 Minuten aufgerufen.

set -euo pipefail

REPO_DIR=/opt/reverse-proxy
LOG=/var/log/proxy-deploy.log

log() {
    echo "$(date -Iseconds) $*" | tee -a "$LOG"
}

cd "$REPO_DIR"

# === 1. Git pull ===
BEFORE=$(git rev-parse HEAD)
git fetch --quiet origin
git reset --hard --quiet origin/main
AFTER=$(git rev-parse HEAD)

if [[ "$BEFORE" == "$AFTER" ]]; then
    # Kein Update — leise beenden
    exit 0
fi

log "Update von $BEFORE → $AFTER"

# === 2. nginx-Configs synchronisieren ===
# Hauptkonfig
rsync -a --checksum nginx/nginx.conf /etc/nginx/nginx.conf

# conf.d (globale Snippets)
rsync -a --checksum --delete nginx/conf.d/ /etc/nginx/conf.d/

# Snippets
rsync -a --checksum --delete nginx/snippets/ /etc/nginx/snippets/

# sites-available (sites-enabled wird über enable-site.sh manuell verlinkt)
rsync -a --checksum --delete nginx/sites-available/ /etc/nginx/sites-available/

# === 3. keepalived-Config ===
NODE_ROLE=$(grep -E "^NODE_ROLE=" /etc/proxy-config/values.env | cut -d= -f2 | tr -d '"')
if [[ "$NODE_ROLE" == "MASTER" ]]; then
    cp keepalived/keepalived-master.conf /etc/keepalived/keepalived.conf
else
    cp keepalived/keepalived-backup.conf /etc/keepalived/keepalived.conf
fi
install -m 0755 keepalived/check_nginx.sh      /usr/local/bin/check_nginx.sh
install -m 0755 keepalived/notify_keepalived.sh /usr/local/bin/notify_keepalived.sh

# === 4. nginx testen ===
if ! nginx -t 2>>"$LOG"; then
    log "FEHLER: nginx -t fehlgeschlagen — kein reload"
    exit 1
fi

# === 5. Reload ===
systemctl reload nginx
log "nginx reloaded"

# Falls keepalived-Config sich geändert hat
if ! diff -q /etc/keepalived/keepalived.conf <(cat keepalived/keepalived-${NODE_ROLE,,}.conf) >/dev/null 2>&1; then
    systemctl reload keepalived || systemctl restart keepalived
    log "keepalived reloaded"
fi

# === 6. Statusseite ggf. neu starten ===
if git diff --name-only "$BEFORE" "$AFTER" | grep -q "^status/"; then
    "$REPO_DIR/status/venv/bin/pip" install -r "$REPO_DIR/status/requirements.txt" --quiet
    systemctl restart proxy-status
    log "proxy-status restarted"
fi

log "Deploy erfolgreich"
