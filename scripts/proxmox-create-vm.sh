#!/bin/bash
# scripts/proxmox-create-vm.sh
#
# Erzeugt auf einem Proxmox-VE-8-Host eine VM, die als Reverse-Proxy-Node
# (proxy01 oder proxy02) dient. Werte und Defaults sind auf den Workload
# dieses Repos abgestimmt: nginx + keepalived + Tailscale + Status-Site,
# nativ auf Debian 13 (trixie) per netinstall.
#
# Aufruf (auf dem Proxmox-Host als root, NICHT in der VM):
#
#   ./proxmox-create-vm.sh --name proxy01
#   ./proxmox-create-vm.sh --name proxy02 --vmid 9012 --bridge vmbr1 --vlan 20
#   ./proxmox-create-vm.sh --name proxy01 --start
#
# Nach dem Erzeugen:
#   - VM in der Proxmox-Web-UI starten (oder mit --start direkt)
#   - Debian 13 netinstall durchklicken (nur ein User reicht)
#   - In der frischen VM dann das Bootstrap dieses Repos:
#       sudo ./scripts/bootstrap.sh
#
# Idempotent: existierende VMID/Name -> Abbruch mit Hinweis (keine Überschreibung).

set -euo pipefail

# ============================================================================
# Defaults — bewusst konservativ, dem CLAUDE.md/README entsprechend
# ============================================================================
DEFAULT_MEMORY_MB=2048           # 2 GB reicht; bei Bedarf --memory 4096
DEFAULT_CORES=2                  # 2 vCPU, 1 Socket
DEFAULT_DISK_GB=20               # Debian + nginx + Logs
DEFAULT_STORAGE="local-lvm"      # Disk-Storage (lvm-thin/zfs/dir)
DEFAULT_ISO_STORAGE="local"      # ISO-Storage (muss content=iso erlauben)
DEFAULT_BRIDGE="vmbr0"           # LAN-Bridge
DEFAULT_VLAN=""                  # leer = untagged
DEFAULT_ISO_BASE_URL="https://cdimage.debian.org/debian-cd/current/amd64/iso-cd"

# Override via CLI-Flag
NAME=""
VMID=""
MEMORY_MB="$DEFAULT_MEMORY_MB"
CORES="$DEFAULT_CORES"
DISK_GB="$DEFAULT_DISK_GB"
STORAGE="$DEFAULT_STORAGE"
ISO_STORAGE="$DEFAULT_ISO_STORAGE"
BRIDGE="$DEFAULT_BRIDGE"
VLAN="$DEFAULT_VLAN"
ISO_BASE_URL="$DEFAULT_ISO_BASE_URL"
ISO_FILE=""                      # leer = automatisch aus SHA256SUMS
START_AFTER=0
DRY_RUN=0

# ============================================================================
# Hilfen
# ============================================================================
usage() {
    cat <<EOF
proxmox-create-vm.sh — Reverse-Proxy-VM auf Proxmox 8 anlegen

Pflicht:
  --name NAME            VM- und Hostname (z.B. proxy01)

Optional:
  --vmid N               VMID (Default: nächste freie via 'pvesh get /cluster/nextid')
  --memory MB            Default: ${DEFAULT_MEMORY_MB}
  --cores N              Default: ${DEFAULT_CORES}
  --disk-size GB         Default: ${DEFAULT_DISK_GB}
  --storage NAME         Disk-Storage, Default: ${DEFAULT_STORAGE}
  --iso-storage NAME     ISO-Storage, Default: ${DEFAULT_ISO_STORAGE}
  --bridge NAME          Default: ${DEFAULT_BRIDGE}
  --vlan TAG             VLAN-Tag (leer = untagged)
  --iso-url BASE_URL     Basis-URL des ISO-Spiegels (Default: Debian current)
  --iso-file FILENAME    Konkretes ISO im Storage nutzen (skipped Download)
  --start                VM nach dem Anlegen starten
  --dry-run              Nur Plan ausgeben, nichts ändern
  --help                 Diese Hilfe

Beispiele:
  $0 --name proxy01
  $0 --name proxy02 --vmid 9012 --memory 4096 --bridge vmbr1 --vlan 20
  $0 --name proxy01 --iso-file debian-13.0.0-amd64-netinst.iso --start

VM-Profil (fix, abgestimmt auf den Workload):
  CPU host, q35, OVMF/UEFI, virtio-scsi-single (iothread+ssd+discard),
  VirtIO-NIC, qemu-guest-agent enabled, Ballooning aus.
EOF
}

err()  { echo "FEHLER: $*" >&2; exit 1; }
info() { echo "→ $*"; }
run()  {
    if [[ "$DRY_RUN" -eq 1 ]]; then
        echo "  [dry-run] $*"
    else
        "$@"
    fi
}

# ============================================================================
# Argumente parsen
# ============================================================================
while [[ $# -gt 0 ]]; do
    case "$1" in
        --name)         NAME="$2"; shift 2 ;;
        --vmid)         VMID="$2"; shift 2 ;;
        --memory)       MEMORY_MB="$2"; shift 2 ;;
        --cores)        CORES="$2"; shift 2 ;;
        --disk-size)    DISK_GB="$2"; shift 2 ;;
        --storage)      STORAGE="$2"; shift 2 ;;
        --iso-storage)  ISO_STORAGE="$2"; shift 2 ;;
        --bridge)       BRIDGE="$2"; shift 2 ;;
        --vlan)         VLAN="$2"; shift 2 ;;
        --iso-url)      ISO_BASE_URL="$2"; shift 2 ;;
        --iso-file)     ISO_FILE="$2"; shift 2 ;;
        --start)        START_AFTER=1; shift ;;
        --dry-run)      DRY_RUN=1; shift ;;
        -h|--help)      usage; exit 0 ;;
        *)              err "Unbekanntes Argument: $1 (siehe --help)" ;;
    esac
done

# ============================================================================
# Validierung
# ============================================================================
[[ $EUID -eq 0 ]] || err "Bitte als root ausführen (auf dem Proxmox-Host)."

[[ -n "$NAME" ]] || { usage; echo; err "--name ist Pflicht."; }
[[ "$NAME" =~ ^[a-zA-Z0-9][a-zA-Z0-9-]{0,62}$ ]] \
    || err "--name ungültig (nur a-z, 0-9, '-'; max 63 Zeichen)."

for c in qm pvesh pvesm wget curl awk grep sed; do
    command -v "$c" >/dev/null 2>&1 || err "'$c' nicht gefunden — läuft das Script auf einem Proxmox-Host?"
done

# Numerische Sanity
[[ "$MEMORY_MB" =~ ^[0-9]+$ ]] && (( MEMORY_MB >= 512 ))    || err "--memory muss >=512 sein."
[[ "$CORES"     =~ ^[0-9]+$ ]] && (( CORES     >= 1   ))    || err "--cores muss >=1 sein."
[[ "$DISK_GB"   =~ ^[0-9]+$ ]] && (( DISK_GB   >= 8   ))    || err "--disk-size muss >=8 sein."
if [[ -n "$VLAN" ]]; then
    [[ "$VLAN" =~ ^[0-9]+$ ]] && (( VLAN >= 1 && VLAN <= 4094 )) \
        || err "--vlan muss zwischen 1 und 4094 liegen."
fi

# Bridge prüfen
ip link show "$BRIDGE" >/dev/null 2>&1 \
    || err "Bridge '$BRIDGE' existiert nicht (vorhanden: $(ls /sys/class/net | tr '\n' ' '))."

# Disk-Storage prüfen
pvesm status 2>/dev/null | awk 'NR>1 {print $1}' | grep -qx "$STORAGE" \
    || err "Disk-Storage '$STORAGE' nicht gefunden (Verfügbar: $(pvesm status 2>/dev/null | awk 'NR>1{print $1}' | tr '\n' ' '))."

# ISO-Storage prüfen + content=iso
if ! pvesh get "/storage/$ISO_STORAGE" --output-format=json 2>/dev/null \
        | grep -q '"content"'; then
    err "ISO-Storage '$ISO_STORAGE' existiert nicht."
fi
ISO_CONTENT=$(pvesh get "/storage/$ISO_STORAGE" --output-format=json 2>/dev/null \
    | sed -n 's/.*"content"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
[[ "$ISO_CONTENT" == *iso* ]] \
    || err "Storage '$ISO_STORAGE' hat kein content=iso (aktuell: '$ISO_CONTENT')."

# ISO-Storage muss ein dir-basiertes Storage sein, damit wir den Pfad kennen
ISO_DIR=$(pvesh get "/storage/$ISO_STORAGE" --output-format=json 2>/dev/null \
    | sed -n 's/.*"path"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
[[ -n "$ISO_DIR" ]] \
    || err "Storage '$ISO_STORAGE' hat keinen 'path' — wird als ISO-Storage nicht unterstützt. Bitte ein dir-Storage angeben."
ISO_PATH_DIR="${ISO_DIR}/template/iso"

# VMID
if [[ -z "$VMID" ]]; then
    VMID=$(pvesh get /cluster/nextid)
fi
[[ "$VMID" =~ ^[0-9]+$ ]] && (( VMID >= 100 )) || err "VMID '$VMID' ungültig."

if qm status "$VMID" >/dev/null 2>&1; then
    err "VMID $VMID ist bereits belegt. Bitte --vmid setzen oder die VM entfernen."
fi

if qm list 2>/dev/null | awk 'NR>1 {print $2}' | grep -qx "$NAME"; then
    err "Eine VM mit Name '$NAME' existiert bereits. Wähle einen anderen --name."
fi

# ============================================================================
# ISO besorgen
# ============================================================================
resolve_latest_iso_filename() {
    # Liest SHA256SUMS und greift den ersten netinst-amd64-Eintrag
    local sha_url="${ISO_BASE_URL}/SHA256SUMS"
    curl -fsSL "$sha_url" 2>/dev/null \
        | awk '{print $2}' \
        | grep -E '^debian-[0-9.]+-amd64-netinst\.iso$' \
        | head -1
}

ensure_iso() {
    mkdir -p "$ISO_PATH_DIR"

    if [[ -z "$ISO_FILE" ]]; then
        info "Ermittle aktuellen Debian-netinst-Filenamen aus $ISO_BASE_URL/SHA256SUMS"
        ISO_FILE=$(resolve_latest_iso_filename || true)
        [[ -n "$ISO_FILE" ]] \
            || err "Konnte aktuelles netinst-ISO nicht ermitteln. --iso-file FILENAME explizit setzen."
        info "Aktuelles ISO: $ISO_FILE"
    fi

    local iso_dest="${ISO_PATH_DIR}/${ISO_FILE}"

    if [[ -f "$iso_dest" ]]; then
        info "ISO bereits vorhanden: $iso_dest"
        return
    fi

    local iso_url="${ISO_BASE_URL}/${ISO_FILE}"
    info "Lade ISO herunter: $iso_url"
    if [[ "$DRY_RUN" -eq 1 ]]; then
        echo "  [dry-run] wget -O ${iso_dest}.partial $iso_url"
        return
    fi

    wget --progress=dot:giga -O "${iso_dest}.partial" "$iso_url" \
        || { rm -f "${iso_dest}.partial"; err "Download fehlgeschlagen."; }

    # SHA256 verifizieren — best effort, schlägt nicht hart fehl wenn SUMS unerreichbar
    local expected
    expected=$(curl -fsSL "${ISO_BASE_URL}/SHA256SUMS" 2>/dev/null \
        | awk -v f="$ISO_FILE" '$2==f {print $1}')
    if [[ -n "$expected" ]]; then
        local actual
        actual=$(sha256sum "${iso_dest}.partial" | awk '{print $1}')
        if [[ "$actual" != "$expected" ]]; then
            rm -f "${iso_dest}.partial"
            err "SHA256-Mismatch beim ISO-Download (erwartet=$expected, ist=$actual)."
        fi
        info "SHA256 ok"
    else
        info "WARN: SHA256SUMS nicht erreichbar — Download nicht verifiziert."
    fi

    mv "${iso_dest}.partial" "$iso_dest"
    info "ISO bereit: $iso_dest"
}

ensure_iso

# ============================================================================
# Plan ausgeben
# ============================================================================
VLAN_OPT=""
[[ -n "$VLAN" ]] && VLAN_OPT=",tag=${VLAN}"

cat <<EOF

==================== Plan ====================
  VMID            : $VMID
  Name / Hostname : $NAME
  Memory          : ${MEMORY_MB} MB (Ballooning aus)
  CPU             : ${CORES} cores, 1 socket, type=host
  Disk            : ${DISK_GB} GB auf '${STORAGE}' (virtio-scsi-single, iothread+ssd+discard)
  NIC             : virtio @ ${BRIDGE}${VLAN_OPT:+ (VLAN ${VLAN})}
  BIOS / Machine  : OVMF (UEFI) / q35
  CD-ROM          : ${ISO_STORAGE}:iso/${ISO_FILE}
  Boot-Order      : ide2 (CD) → scsi0 (Disk)
  Guest Agent     : enabled
  Auto-Start      : $([[ $START_AFTER -eq 1 ]] && echo "ja" || echo "nein")
==============================================

EOF

# ============================================================================
# VM anlegen
# ============================================================================
info "Lege VM $VMID an..."
run qm create "$VMID" \
    --name "$NAME" \
    --memory "$MEMORY_MB" \
    --balloon 0 \
    --cores "$CORES" \
    --sockets 1 \
    --cpu host \
    --machine q35 \
    --bios ovmf \
    --efidisk0 "${STORAGE}:0,efitype=4m,pre-enrolled-keys=0" \
    --scsihw virtio-scsi-single \
    --scsi0 "${STORAGE}:${DISK_GB},iothread=1,ssd=1,discard=on" \
    --net0 "virtio,bridge=${BRIDGE}${VLAN_OPT}" \
    --ide2 "${ISO_STORAGE}:iso/${ISO_FILE},media=cdrom" \
    --boot 'order=ide2;scsi0' \
    --agent enabled=1 \
    --ostype l26 \
    --tags "reverse-proxy;debian13" \
    --description "Reverse-Proxy-Node ($NAME) — siehe https://github.com/mrckch/HA-Reverse-Proxy"

if [[ "$START_AFTER" -eq 1 ]]; then
    info "Starte VM $VMID..."
    run qm start "$VMID"
fi

cat <<EOF

VM $VMID ($NAME) angelegt.

Nächste Schritte:
  1. Konsole öffnen (Web-UI -> VM $VMID -> Console) oder:
       qm terminal $VMID         (nur wenn Serial konfiguriert)
  2. Debian-13-Installer durchklicken (Standard-System + SSH-Server reicht).
  3. Nach dem Reboot der VM in ihr:
       apt-get update && apt-get install -y git
       git clone https://github.com/mrckch/HA-Reverse-Proxy.git /opt/reverse-proxy
       cd /opt/reverse-proxy
       sudo ./scripts/bootstrap.sh

Tipp: Auf dem ZWEITEN Proxmox-Host das Script erneut aufrufen:
       $0 --name proxy02
EOF
