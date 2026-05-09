#!/bin/bash
# scripts/npm-bootstrap.sh
#
# Bootstrap-Assistent für eine NPM-VM (Nginx Proxy Manager mit Web-UI).
# Zwei Phasen, idempotent, IP-Wechsel-resilient — wie das HA-Bootstrap,
# aber deutlich kleiner: keine VRRP, keine Floating-IP, kein Cert-Sync.
# Nur: statische IP setzen, Docker installieren, NPM starten.
#
# Aufruf:
#   ./scripts/npm-bootstrap.sh             # interaktiv (Phase A + B)
#   ./scripts/npm-bootstrap.sh --resume    # Auto-Resume nach IP-Wechsel
#
# Logging: /var/log/npm-bootstrap.log

set -euo pipefail

# ============================================================================
# Konstanten
# ============================================================================
PROJECT=npm
NPM_DIR=/opt/npm
BOOTSTRAP_CONF=/etc/${PROJECT}-bootstrap.conf
BOOTSTRAP_BIN=/usr/local/sbin/${PROJECT}-bootstrap
RESUME_SERVICE=${PROJECT}-bootstrap-resume.service
LOG=/var/log/${PROJECT}-bootstrap.log
COMPOSE_SRC=/opt/npm-bootstrap/npm/docker-compose.yml

RESUMING=0
[[ "${1:-}" == "--resume" ]] && RESUMING=1

# ============================================================================
# Logging
# ============================================================================
mkdir -p "$(dirname "$LOG")"
exec > >(tee -a "$LOG") 2>&1
echo
echo "================================================================"
echo " $(date -Iseconds)  npm-bootstrap started  (pid=$$, resume=$RESUMING)"
echo "================================================================"

# ============================================================================
# Helpers
# ============================================================================
require_root() {
    [[ $EUID -eq 0 ]] || { echo "FEHLER: bitte als root ausführen"; exit 1; }
}

require_debian() {
    if ! grep -qi "debian" /etc/os-release 2>/dev/null; then
        echo "WARN: Dieses Script ist für Debian 13 (trixie) entwickelt."
        read -rp "Trotzdem fortfahren? [yes/NO] " ans
        [[ "$ans" == "yes" ]] || exit 1
    fi
}

ensure_tools() {
    local missing=()
    for t in whiptail jq dig tee curl awk sed ifup; do
        command -v "$t" >/dev/null 2>&1 || missing+=("$t")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        echo "Installiere fehlende Tools: ${missing[*]}"
        apt-get update -qq
        apt-get install -y whiptail jq dnsutils coreutils gawk sed curl ifupdown
    fi
}

# CIDR-Prefix → Netmask
prefix_to_netmask() {
    local p=$1 i mask=""
    for i in 1 2 3 4; do
        if (( p >= 8 )); then mask+="255"; p=$(( p - 8 ))
        elif (( p > 0 )); then mask+="$(( 256 - 2**(8 - p) ))"; p=0
        else mask+="0"
        fi
        (( i < 4 )) && mask+="."
    done
    echo "$mask"
}

wait_for_dns() {
    local i
    for i in $(seq 1 60); do
        dig +short +time=2 +tries=1 @1.1.1.1 docker.com >/dev/null 2>&1 && return 0
        sleep 2
    done
    echo "FEHLER: DNS hat 60 Versuche nicht geantwortet."
    return 1
}

trigger_reboot() {
    local unit="${PROJECT}-bootstrap-reboot.service"
    systemd-run --on-active=5s --unit="$unit" \
        systemctl reboot 2>/dev/null \
        || systemctl reboot
}

# ============================================================================
# whiptail-Wrapper
# ============================================================================
WT_HEIGHT=22
WT_WIDTH=78

wt_msg()   { whiptail --title "$1" --msgbox "$2" "$WT_HEIGHT" "$WT_WIDTH"; }
wt_yesno() { whiptail --title "$1" --yesno  "$2" "$WT_HEIGHT" "$WT_WIDTH"; }
wt_input() { whiptail --title "$1" --inputbox "$2" "$WT_HEIGHT" "$WT_WIDTH" "${3:-}" 3>&1 1>&2 2>&3; }

ask_validated() {
    local title="$1" text="$2" default="$3" regex="$4" errtext="$5" val
    while true; do
        val=$(wt_input "$title" "$text" "$default") || exit 1
        if [[ "$val" =~ $regex ]]; then echo "$val"; return 0; fi
        wt_msg "Ungültige Eingabe" "$errtext"$'\n\nDeine Eingabe: '"$val"
    done
}

# ============================================================================
# Phase A — Eingaben
# ============================================================================
welcome() {
    wt_msg "NPM-Bootstrap" \
"Willkommen.

Dieser Assistent richtet diese VM als Nginx-Proxy-Manager-Server ein:

  - statische IP setzen (mit automatischem Reboot, falls nötig)
  - Docker + Docker-Compose installieren
  - NPM-Container starten
  - Statusprüfung

Am Ende öffnest du im Browser http://<IP>:81 und arbeitest komplett
über die Web-UI — keine weiteren Linux-Kenntnisse nötig.

Default-Login: admin@example.com / changeme  (sofort ändern!)

Dauer: 5–10 Minuten."
}

collect_hostname() {
    ask_validated "Schritt 1/3: Hostname" \
"Hostname für diese VM. Vorschlag: 'npm' oder 'proxy'.
Nur Buchstaben, Ziffern und Bindestrich; max. 63 Zeichen." \
        "npm" \
        '^[a-zA-Z0-9][a-zA-Z0-9-]{0,62}$' \
        "Nur a-z, A-Z, 0-9, '-'; nicht mit '-' beginnen."
}

collect_interface() {
    mapfile -t ifaces < <(ip -o link show | awk -F': ' '{print $2}' | grep -vE '^(lo|docker|tailscale|br-|veth)')
    [[ ${#ifaces[@]} -gt 0 ]] || { wt_msg "FEHLER" "Kein Netzwerk-Interface gefunden."; exit 1; }
    local current_iface
    current_iface=$(ip -o -4 route show default | awk '{print $5}' | head -1)
    local args=()
    for i in "${ifaces[@]}"; do
        local mac on=OFF
        mac=$(cat "/sys/class/net/$i/address" 2>/dev/null || echo "?")
        [[ "$i" == "$current_iface" ]] && on=ON
        args+=("$i" "MAC ${mac}" "$on")
    done
    whiptail --title "Schritt 2/3: Netzwerk-Interface" --radiolist \
"Welches Interface ist mit deinem LAN verbunden?

Normalerweise das mit der Default-Route (vorausgewählt). In Proxmox-VMs
meist 'eth0', 'ens18' oder 'enp0s3'." \
        "$WT_HEIGHT" "$WT_WIDTH" 6 "${args[@]}" 3>&1 1>&2 2>&3
}

collect_static_ip() {
    local default_ip default_gw
    default_ip=$(ip -o -4 addr show "$NIC" 2>/dev/null | awk '{print $4}' | head -1)
    default_gw=$(ip -o -4 route show default | awk '{print $3}' | head -1)

    NODE_IP=$(ask_validated "Schritt 3a/3: Statische IP" \
"Statische IP dieser VM mit CIDR-Maske, z.B. 192.168.1.20/24

Diese IP wird später im Browser aufgerufen, um auf die NPM-Web-UI
zuzugreifen. Wähle eine freie IP außerhalb des DHCP-Pools deines
Routers. Wenn du eine andere IP einträgst als die aktuelle, wird die
VM nach Phase A neu gestartet." \
        "$default_ip" \
        '^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$' \
        "Format: IP/CIDR, z.B. 192.168.1.20/24")

    NODE_GW=$(ask_validated "Schritt 3b/3: Gateway" \
"IP des Standard-Gateways (Router) ohne Maske, z.B. 192.168.1.1" \
        "$default_gw" \
        '^([0-9]{1,3}\.){3}[0-9]{1,3}$' \
        "Format: IP-Adresse ohne Maske, z.B. 192.168.1.1")
}

review_and_confirm() {
    wt_yesno "Zusammenfassung" \
"Bitte prüfen:

  Hostname        : $NODE_NAME
  Interface       : $NIC
  Statische IP    : $NODE_IP
  Gateway         : $NODE_GW

Mit OK speichern wir + gehen zu Phase B.
Mit NEIN brichst du ab — nichts wurde verändert." || {
        echo "Bootstrap abgebrochen."
        exit 1
    }
}

save_config() {
    umask 077
    cat > "$BOOTSTRAP_CONF" <<EOF
# Auto-generated by npm-bootstrap.sh — wird nach Phase B gelöscht.
NODE_NAME="$NODE_NAME"
NIC="$NIC"
NODE_IP="$NODE_IP"
NODE_GW="$NODE_GW"
EOF
    chmod 600 "$BOOTSTRAP_CONF"
    echo "→ Konfiguration gespeichert: $BOOTSTRAP_CONF"
}

# ============================================================================
# Netzwerk via ifupdown (gleicher Pfad wie HA-Bootstrap)
# ============================================================================
write_network_config() {
    local addr prefix netmask
    addr=$(echo "$NODE_IP" | awk -F/ '{print $1}')
    prefix=$(echo "$NODE_IP" | awk -F/ '{print $2}')
    netmask=$(prefix_to_netmask "$prefix")

    # Hygiene: cloud-init / systemd-resolved / konkurrierende Configs raus
    mkdir -p /etc/cloud
    : > /etc/cloud/cloud-init.disabled
    if systemctl is-enabled --quiet systemd-resolved 2>/dev/null \
       || systemctl is-active --quiet systemd-resolved 2>/dev/null; then
        systemctl disable --now systemd-resolved >/dev/null 2>&1 || true
    fi
    rm -f /etc/systemd/network/*.network 2>/dev/null || true
    rm -f /etc/network/interfaces.d/* 2>/dev/null || true

    if [[ -f /etc/network/interfaces ]]; then
        cp -a /etc/network/interfaces "/etc/network/interfaces.bak.$(date +%s)"
    fi

    cat > /etc/network/interfaces <<EOF
# Auto-generated by ${PROJECT}-bootstrap
auto lo
iface lo inet loopback

auto ${NIC}
iface ${NIC} inet static
    address ${addr}
    netmask ${netmask}
    gateway ${NODE_GW}
    dns-nameservers 1.1.1.1 9.9.9.9
EOF
    chmod 0644 /etc/network/interfaces

    if [[ -L /etc/resolv.conf ]]; then
        rm -f /etc/resolv.conf
    elif [[ -f /etc/resolv.conf ]] && lsattr /etc/resolv.conf 2>/dev/null | awk '{print $1}' | grep -q 'i'; then
        chattr -i /etc/resolv.conf 2>/dev/null || true
    fi
    cat > /etc/resolv.conf <<'EOF'
nameserver 1.1.1.1
nameserver 9.9.9.9
EOF
    chmod 0644 /etc/resolv.conf
    chattr +i /etc/resolv.conf 2>/dev/null || true

    echo "→ /etc/network/interfaces geschrieben (${NIC} → ${addr}/${prefix})"
}

ip_changed() {
    local current
    current=$(ip -o -4 addr show "$NIC" 2>/dev/null | awk '{print $4}' | head -1)
    [[ "$current" != "$NODE_IP" ]]
}

# ============================================================================
# Resume-Service installieren
# ============================================================================
install_resume_service() {
    install -m 0755 "$0" "$BOOTSTRAP_BIN"

    cat > "/etc/systemd/system/${RESUME_SERVICE}" <<EOF
[Unit]
Description=Resume ${PROJECT}-bootstrap after IP change
After=network.target networking.service multi-user.target
ConditionPathExists=${BOOTSTRAP_CONF}

[Service]
Type=oneshot
ExecStartPre=/bin/sleep 10
ExecStartPre=/bin/sh -c 'for i in \$(seq 1 60); do /usr/bin/dig +short +time=2 +tries=1 @1.1.1.1 docker.com >/dev/null && exit 0; sleep 2; done; exit 1'
ExecStart=${BOOTSTRAP_BIN} --resume
ExecStartPost=/bin/systemctl disable ${RESUME_SERVICE}
StandardOutput=append:${LOG}
StandardError=append:${LOG}
RemainAfterExit=no
TimeoutStartSec=20min

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable "${RESUME_SERVICE}" >/dev/null
    echo "→ Resume-Service installiert: ${RESUME_SERVICE}"
}

# ============================================================================
# Phase B — Docker + NPM
# ============================================================================
phase_b_sanity_check_ip() {
    local soll_addr ist
    soll_addr=$(echo "$NODE_IP" | awk -F/ '{print $1}')
    ist=$(ip -o -4 addr show "$NIC" 2>/dev/null \
            | awk '{print $4}' | head -1 | awk -F/ '{print $1}')
    if [[ "$ist" != "$soll_addr" ]]; then
        echo "WARN: IST-IP ('${ist:-keine}') != SOLL ('$soll_addr') — schreibe Netzkonfig neu und reboote."
        write_network_config
        trigger_reboot
        exit 0
    fi
    echo "→ IP-Sanity-Check ok ($ist)"
}

phase_b_packages() {
    echo "=== Phase B [1/4] System-Update + Basis-Pakete ==="
    DEBIAN_FRONTEND=noninteractive apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get -y \
        -o Dpkg::Options::="--force-confdef" \
        -o Dpkg::Options::="--force-confold" upgrade
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
        ca-certificates curl gnupg lsb-release ufw fail2ban
}

phase_b_docker() {
    echo "=== Phase B [2/4] Docker Engine + Compose installieren ==="
    if command -v docker >/dev/null 2>&1; then
        echo "→ Docker bereits installiert: $(docker --version)"
    else
        # Offizielle Docker-Repo (sicherer als 'apt-get install docker.io')
        install -m 0755 -d /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/debian/gpg \
            | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
        chmod a+r /etc/apt/keyrings/docker.gpg
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
            > /etc/apt/sources.list.d/docker.list

        DEBIAN_FRONTEND=noninteractive apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y \
            docker-ce docker-ce-cli containerd.io \
            docker-buildx-plugin docker-compose-plugin

        systemctl enable --now docker
        echo "→ Docker installiert: $(docker --version)"
    fi
}

phase_b_ufw() {
    echo "=== Phase B [3/4] Firewall (ufw) ==="
    ufw default deny incoming  >/dev/null
    ufw default allow outgoing >/dev/null
    ufw allow OpenSSH          >/dev/null
    ufw allow 80/tcp           >/dev/null
    ufw allow 443/tcp          >/dev/null
    ufw allow 81/tcp           >/dev/null  # NPM-Web-UI
    ufw --force enable
}

phase_b_npm() {
    echo "=== Phase B [4/4] NPM-Container starten ==="
    mkdir -p "$NPM_DIR" "$NPM_DIR/data" "$NPM_DIR/letsencrypt"

    # docker-compose.yml aus dem Repo holen
    if [[ -f "$COMPOSE_SRC" ]]; then
        install -m 0644 "$COMPOSE_SRC" "$NPM_DIR/docker-compose.yml"
    else
        # Fallback — falls Repo-Pfad nicht stimmt, inline schreiben
        cat > "$NPM_DIR/docker-compose.yml" <<'EOF'
services:
  npm:
    image: 'jc21/nginx-proxy-manager:latest'
    container_name: npm
    restart: unless-stopped
    ports:
      - '80:80'
      - '443:443'
      - '81:81'
    volumes:
      - /opt/npm/data:/data
      - /opt/npm/letsencrypt:/etc/letsencrypt
    environment:
      DISABLE_IPV6: 'true'
EOF
    fi

    cd "$NPM_DIR"
    docker compose pull
    docker compose up -d

    echo "→ Warte auf NPM-Container..."
    local i
    for i in $(seq 1 30); do
        if curl -sf -o /dev/null http://127.0.0.1:81 2>/dev/null; then
            echo "→ NPM erreichbar auf Port 81"
            break
        fi
        sleep 2
    done
}

phase_b_finalize() {
    systemctl disable "${RESUME_SERVICE}" >/dev/null 2>&1 || true
    rm -f "/etc/systemd/system/${RESUME_SERVICE}"
    systemctl daemon-reload
    rm -f "$BOOTSTRAP_CONF" "$BOOTSTRAP_BIN"
}

phase_b() {
    # shellcheck disable=SC1090
    source "$BOOTSTRAP_CONF"

    phase_b_sanity_check_ip
    phase_b_packages
    phase_b_docker
    phase_b_ufw
    phase_b_npm
    phase_b_finalize

    local addr
    addr=$(echo "$NODE_IP" | awk -F/ '{print $1}')
    cat <<EOF

================================================================
 NPM-Bootstrap abgeschlossen.
================================================================

  Web-UI:    http://${addr}:81
  Default-Login:
      E-Mail:    admin@example.com
      Passwort:  changeme

  *** SOFORT EINLOGGEN UND PASSWORT ÄNDERN! ***

Schritt-für-Schritt-Anleitung für die ersten Sites:
  /opt/npm-bootstrap/docs/npm-setup.md  (im Repo)
  oder online: https://github.com/mrckch/HA-Reverse-Proxy/blob/main/docs/npm-setup.md

Update später:
  cd /opt/npm
  docker compose pull
  docker compose up -d

Backup (manuell):
  tar czf npm-backup-\$(date +%F).tar.gz -C /opt/npm data letsencrypt

EOF
}

# ============================================================================
# Phase A — Orchestrator
# ============================================================================
phase_a() {
    welcome
    NODE_NAME=$(collect_hostname)
    NIC=$(collect_interface)
    collect_static_ip
    review_and_confirm

    save_config
    hostnamectl set-hostname "$NODE_NAME" 2>/dev/null || true
    write_network_config

    if ip_changed; then
        install_resume_service
        wt_msg "IP-Wechsel erforderlich" \
"Die neue IP $NODE_IP weicht von der aktuellen ab. Die VM startet \
in ~5 Sekunden neu — die SSH-Session bricht ab. Warte ~60 s und \
verbinde dich danach per SSH zur NEUEN IP.

Phase B läuft beim Boot automatisch weiter. Live-Log:
  tail -f $LOG

Mit OK starten wir den Reboot."
        trigger_reboot
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
    [[ -f "$BOOTSTRAP_CONF" ]] || { echo "FEHLER: --resume aber $BOOTSTRAP_CONF fehlt."; exit 1; }
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
