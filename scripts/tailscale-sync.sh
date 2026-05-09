#!/bin/bash
# scripts/tailscale-sync.sh
#
# Synchronisiert die Tailscale-IPs in /etc/proxy-config/values.env:
#   - STATUS_BIND_IP        ← eigene Tailscale-IP (statt 127.0.0.1-Fallback)
#   - PEER_TAILSCALE_IP     ← Tailscale-IP der Peer-Node (über PEER_NAME)
#
# Lädt proxy-status nur dann neu, wenn sich tatsächlich etwas geändert hat.
# Idempotent. No-op wenn Tailscale nicht läuft (kein Crash, kein Lärm).
#
# Aufrufe:
#   ./tailscale-sync.sh              # einmal syncen (auch was der Timer ruft)
#   ./tailscale-sync.sh --install    # systemd-Timer installieren + ersten Sync
#   ./tailscale-sync.sh --uninstall  # Timer/Service wieder entfernen
#   ./tailscale-sync.sh --dry-run    # nur ausgeben was sich ändern würde
#
# Wird vom Bootstrap automatisch installiert (phase_b_tailscale_sync_timer).
# Auf bestehenden Nodes nachträglich:
#   cd /opt/reverse-proxy && git pull --ff-only
#   tailscale up --ssh --hostname=$(hostname)   # falls noch nicht aktiv
#   ./scripts/tailscale-sync.sh --install

set -euo pipefail

VALUES_ENV=/etc/proxy-config/values.env
SERVICE_FILE=/etc/systemd/system/proxy-tailscale-sync.service
TIMER_FILE=/etc/systemd/system/proxy-tailscale-sync.timer
SCRIPT_DEST=/usr/local/sbin/proxy-tailscale-sync

DRY_RUN=0
ACTION=sync

# ============================================================================
# Argumente
# ============================================================================
while [[ $# -gt 0 ]]; do
    case "$1" in
        --install)   ACTION=install; shift ;;
        --uninstall) ACTION=uninstall; shift ;;
        --dry-run)   DRY_RUN=1; shift ;;
        -h|--help)
            sed -n '2,/^$/p' "$0" | sed 's/^# \?//'
            exit 0 ;;
        *) echo "Unbekanntes Argument: $1" >&2; exit 1 ;;
    esac
done

[[ $EUID -eq 0 ]] || { echo "FEHLER: als root ausführen" >&2; exit 1; }

# ============================================================================
# Sync-Logik (auch was der Timer aufruft)
# ============================================================================
do_sync() {
    if [[ ! -f "$VALUES_ENV" ]]; then
        echo "→ $VALUES_ENV existiert nicht — Bootstrap noch nicht durch?"
        return 0
    fi

    # Eigene Tailscale-IP
    local own_ip=""
    if command -v tailscale >/dev/null 2>&1; then
        own_ip=$(tailscale ip -4 2>/dev/null | head -1 || true)
    fi

    if [[ -z "$own_ip" ]]; then
        # Tailscale läuft nicht oder ist nicht angemeldet — graceful exit
        echo "→ keine Tailscale-IP gefunden (tailscale up noch nicht gemacht?)"
        return 0
    fi

    # shellcheck disable=SC1090
    source "$VALUES_ENV"

    local changed=0

    # STATUS_BIND_IP nachziehen
    if [[ "${STATUS_BIND_IP:-}" != "$own_ip" ]]; then
        echo "→ STATUS_BIND_IP: ${STATUS_BIND_IP:-<leer>} → $own_ip"
        if [[ $DRY_RUN -eq 0 ]]; then
            sed -i -E "s|^STATUS_BIND_IP=.*|STATUS_BIND_IP=${own_ip}|" "$VALUES_ENV"
            changed=1
        fi
    fi

    # Peer-Tailscale-IP via 'tailscale status --json' anhand PEER_NAME
    if [[ -n "${PEER_NAME:-}" ]] && command -v jq >/dev/null 2>&1; then
        local peer_ip
        peer_ip=$(tailscale status --json 2>/dev/null \
            | jq -r --arg n "$PEER_NAME" \
                '.Peer // {} | to_entries[] | select(.value.HostName==$n) | .value.TailscaleIPs[0]' \
            2>/dev/null | head -1 || true)

        if [[ -n "$peer_ip" && "${PEER_TAILSCALE_IP:-}" != "$peer_ip" ]]; then
            echo "→ PEER_TAILSCALE_IP ($PEER_NAME): ${PEER_TAILSCALE_IP:-<leer>} → $peer_ip"
            if [[ $DRY_RUN -eq 0 ]]; then
                sed -i -E "s|^PEER_TAILSCALE_IP=.*|PEER_TAILSCALE_IP=${peer_ip}|" "$VALUES_ENV"
                changed=1
            fi
        fi
    fi

    if [[ $changed -eq 1 ]]; then
        echo "→ proxy-status neuladen"
        systemctl reload-or-restart proxy-status.service 2>/dev/null \
            || echo "WARN: proxy-status reload schlug fehl (Service nicht da?)"
    elif [[ $DRY_RUN -eq 1 ]]; then
        echo "→ (dry-run) keine Änderung"
    else
        echo "→ keine Änderung nötig"
    fi
}

# ============================================================================
# Install-Modus: systemd-Units anlegen + enablen
# ============================================================================
do_install() {
    echo "→ Installiere systemd-Timer (proxy-tailscale-sync)"

    install -m 0755 "$0" "$SCRIPT_DEST"

    cat > "$SERVICE_FILE" <<'EOF'
[Unit]
Description=Sync Tailscale-IPs in proxy values.env
After=tailscaled.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/proxy-tailscale-sync
Nice=10
EOF

    cat > "$TIMER_FILE" <<'EOF'
[Unit]
Description=Run proxy-tailscale-sync every 10 minutes (and 1 min after boot)
After=network-online.target

[Timer]
OnBootSec=1min
OnUnitActiveSec=10min
RandomizedDelaySec=20s
Persistent=true

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
    systemctl enable --now proxy-tailscale-sync.timer
    echo "→ Timer aktiv:"
    systemctl list-timers proxy-tailscale-sync.timer --no-pager 2>/dev/null \
        | sed -n '1,3p'

    echo
    echo "→ Erster Sync-Lauf jetzt:"
    do_sync
}

# ============================================================================
# Uninstall-Modus
# ============================================================================
do_uninstall() {
    echo "→ Entferne systemd-Timer (proxy-tailscale-sync)"
    systemctl disable --now proxy-tailscale-sync.timer 2>/dev/null || true
    systemctl disable --now proxy-tailscale-sync.service 2>/dev/null || true
    rm -f "$SERVICE_FILE" "$TIMER_FILE" "$SCRIPT_DEST"
    systemctl daemon-reload
    echo "→ Entfernt."
}

# ============================================================================
# Dispatch
# ============================================================================
case "$ACTION" in
    sync)      do_sync ;;
    install)   do_install ;;
    uninstall) do_uninstall ;;
esac
