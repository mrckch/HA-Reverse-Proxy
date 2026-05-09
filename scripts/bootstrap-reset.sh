#!/bin/bash
# scripts/bootstrap-reset.sh
#
# Setzt das HA-Reverse-Proxy-Bootstrap auf einer VM zurück, sodass ein
# erneuter './scripts/bootstrap.sh'-Lauf auf dem gleichen Host sauber
# durchläuft. Hilfreich, wenn ein Bootstrap-Lauf abgebrochen ist (z.B.
# falscher Deploy-Key, Tippfehler bei der IP, generelles "ich will von
# vorn anfangen").
#
# Aufruf:
#   ./scripts/bootstrap-reset.sh             # Soft-Reset (Phase-A-State)
#   ./scripts/bootstrap-reset.sh --full      # zusätzlich Phase-B-State
#   ./scripts/bootstrap-reset.sh --no-keep-key   # SSH-Deploy-Key auch weg
#   ./scripts/bootstrap-reset.sh --dry-run   # nur Plan ausgeben
#   ./scripts/bootstrap-reset.sh -y          # ohne Rückfrage
#
# WAS NICHT GETOUCHT WIRD (bewusst):
#   - /etc/letsencrypt/   — dort liegen echte Zertifikate, Re-Issue
#                           würde am Let's-Encrypt-Rate-Limit knabbern.
#   - /etc/network/interfaces  — Mid-flight-Änderung würde die SSH-
#                           Session killen. Nächster Bootstrap-Lauf
#                           schreibt das eh neu, falls IP-Wechsel.
#   - Installierte Pakete (nginx, keepalived, tailscale, certbot, …) —
#                           idempotent installierbar, 'apt purge' wäre
#                           Zeitverschwendung.

set -euo pipefail

# ============================================================================
# Konstanten — müssen mit bootstrap.sh übereinstimmen
# ============================================================================
PROJECT=proxy
REPO_DIR=/opt/reverse-proxy
CONFIG_DIR=/etc/proxy-config
BOOTSTRAP_CONF=/etc/${PROJECT}-bootstrap.conf
BOOTSTRAP_BIN=/usr/local/sbin/${PROJECT}-bootstrap
RESUME_SERVICE=${PROJECT}-bootstrap-resume.service
LOG=/var/log/${PROJECT}-bootstrap.log
SSH_KEY=/root/.ssh/id_ed25519_${PROJECT}

# Defaults
KEEP_KEY=1
FULL=0
DRY_RUN=0
ASSUME_YES=0

# ============================================================================
# Helpers
# ============================================================================
err()  { echo "FEHLER: $*" >&2; exit 1; }
info() { echo "→ $*"; }
warn() { echo "WARN: $*" >&2; }

usage() {
    cat <<EOF
bootstrap-reset.sh — Setup eines Bootstrap-Laufs zurücknehmen

Optionen:
  --full          Zusätzlich Phase-B-Artefakte entfernen (values.env,
                  proxy-status/proxy-deploy services, cron, sudoers,
                  logrotate, unattended-upgrades-Configs).
  --no-keep-key   SSH-Deploy-Key (${SSH_KEY}{,.pub}) auch löschen —
                  WICHTIG: dann auch den Deploy-Key in GitHub entfernen
                  (Repo → Settings → Deploy keys), sonst stale Eintrag.
  --dry-run       Nur ausgeben, was passieren würde — keine Änderung.
  -y, --yes       Confirmation überspringen.
  -h, --help      Diese Hilfe.

Beispiele:
  $0                      # Phase-A-Reset, Key bleibt, mit Rückfrage
  $0 --full -y            # Phase A + B, Key bleibt, ohne Rückfrage
  $0 --full --no-keep-key # alles inklusive Key (für komplett frischen Run)

Was bleibt unangetastet: /etc/letsencrypt/ (Certs!),
/etc/network/interfaces (SSH-Killer-Risiko), installierte Pakete.
Für einen *wirklich* sauberen Reset: VM in Proxmox neu aufsetzen
(siehe scripts/proxmox-create-vm.sh).
EOF
}

# Führt einen Schritt aus oder zeigt ihn nur (dry-run). Idempotent —
# scheitert nicht hart, wenn das zu löschende Ding schon weg ist.
run_step() {
    local desc=$1
    shift
    info "$desc"
    if [[ "$DRY_RUN" -eq 1 ]]; then
        printf '   [dry-run] %s\n' "$*"
    else
        "$@" || warn "Schritt '$desc' nicht vollständig erfolgreich (Datei/Service evtl. schon weg)"
    fi
}

# ============================================================================
# Argument-Parsing
# ============================================================================
while [[ $# -gt 0 ]]; do
    case "$1" in
        --full)         FULL=1; shift ;;
        --no-keep-key)  KEEP_KEY=0; shift ;;
        --dry-run)      DRY_RUN=1; shift ;;
        -y|--yes)       ASSUME_YES=1; shift ;;
        -h|--help)      usage; exit 0 ;;
        *)              err "Unbekanntes Argument: $1 (siehe --help)" ;;
    esac
done

[[ $EUID -eq 0 ]] || err "Bitte als root ausführen."

# ============================================================================
# Plan-Anzeige + Bestätigung
# ============================================================================
echo
echo "==================== Reset-Plan ===================="
echo "  Phase-A-State entfernen          : ja"
echo "  Phase-B-State entfernen          : $([[ $FULL -eq 1 ]] && echo "ja (--full)" || echo "nein")"
echo "  SSH-Deploy-Key löschen           : $([[ $KEEP_KEY -eq 0 ]] && echo "JA — danach in GitHub entfernen!" || echo "nein (bleibt)")"
echo "  Modus                            : $([[ $DRY_RUN -eq 1 ]] && echo "dry-run (keine Änderung)" || echo "echte Änderung")"
echo "===================================================="
echo

if [[ "$ASSUME_YES" -ne 1 && "$DRY_RUN" -ne 1 ]]; then
    read -rp "Fortfahren? [yes/NO] " ans
    [[ "$ans" == "yes" ]] || { echo "Abgebrochen."; exit 0; }
fi

# ============================================================================
# Phase-A-Reset (Default)
# ============================================================================
echo
echo "=== Phase-A-Reset ==="

run_step "Resume-Service stoppen + entfernen" bash -c "
    systemctl disable --now ${RESUME_SERVICE} 2>/dev/null || true
    rm -f /etc/systemd/system/${RESUME_SERVICE}
    rm -f ${BOOTSTRAP_BIN}
"

run_step "Bootstrap-Config wegwerfen ($BOOTSTRAP_CONF)" bash -c "
    if [[ -f ${BOOTSTRAP_CONF} ]]; then
        shred -u ${BOOTSTRAP_CONF} 2>/dev/null || rm -f ${BOOTSTRAP_CONF}
    fi
"

run_step "Bootstrap-Log wegwerfen ($LOG)" rm -f "$LOG"

run_step "/etc/resolv.conf wieder editierbar machen" bash -c "
    chattr -i /etc/resolv.conf 2>/dev/null || true
"

# ============================================================================
# Phase-B-Reset (--full)
# ============================================================================
if [[ "$FULL" -eq 1 ]]; then
    echo
    echo "=== Phase-B-Reset (--full) ==="

    run_step "proxy-deploy.timer + .service entfernen" bash -c "
        systemctl disable --now proxy-deploy.timer 2>/dev/null || true
        systemctl disable --now proxy-deploy.service 2>/dev/null || true
        rm -f /etc/systemd/system/proxy-deploy.timer /etc/systemd/system/proxy-deploy.service
    "

    run_step "proxy-status.service entfernen" bash -c "
        systemctl disable --now proxy-status.service 2>/dev/null || true
        rm -f /etc/systemd/system/proxy-status.service
    "

    run_step "values.env + Config-Dir wegwerfen ($CONFIG_DIR)" bash -c "
        if [[ -f ${CONFIG_DIR}/values.env ]]; then
            shred -u ${CONFIG_DIR}/values.env 2>/dev/null || rm -f ${CONFIG_DIR}/values.env
        fi
        rmdir ${CONFIG_DIR} 2>/dev/null || true
    "

    run_step "cron + sudoers + logrotate aufräumen" bash -c "
        rm -f /etc/cron.d/proxy-status
        rm -f /etc/sudoers.d/proxy-status
        rm -f /etc/logrotate.d/proxy
    "

    run_step "Status-State + Logs wegwerfen" bash -c "
        rm -rf /var/log/proxy-status
        rm -rf /var/lib/proxy-status
    "

    run_step "Unattended-Upgrades-Configs entfernen (Distro-Defaults bleiben)" bash -c "
        rm -f /etc/apt/apt.conf.d/20auto-upgrades
        rm -f /etc/apt/apt.conf.d/50unattended-upgrades
    "

    run_step "keepalived-Helper-Skripte entfernen" bash -c "
        rm -f /usr/local/bin/check_nginx.sh /usr/local/bin/notify_keepalived.sh
    "

    # proxy-status User: rauswerfen wenn er existiert
    if id proxy-status >/dev/null 2>&1; then
        run_step "proxy-status User entfernen" userdel -f proxy-status
    fi
fi

# ============================================================================
# SSH-Deploy-Key (--no-keep-key)
# ============================================================================
if [[ "$KEEP_KEY" -eq 0 ]]; then
    echo
    echo "=== SSH-Deploy-Key entfernen ==="
    run_step "$SSH_KEY{,.pub} wegwerfen" bash -c "
        rm -f ${SSH_KEY} ${SSH_KEY}.pub
    "
    warn "Vergiss nicht: alten Deploy-Key in GitHub löschen"
    warn "  Repo → Settings → Deploy keys"
fi

# ============================================================================
# Cleanup-Final
# ============================================================================
echo
run_step "systemctl daemon-reload" systemctl daemon-reload

# ============================================================================
# Abschluss-Hinweis
# ============================================================================
cat <<EOF

================================================================
 Reset abgeschlossen$([[ $DRY_RUN -eq 1 ]] && echo " (dry-run)").
================================================================

Nächster Schritt — Bootstrap erneut starten:

  cd ${REPO_DIR}
  git pull --ff-only
  ./scripts/bootstrap.sh

EOF
