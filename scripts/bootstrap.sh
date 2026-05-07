#!/bin/bash
# scripts/bootstrap.sh
#
# HA-Reverse-Proxy Bootstrap-Assistent.
# Zwei Phasen, idempotent, IP-Wechsel-resilient, mit whiptail-TUI.
#
# Aufruf:
#   sudo ./scripts/bootstrap.sh             # interaktiv (Phase A + B)
#   sudo ./scripts/bootstrap.sh --resume    # nach IP-Wechsel automatisch (Phase B)
#
# Logging: alles nach /var/log/proxy-bootstrap.log

set -euo pipefail

# ============================================================================
# Konstanten
# ============================================================================
PROJECT=proxy
REPO_DIR=/opt/reverse-proxy
CONFIG_DIR=/etc/proxy-config
BOOTSTRAP_CONF=/etc/${PROJECT}-bootstrap.conf
BOOTSTRAP_BIN=/usr/local/sbin/${PROJECT}-bootstrap
RESUME_SERVICE=${PROJECT}-bootstrap-resume.service
LOG=/var/log/${PROJECT}-bootstrap.log
SSH_KEY=/root/.ssh/id_ed25519_${PROJECT}

RESUMING=0
[[ "${1:-}" == "--resume" ]] && RESUMING=1

# ============================================================================
# Logging
# ============================================================================
mkdir -p "$(dirname "$LOG")"
exec > >(tee -a "$LOG") 2>&1
echo
echo "================================================================"
echo " $(date -Iseconds)  bootstrap started  (pid=$$, resume=$RESUMING)"
echo "================================================================"

# ============================================================================
# Basis-Helpers
# ============================================================================
require_root() {
    if [[ $EUID -ne 0 ]]; then
        echo "FEHLER: Bitte als root ausführen (sudo ...)"
        exit 1
    fi
}

require_debian() {
    if ! grep -qi "debian" /etc/os-release 2>/dev/null; then
        echo "WARN: Dieses Script ist für Debian 12 entwickelt."
        read -rp "Trotzdem fortfahren? [yes/NO] " ans
        [[ "$ans" == "yes" ]] || exit 1
    fi
}

ensure_tools() {
    local missing=()
    for t in whiptail jq dig tee curl awk sed; do
        command -v "$t" >/dev/null 2>&1 || missing+=("$t")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        echo "Installiere fehlende Tools: ${missing[*]}"
        apt-get update -qq
        apt-get install -y whiptail jq dnsutils coreutils gawk sed curl
    fi
}

# ============================================================================
# whiptail-Wrapper mit Erklärtexten
# ============================================================================
WT_HEIGHT=22
WT_WIDTH=78

wt_msg()    { whiptail --title "$1" --msgbox "$2" "$WT_HEIGHT" "$WT_WIDTH"; }
wt_yesno()  { whiptail --title "$1" --yesno  "$2" "$WT_HEIGHT" "$WT_WIDTH"; }

wt_input() {
    whiptail --title "$1" --inputbox "$2" "$WT_HEIGHT" "$WT_WIDTH" "${3:-}" 3>&1 1>&2 2>&3
}

wt_password() {
    whiptail --title "$1" --passwordbox "$2" "$WT_HEIGHT" "$WT_WIDTH" 3>&1 1>&2 2>&3
}

wt_radio() {
    local title="$1" text="$2"; shift 2
    whiptail --title "$title" --radiolist "$text" "$WT_HEIGHT" "$WT_WIDTH" 6 "$@" 3>&1 1>&2 2>&3
}

# Validierte Eingabe — wiederholt bis valide
ask_validated() {
    local title="$1" text="$2" default="$3" regex="$4" errtext="$5"
    local val
    while true; do
        val=$(wt_input "$title" "$text" "$default") || exit 1
        if [[ "$val" =~ $regex ]]; then
            echo "$val"
            return 0
        fi
        wt_msg "Ungültige Eingabe" "$errtext"$'\n\nDeine Eingabe: '"$val"
    done
}

# ============================================================================
# Phase A — Bildschirme
# ============================================================================
welcome() {
    wt_msg "HA-Reverse-Proxy Bootstrap" \
"Willkommen.

Dieser Assistent richtet diese VM als eine Hälfte eines hochverfügbaren \
Reverse-Proxy-Pärchens (proxy01 + proxy02) ein.

Was passiert:

1. Phase A (jetzt): Du beantwortest ~10 Fragen. Jede mit Erklärung.
   Die Antworten werden in /etc/proxy-bootstrap.conf gespeichert.

2. Falls du die IP der VM änderst, startet die VM danach neu.
   Sobald sie unter der neuen IP erreichbar ist, läuft Phase B
   automatisch weiter — du musst dich nur über die neue IP einloggen.

3. Phase B (automatisch): Pakete installieren, Tailscale, Repo klonen,
   nginx + keepalived konfigurieren, Statusseite starten.

Dauer insgesamt: ca. 10–15 Minuten.

Du kannst den Assistenten jederzeit mit ESC abbrechen — bisher gemachte \
Eingaben gehen verloren, aber die VM bleibt unverändert."
}

collect_role() {
    wt_radio "Schritt 1/10: Rolle dieser Node" \
"Diese Node soll die Rolle MASTER oder BACKUP übernehmen.

MASTER: Hält im Normalbetrieb die Floating-IP. Nur hier laufen
        Cert-Erneuerungen (certbot). Empfehlung: priority=100.

BACKUP: Übernimmt die Floating-IP automatisch, wenn MASTER ausfällt.
        Empfängt Zertifikate vom MASTER per rsync (über Tailscale).
        Empfehlung: priority=90.

Beide Nodes betreiben nginx parallel — die Rolle bestimmt nur, WER
die Floating-IP hält und WO certbot läuft. Bei Failover wechselt
die IP innerhalb von ~3 Sekunden." \
        "MASTER" "Primärer Knoten (proxy01)" ON \
        "BACKUP" "Sekundärer Knoten (proxy02)" OFF
}

collect_hostname() {
    local default="proxy01"
    [[ "$NODE_ROLE" == "BACKUP" ]] && default="proxy02"
    ask_validated "Schritt 2/10: Hostname dieser Node" \
"Hostname für diese VM.

Konvention: proxy01 für MASTER, proxy02 für BACKUP. Der Hostname \
wird im /etc/hostname gesetzt und ist auch in der Statusseite \
sichtbar. Nur Buchstaben, Ziffern und Bindestrich; Länge 1–63." \
        "$default" \
        '^[a-zA-Z0-9][a-zA-Z0-9-]{0,62}$' \
        "Hostname: nur a-z, A-Z, 0-9, '-'; nicht mit '-' beginnen; max 63 Zeichen."
}

collect_interface() {
    mapfile -t ifaces < <(ip -o link show | awk -F': ' '{print $2}' | grep -vE '^(lo|docker|tailscale|br-|veth)')

    if [[ ${#ifaces[@]} -eq 0 ]]; then
        wt_msg "FEHLER" "Kein passendes Netzwerk-Interface gefunden."
        exit 1
    fi

    local current_iface
    current_iface=$(ip -o -4 route show default | awk '{print $5}' | head -1)

    local args=()
    for i in "${ifaces[@]}"; do
        local mac
        mac=$(cat "/sys/class/net/$i/address" 2>/dev/null || echo "?")
        local on=OFF
        [[ "$i" == "$current_iface" ]] && on=ON
        args+=("$i" "MAC ${mac}" "$on")
    done

    wt_radio "Schritt 3/10: Netzwerk-Interface" \
"Welches Interface soll für die VRRP-Floating-IP genutzt werden?

Normalerweise das Interface mit der Default-Route (vorausgewählt). \
Wenn deine VM nur ein Interface hat, ist die Wahl trivial.

In Proxmox-VMs ist das meist 'eth0', 'ens18' oder 'enp0s3'. Das \
gewählte Interface MUSS später auch auf der zweiten Node existieren \
(sonst klappt VRRP nicht)." \
        "${args[@]}"
}

collect_static_ip() {
    local default_ip default_gw
    default_ip=$(ip -o -4 addr show "$VRRP_INTERFACE" 2>/dev/null | awk '{print $4}' | head -1)
    default_gw=$(ip -o -4 route show default | awk '{print $3}' | head -1)

    NODE_IP=$(ask_validated "Schritt 4a/10: Statische IP dieser Node" \
"Statische IP dieser Node mit CIDR-Maske, z.B. 192.168.1.10/24

Diese IP gehört NUR dieser VM (nicht die Floating-IP — die kommt \
gleich). Sie wird über systemd-networkd gesetzt. Wenn du eine andere \
IP einträgst als die aktuelle, wird die VM nach Phase A neu gestartet \
und Phase B läuft danach unter der neuen IP weiter." \
        "$default_ip" \
        '^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$' \
        "Format: IP/CIDR, z.B. 192.168.1.10/24")

    NODE_GW=$(ask_validated "Schritt 4b/10: Gateway" \
"IP-Adresse des Standard-Gateways (Router) ohne Maske, z.B. 192.168.1.1

Das ist die IP deines Routers im LAN — diese Node nutzt sie für \
Internet-Zugriff (apt update, certbot, GitHub-Clone). Muss im selben \
Subnetz liegen wie die statische IP oben." \
        "$default_gw" \
        '^([0-9]{1,3}\.){3}[0-9]{1,3}$' \
        "Format: IP-Adresse ohne Maske, z.B. 192.168.1.1")
}

collect_floating_ip() {
    FLOATING_IP=$(ask_validated "Schritt 5/10: Floating-IP (VRRP)" \
"Die FLOATING-IP ist die IP, unter der eure Services nach außen \
erreichbar sind (z.B. via DNS auf diese IP zeigen).

WICHTIG: Diese IP muss auf BEIDEN Nodes (MASTER + BACKUP) IDENTISCH \
eingetragen werden. keepalived sorgt dafür, dass nur die aktive Node \
sie tatsächlich auf dem Interface trägt.

Format: IP/CIDR, z.B. 192.168.1.100/24
Die IP muss frei sein (kein anderes Gerät nutzt sie) und im selben \
Subnetz wie die statische Node-IP liegen." \
        "192.168.1.100/24" \
        '^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$' \
        "Format: IP/CIDR, z.B. 192.168.1.100/24")

    VRRP_ROUTER_ID=$(ask_validated "Schritt 6a/10: VRRP Router-ID" \
"Eine Zahl zwischen 1 und 255, die diese VRRP-Gruppe in eurem Netz \
eindeutig identifiziert.

WICHTIG: Auf BEIDEN Nodes IDENTISCH. Wenn ihr im selben Netz weitere \
keepalived-Gruppen habt (z.B. für andere VIPs), müssen die unter- \
schiedliche Router-IDs haben. 51 ist ein üblicher Default." \
        "51" \
        '^([1-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])$' \
        "Zahl 1–255")

    VRRP_PASS=$(wt_password "Schritt 6b/10: VRRP-Passwort" \
"Gemeinsames Passwort für die VRRP-Authentifizierung zwischen MASTER \
und BACKUP.

WICHTIG: Auf BEIDEN Nodes IDENTISCH. Schützt nicht vor allem (VRRP- \
Auth ist schwach), verhindert aber Verwechslungen wenn andere VRRP- \
Sprecher im Netz sind. Mindestens 8 Zeichen.")
    while [[ ${#VRRP_PASS} -lt 8 ]]; do
        wt_msg "Zu kurz" "VRRP-Passwort muss mindestens 8 Zeichen haben."
        VRRP_PASS=$(wt_password "Schritt 6b/10: VRRP-Passwort" "Mindestens 8 Zeichen.")
    done
}

collect_acme_email() {
    ACME_EMAIL=$(ask_validated "Schritt 7/10: E-Mail für Let's Encrypt" \
"Deine E-Mail-Adresse — wird an Let's Encrypt übermittelt, damit du \
Benachrichtigungen über ablaufende Zertifikate bekommst.

Wird sonst nirgends verwendet, nicht im Repo gespeichert (landet nur \
in /etc/letsencrypt/ auf dieser Node)." \
        "" \
        '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$' \
        "Bitte eine gültige E-Mail-Adresse eingeben.")
}

collect_repo_url() {
    REPO_URL=$(ask_validated "Schritt 8/10: Git-Repo-URL" \
"SSH-URL eures Reverse-Proxy-Repos auf GitHub.

Format: git@github.com:USERNAME/REPONAME.git

Diese Node braucht NUR Lese-Zugriff (read-only Pull alle 2 Min). \
Wir generieren gleich einen SSH-Key, den du als Deploy-Key in GitHub \
einträgst. Der Push-Workflow läuft weiterhin von deinem Dev-Rechner." \
        "git@github.com:USER/HA-Reverse-Proxy-HomeLab.git" \
        '^git@[A-Za-z0-9.-]+:[A-Za-z0-9_./-]+\.git$' \
        "Format: git@github.com:USER/REPO.git")
}

collect_peer() {
    local default_peer="proxy02"
    [[ "$NODE_ROLE" == "BACKUP" ]] && default_peer="proxy01"

    PEER_NAME=$(ask_validated "Schritt 9a/10: Hostname der Peer-Node" \
"Wie heißt die ANDERE Node (das Gegenstück zu dieser hier)?

Wenn diese hier proxy01 ist, ist der Peer proxy02 — und umgekehrt. \
Wird nur in der Statusseite zur Anzeige genutzt." \
        "$default_peer" \
        '^[a-zA-Z0-9][a-zA-Z0-9-]{0,62}$' \
        "Hostname-Format: a-z, 0-9, '-'")

    wt_msg "Schritt 9b/10: Peer Tailscale-IP (optional)" \
"Im nächsten Dialog kannst du die Tailscale-IP der Peer-Node eintragen \
(z.B. 100.64.1.5).

Diese wird gebraucht für:
  - Cert-Sync von MASTER nach BACKUP per rsync
  - Cluster-Statusanzeige (Peer-Health auf der Status-Seite)

Wenn die Peer-Node noch nicht existiert / Tailscale dort noch nicht \
läuft, lass das Feld LEER. Du kannst die IP später in /etc/proxy- \
config/values.env nachtragen — kein Neu-Bootstrap nötig."

    PEER_TAILSCALE_IP=$(wt_input "Schritt 9b/10: Peer Tailscale-IP" \
"Tailscale-IP der Peer-Node (z.B. 100.64.1.5) oder LEER lassen:" "")

    if [[ -n "$PEER_TAILSCALE_IP" && ! "$PEER_TAILSCALE_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        wt_msg "Ungültig" "Eingabe ist keine IP-Adresse — wird ignoriert (leer gesetzt)."
        PEER_TAILSCALE_IP=""
    fi
}

collect_tailscale() {
    wt_msg "Schritt 10/10: Tailscale-Authkey (optional)" \
"Tailscale ist ein VPN-Mesh, über das du diese VM von außen erreichst \
(SSH, Statusseite). Ohne Tailscale ist die Statusseite nicht erreichbar \
(sie bindet bewusst NICHT auf der LAN-IP).

Du hast zwei Optionen:

  A) Authkey jetzt eintragen → Tailscale wird automatisch verbunden.
     Authkey holst du dir aus https://login.tailscale.com/admin/settings/keys
     (Reusable, Ephemeral=NO, Tags optional).

  B) LEER lassen → später manuell 'tailscale up --ssh' ausführen.

Authkeys sind sensitiv — sie werden NICHT ins Repo gespeichert, nur \
einmalig in /etc/proxy-bootstrap.conf (mode 0600), die am Ende von \
Phase B gelöscht wird."

    TAILSCALE_AUTHKEY=$(wt_password "Tailscale Authkey" \
"Authkey (tskey-auth-...) oder LEER für manuelles Setup später:") || TAILSCALE_AUTHKEY=""
}

review_and_confirm() {
    local summary
    summary="Bitte prüfe die Eingaben:

Rolle:              $NODE_ROLE
Hostname:           $NODE_NAME
Interface:          $VRRP_INTERFACE
Statische IP:       $NODE_IP
Gateway:            $NODE_GW
Floating-IP:        $FLOATING_IP
VRRP Router-ID:     $VRRP_ROUTER_ID
VRRP-Passwort:      $(printf '%*s' "${#VRRP_PASS}" '' | tr ' ' '*')
ACME-E-Mail:        $ACME_EMAIL
Repo:               $REPO_URL
Peer-Hostname:      $PEER_NAME
Peer Tailscale-IP:  ${PEER_TAILSCALE_IP:-(später nachtragen)}
Tailscale-Authkey:  $([[ -n "$TAILSCALE_AUTHKEY" ]] && echo "(eingegeben)" || echo "(leer — manuell)")

Mit OK speichern wir die Konfiguration und gehen zu Phase B weiter.
Mit NEIN brichst du ab und nichts wird verändert."

    wt_yesno "Zusammenfassung" "$summary" || {
        echo "Bootstrap vom Benutzer abgebrochen."
        exit 1
    }
}

save_config() {
    umask 077
    cat > "$BOOTSTRAP_CONF" <<EOF
# Auto-generated by bootstrap.sh — wird nach Phase B gelöscht.
NODE_ROLE="$NODE_ROLE"
NODE_NAME="$NODE_NAME"
VRRP_INTERFACE="$VRRP_INTERFACE"
NODE_IP="$NODE_IP"
NODE_GW="$NODE_GW"
FLOATING_IP="$FLOATING_IP"
VRRP_ROUTER_ID="$VRRP_ROUTER_ID"
VRRP_PASS="$VRRP_PASS"
ACME_EMAIL="$ACME_EMAIL"
REPO_URL="$REPO_URL"
PEER_NAME="$PEER_NAME"
PEER_TAILSCALE_IP="$PEER_TAILSCALE_IP"
TAILSCALE_AUTHKEY="$TAILSCALE_AUTHKEY"
EOF
    chmod 600 "$BOOTSTRAP_CONF"
    echo "→ Konfiguration gespeichert: $BOOTSTRAP_CONF"
}

# ============================================================================
# SSH-Deploy-Key
# ============================================================================
generate_ssh_key() {
    mkdir -p /root/.ssh
    chmod 700 /root/.ssh
    if [[ ! -f "$SSH_KEY" ]]; then
        ssh-keygen -t ed25519 -N "" -C "${PROJECT}-${NODE_NAME}" -f "$SSH_KEY"
    fi
    local cfg=/root/.ssh/config
    if ! grep -q "Host github.com" "$cfg" 2>/dev/null; then
        cat >> "$cfg" <<EOF

Host github.com
    IdentityFile $SSH_KEY
    IdentitiesOnly yes
    StrictHostKeyChecking accept-new
EOF
        chmod 600 "$cfg"
    fi
    ssh-keyscan -t ed25519 github.com 2>/dev/null >> /root/.ssh/known_hosts || true
    sort -u -o /root/.ssh/known_hosts /root/.ssh/known_hosts 2>/dev/null || true
}

display_pubkey_and_wait() {
    local pubkey
    pubkey=$(cat "${SSH_KEY}.pub")
    wt_msg "GitHub Deploy-Key eintragen" \
"Damit diese Node das Repo lesen kann, muss der folgende Public-Key \
als Deploy-Key (read-only) in eurem GitHub-Repo eingetragen werden.

Schritte:

  1. Öffne https://github.com/USER/REPO/settings/keys
  2. Klick 'Add deploy key'
  3. Title: ${PROJECT}-${NODE_NAME}
  4. Key: (untenstehenden Block einfügen)
  5. 'Allow write access' → NICHT aktivieren (read-only)
  6. 'Add key'

Der Key (auch in ${SSH_KEY}.pub):

$pubkey

Mit OK bestätigst du, dass der Key in GitHub eingetragen ist."

    if ! ssh -o BatchMode=yes -o ConnectTimeout=10 -T git@github.com 2>&1 | \
            grep -qE "successfully authenticated|does not provide shell access"; then
        wt_yesno "Verifikation fehlgeschlagen" \
"Der Test-SSH-Connect zu GitHub hat nicht den erwarteten 'successfully \
authenticated'-String geliefert. Möglich ist:

  - Key wurde noch nicht in GitHub eingetragen
  - GitHub-Outage (selten)
  - Firewall blockiert ausgehend SSH (Port 22)

Trotzdem fortfahren? (Bei NEIN brechen wir ab — du kannst das Bootstrap \
später erneut starten, deine Eingaben sind in $BOOTSTRAP_CONF gespeichert.)" || {
            echo "Bootstrap pausiert. Trage den Key in GitHub ein und starte erneut:"
            echo "  sudo $0"
            exit 1
        }
    fi
}

# ============================================================================
# Netzwerk via systemd-networkd
# ============================================================================
write_networkd_config() {
    local nwd=/etc/systemd/network/10-${PROJECT}.network
    cat > "$nwd" <<EOF
# Auto-generated by ${PROJECT}-bootstrap
[Match]
Name=${VRRP_INTERFACE}

[Network]
Address=${NODE_IP}
Gateway=${NODE_GW}
DNS=1.1.1.1
DNS=9.9.9.9
EOF
    chmod 644 "$nwd"
    systemctl enable systemd-networkd >/dev/null 2>&1 || true
    echo "→ networkd-Config geschrieben: $nwd"
}

ip_changed() {
    local current
    current=$(ip -o -4 addr show "$VRRP_INTERFACE" 2>/dev/null | awk '{print $4}' | head -1)
    [[ "$current" != "$NODE_IP" ]]
}

# ============================================================================
# Resume-Service installieren (für IP-Wechsel)
# ============================================================================
install_resume_service() {
    cp "$0" "$BOOTSTRAP_BIN"
    chmod 700 "$BOOTSTRAP_BIN"

    cat > "/etc/systemd/system/${RESUME_SERVICE}" <<EOF
[Unit]
Description=Resume ${PROJECT}-bootstrap after IP change
After=network-online.target
Wants=network-online.target
ConditionPathExists=${BOOTSTRAP_CONF}

[Service]
Type=oneshot
ExecStartPre=/bin/sh -c 'until /usr/bin/dig +short +time=2 +tries=1 @1.1.1.1 github.com >/dev/null; do sleep 2; done'
ExecStart=${BOOTSTRAP_BIN} --resume
StandardOutput=append:${LOG}
StandardError=append:${LOG}

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable "${RESUME_SERVICE}" >/dev/null
    echo "→ Resume-Service installiert: ${RESUME_SERVICE}"
}

# ============================================================================
# Phase B
# ============================================================================
phase_b_packages() {
    echo "=== Phase B [1/9] System-Update + Pakete ==="
    DEBIAN_FRONTEND=noninteractive apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get -y \
        -o Dpkg::Options::="--force-confdef" \
        -o Dpkg::Options::="--force-confold" upgrade
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
        nginx keepalived \
        certbot python3-certbot-nginx \
        fail2ban ufw \
        git rsync openssl jq curl wget \
        python3 python3-venv python3-pip \
        unattended-upgrades
}

phase_b_tailscale() {
    echo "=== Phase B [2/9] Tailscale ==="
    if ! command -v tailscale >/dev/null 2>&1; then
        curl -fsSL https://tailscale.com/install.sh | sh
    fi
    if [[ -n "${TAILSCALE_AUTHKEY:-}" ]]; then
        tailscale up --ssh --authkey="$TAILSCALE_AUTHKEY" --hostname="$NODE_NAME" || true
    else
        echo "→ Kein Authkey — bitte später manuell: tailscale up --ssh"
    fi

    STATUS_BIND_IP=$(tailscale ip -4 2>/dev/null | head -1 || echo "")
    if [[ -z "$STATUS_BIND_IP" ]]; then
        echo "WARN: Keine Tailscale-IP — STATUS_BIND_IP bleibt 127.0.0.1"
        STATUS_BIND_IP="127.0.0.1"
    fi

    chattr +i /etc/resolv.conf 2>/dev/null || true
}

phase_b_clone_repo() {
    echo "=== Phase B [3/9] Repo klonen ==="
    until dig +short +time=2 +tries=1 @1.1.1.1 github.com >/dev/null; do
        echo "  warte auf DNS..."
        sleep 2
    done

    if [[ ! -d "$REPO_DIR/.git" ]]; then
        mkdir -p "$(dirname "$REPO_DIR")"
        GIT_SSH_COMMAND="ssh -i $SSH_KEY -o IdentitiesOnly=yes" \
            git clone "$REPO_URL" "$REPO_DIR"
    else
        echo "→ Repo existiert bereits, pull"
        GIT_SSH_COMMAND="ssh -i $SSH_KEY -o IdentitiesOnly=yes" \
            git -C "$REPO_DIR" pull --ff-only
    fi
}

phase_b_render_values_env() {
    echo "=== Phase B [4/9] values.env rendern ==="
    mkdir -p "$CONFIG_DIR"
    local prio=100
    [[ "$NODE_ROLE" == "BACKUP" ]] && prio=90

    cat > "$CONFIG_DIR/values.env" <<EOF
# Auto-generated von bootstrap.sh am $(date -Iseconds)
# Bei Änderungen: nginx -t && systemctl reload nginx && systemctl reload keepalived

NODE_ROLE=$NODE_ROLE
NODE_NAME=$NODE_NAME
PEER_NAME=$PEER_NAME
PEER_TAILSCALE_IP=$PEER_TAILSCALE_IP

VRRP_INTERFACE=$VRRP_INTERFACE
VRRP_VIRTUAL_ROUTER_ID=$VRRP_ROUTER_ID
VRRP_PRIORITY=$prio
VRRP_AUTH_PASS=$VRRP_PASS
FLOATING_IP=$FLOATING_IP

STATUS_BIND_IP=$STATUS_BIND_IP

ACME_EMAIL=$ACME_EMAIL
EOF
    chmod 600 "$CONFIG_DIR/values.env"
}

phase_b_dh_and_default_cert() {
    echo "=== Phase B [5/9] DH-Params + Default-Cert ==="
    mkdir -p /etc/nginx/ssl /var/www/letsencrypt
    if [[ ! -f /etc/nginx/ssl/dhparam.pem ]]; then
        openssl dhparam -out /etc/nginx/ssl/dhparam.pem 2048
    fi
    if [[ ! -f /etc/nginx/ssl/default.crt ]]; then
        openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
            -keyout /etc/nginx/ssl/default.key \
            -out    /etc/nginx/ssl/default.crt \
            -subj "/CN=default" 2>/dev/null
    fi
}

phase_b_ufw() {
    echo "=== Phase B [6/9] Firewall ==="
    ufw default deny incoming  >/dev/null
    ufw default allow outgoing >/dev/null
    ufw allow OpenSSH          >/dev/null
    ufw allow 80/tcp           >/dev/null
    ufw allow 443/tcp          >/dev/null
    ufw allow in on tailscale0 >/dev/null
    ufw allow in on "$VRRP_INTERFACE" to 224.0.0.18 >/dev/null || true
    ufw --force enable
}

phase_b_keepalived_helpers() {
    echo "=== Phase B [7/9] keepalived-Helpers + State-User + Cron + Sudoers ==="
    install -m 0755 "$REPO_DIR/keepalived/check_nginx.sh"      /usr/local/bin/check_nginx.sh
    install -m 0755 "$REPO_DIR/keepalived/notify_keepalived.sh" /usr/local/bin/notify_keepalived.sh

    if ! id proxy-status >/dev/null 2>&1; then
        useradd -r -s /usr/sbin/nologin -d "$REPO_DIR/status" proxy-status
    fi
    mkdir -p /var/log/proxy-status /var/lib/proxy-status
    # /var/log/proxy-status: Service schreibt rein
    chown -R proxy-status:proxy-status /var/log/proxy-status
    # /var/lib/proxy-status: cron schreibt (root), Service liest
    chown root:proxy-status /var/lib/proxy-status
    chmod 0750 /var/lib/proxy-status

    # update-site-info.sh ausführbar machen
    chmod 0755 "$REPO_DIR/scripts/update-site-info.sh"

    # Cron-Job für 5-Min-Snapshots
    install -m 0644 "$REPO_DIR/cron/proxy-status" /etc/cron.d/proxy-status

    # Sudoers-Whitelist (visudo-validiert vor Install)
    if visudo -c -f "$REPO_DIR/status/sudoers.d/proxy-status" >/dev/null; then
        install -m 0440 "$REPO_DIR/status/sudoers.d/proxy-status" \
                        /etc/sudoers.d/proxy-status
    else
        echo "FEHLER: sudoers.d/proxy-status ist syntaktisch ungültig!"
        exit 1
    fi

    # Erste Snapshot-Sammlung jetzt (damit die UI nicht leer ist)
    "$REPO_DIR/scripts/update-site-info.sh" || \
        echo "WARN: erste Snapshot-Sammlung fehlgeschlagen — wird via cron erneut versucht"
}

phase_b_status_service() {
    echo "=== Phase B [8/9] Status-Site (venv + systemd) ==="
    if [[ ! -d "$REPO_DIR/status/venv" ]]; then
        python3 -m venv "$REPO_DIR/status/venv"
    fi
    "$REPO_DIR/status/venv/bin/pip" install --upgrade pip --quiet
    "$REPO_DIR/status/venv/bin/pip" install -r "$REPO_DIR/status/requirements.txt" --quiet
    chown -R proxy-status:proxy-status "$REPO_DIR/status/venv"

    install -m 0644 "$REPO_DIR/status/systemd/proxy-status.service" \
                    /etc/systemd/system/proxy-status.service
    systemctl daemon-reload
    systemctl enable --now proxy-status.service || \
        echo "WARN: proxy-status startete nicht — siehe journalctl -u proxy-status"
}

phase_b_deploy_timer() {
    echo "=== Phase B [9/9] Deploy-Timer + erstes Deploy ==="
    install -m 0644 "$REPO_DIR/systemd/proxy-deploy.service" /etc/systemd/system/proxy-deploy.service
    install -m 0644 "$REPO_DIR/systemd/proxy-deploy.timer"   /etc/systemd/system/proxy-deploy.timer
    systemctl daemon-reload
    systemctl enable --now proxy-deploy.timer

    "$REPO_DIR/scripts/deploy.sh" || \
        echo "WARN: erstes deploy.sh fehlgeschlagen — Timer wird's erneut versuchen"

    hostnamectl set-hostname "$NODE_NAME"

    systemctl enable --now nginx
    systemctl enable --now keepalived
}

phase_b_finalize() {
    systemctl disable "${RESUME_SERVICE}" >/dev/null 2>&1 || true
    rm -f "/etc/systemd/system/${RESUME_SERVICE}"
    systemctl daemon-reload
    shred -u "$BOOTSTRAP_CONF" 2>/dev/null || rm -f "$BOOTSTRAP_CONF"
    rm -f "$BOOTSTRAP_BIN"
}

phase_b() {
    # shellcheck disable=SC1090
    source "$BOOTSTRAP_CONF"

    phase_b_packages
    phase_b_tailscale
    phase_b_clone_repo
    phase_b_render_values_env
    phase_b_dh_and_default_cert
    phase_b_ufw
    phase_b_keepalived_helpers
    phase_b_status_service
    phase_b_deploy_timer
    phase_b_finalize

    echo
    echo "================================================================"
    echo " Bootstrap abgeschlossen — Rolle: $NODE_ROLE ($NODE_NAME)"
    echo "================================================================"
    echo
    echo "Nächste Schritte:"
    echo "  1. Auf der zweiten Node das Bootstrap mit umgekehrter Rolle laufen lassen."
    echo "  2. Tailscale-IP der Peer-Node in $CONFIG_DIR/values.env eintragen,"
    echo "     falls noch nicht geschehen (Variable PEER_TAILSCALE_IP)."
    echo "  3. Erstes Zertifikat anfordern (nur auf MASTER):"
    echo "       ./scripts/cert-request.sh service.example.com"
    echo "  4. Service aktivieren:"
    echo "       ./scripts/enable-site.sh <service-name>"
    echo "  5. Statusseite öffnen: http://${STATUS_BIND_IP}:8080  (über Tailscale)"
}

# ============================================================================
# Phase A — Orchestrator
# ============================================================================
phase_a() {
    welcome
    NODE_ROLE=$(collect_role)
    NODE_NAME=$(collect_hostname)
    VRRP_INTERFACE=$(collect_interface)
    collect_static_ip
    collect_floating_ip
    collect_acme_email
    collect_repo_url
    collect_peer
    collect_tailscale
    review_and_confirm

    save_config
    generate_ssh_key
    display_pubkey_and_wait
    write_networkd_config

    if ip_changed; then
        install_resume_service
        wt_msg "IP-Wechsel erforderlich" \
"Die neue IP $NODE_IP weicht von der aktuellen ab. Die VM startet \
jetzt neu — verbinde dich danach per SSH zur NEUEN IP.

Phase B läuft beim Boot automatisch weiter (siehe ${RESUME_SERVICE}). \
Logs: $LOG

Mit OK starten wir den Reboot."
        systemctl restart systemd-networkd || true
        sleep 2
        reboot
        exit 0
    fi
}

# ============================================================================
# MAIN
# ============================================================================
require_root
require_debian
ensure_tools

if [[ "$RESUMING" == "1" ]]; then
    if [[ ! -f "$BOOTSTRAP_CONF" ]]; then
        echo "FEHLER: --resume aber $BOOTSTRAP_CONF fehlt."
        exit 1
    fi
    echo "=> Resuming Phase B"
    phase_b
    exit 0
fi

if [[ -f "$BOOTSTRAP_CONF" ]]; then
    if wt_yesno "Bestehende Konfiguration gefunden" \
"$BOOTSTRAP_CONF existiert bereits.

[JA]   Phase B mit den bestehenden Werten weiterlaufen lassen.
[NEIN] Conf löschen und Phase A neu starten."; then
        phase_b
        exit 0
    else
        rm -f "$BOOTSTRAP_CONF"
    fi
fi

phase_a
phase_b
