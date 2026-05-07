#!/bin/bash
# scripts/update-site-info.sh
#
# Sammelt System- und Service-Metriken, schreibt:
#   /var/lib/proxy-status/system-status.json    (Snapshot)
#   /var/lib/proxy-status/metrics-history.json  (288-Punkt-Rolling-Window, 24h bei 5min)
#
# Wird via /etc/cron.d/proxy-status alle 5 Min als root ausgeführt.
# Atomisches Schreiben via mv (kein Race mit Flask-Reader).

set -euo pipefail

DATA_DIR=/var/lib/proxy-status
STATUS_FILE="$DATA_DIR/system-status.json"
HISTORY_FILE="$DATA_DIR/metrics-history.json"
HEALTH_FILE=/run/proxy-healthcheck.json
CONFIG=/etc/proxy-config/values.env
NGINX_STATUS_URL="http://127.0.0.1:8081/nginx_status"
LETSENCRYPT_LIVE=/etc/letsencrypt/live
KEEPALIVED_STATE=/run/keepalived-state
REPO_DIR=/opt/reverse-proxy
MAX_POINTS=288
INTERVAL=300

mkdir -p "$DATA_DIR"

# Werte aus values.env (mit Defaults)
NODE_NAME="$(hostname)"
NODE_ROLE="UNKNOWN"
PEER_NAME=""
PEER_TAILSCALE_IP=""
FLOATING_IP=""
if [[ -r "$CONFIG" ]]; then
    # shellcheck disable=SC1090
    source "$CONFIG"
fi

now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }
now_epoch() { date +%s; }

# === Sammler ===
collect_uptime()    { awk '{print int($1)}' /proc/uptime; }
collect_load()      { awk '{printf "[%s,%s,%s]", $1,$2,$3}' /proc/loadavg; }

collect_memory() {
    local total avail used pct
    total=$(awk '/^MemTotal:/   {print $2}' /proc/meminfo)
    avail=$(awk '/^MemAvailable:/{print $2}' /proc/meminfo)
    used=$((total - avail))
    pct=$(awk -v u="$used" -v t="$total" 'BEGIN{ if(t>0) printf "%.1f", u*100/t; else print "0"}')
    printf '{"total_mb":%d,"used_mb":%d,"available_mb":%d,"percent":%s}' \
        "$((total/1024))" "$((used/1024))" "$((avail/1024))" "$pct"
}

collect_disk() {
    df -B1 / | awk 'NR==2 {
        printf "{\"total_gb\":%.1f,\"used_gb\":%.1f,\"free_gb\":%.1f,\"percent\":%.1f}",
            $2/1073741824, $3/1073741824, $4/1073741824, ($3*100/$2)
    }'
}

collect_keepalived() {
    local state="UNKNOWN" since="" active="false"
    [[ -r "$KEEPALIVED_STATE" ]] && state=$(tr -d '\n' < "$KEEPALIVED_STATE")
    [[ -r "${KEEPALIVED_STATE}.timestamp" ]] && since=$(tr -d '\n' < "${KEEPALIVED_STATE}.timestamp")
    systemctl is-active --quiet keepalived && active="true"
    printf '{"state":"%s","since":"%s","service_active":%s}' "$state" "$since" "$active"
}

collect_nginx() {
    local active="false" version="" active_conns=0 reading=0 writing=0 waiting=0
    local accepts=0 handled=0 requests=0
    systemctl is-active --quiet nginx && active="true"
    version=$(nginx -v 2>&1 | sed 's|nginx version: ||' | tr -d '\n' | sed 's/"/\\"/g')

    if [[ "$active" == "true" ]]; then
        local body
        body=$(curl -s -m 2 "$NGINX_STATUS_URL" || true)
        if [[ -n "$body" ]]; then
            active_conns=$(echo "$body" | awk '/Active connections:/ {print $3}')
            read -r accepts handled requests <<< "$(echo "$body" | awk 'NR==3 {print $1, $2, $3}')"
            reading=$(echo "$body" | awk '/Reading:/ {print $2}')
            writing=$(echo "$body" | awk '/Reading:/ {print $4}')
            waiting=$(echo "$body" | awk '/Reading:/ {print $6}')
        fi
    fi
    printf '{"active":%s,"version":"%s","active_connections":%d,"accepts":%d,"handled":%d,"requests":%d,"reading":%d,"writing":%d,"waiting":%d}' \
        "$active" "$version" "${active_conns:-0}" "${accepts:-0}" "${handled:-0}" "${requests:-0}" \
        "${reading:-0}" "${writing:-0}" "${waiting:-0}"
}

collect_certificates() {
    local out="["
    local first=1 now_s domain expiry_s days_left expiry_iso
    now_s=$(now_epoch)
    if [[ -d "$LETSENCRYPT_LIVE" ]]; then
        for dir in "$LETSENCRYPT_LIVE"/*/; do
            [[ -d "$dir" ]] || continue
            domain=$(basename "$dir")
            [[ -f "${dir}cert.pem" ]] || continue
            expiry_iso=$(openssl x509 -in "${dir}cert.pem" -noout -enddate 2>/dev/null | cut -d= -f2 || echo "")
            [[ -z "$expiry_iso" ]] && continue
            expiry_s=$(date -d "$expiry_iso" +%s 2>/dev/null || echo 0)
            days_left=$(( (expiry_s - now_s) / 86400 ))
            [[ $first -eq 0 ]] && out+=","
            first=0
            out+=$(printf '{"domain":"%s","expires":"%s","days_left":%d,"warning":%s,"critical":%s}' \
                "$domain" "$expiry_iso" "$days_left" \
                "$([[ $days_left -lt 30 ]] && echo true || echo false)" \
                "$([[ $days_left -lt 14 ]] && echo true || echo false)")
        done
    fi
    out+="]"
    echo "$out"
}

collect_backends() {
    local out="["
    local first=1 conf domains targets target host port reachable=false latency=null start end
    if [[ -d /etc/nginx/sites-enabled ]]; then
        for conf in /etc/nginx/sites-enabled/*.conf; do
            [[ -f "$conf" ]] || continue
            local svc; svc=$(basename "$conf" .conf)
            domains=$(grep -hE '^\s*server_name\s' "$conf" 2>/dev/null | \
                head -1 | sed -E 's/.*server_name\s+([^;]+);.*/\1/' | tr -s ' ')
            targets=$(grep -hE '^\s*proxy_pass\s' "$conf" 2>/dev/null | \
                sed -E 's|.*proxy_pass\s+https?://([^/;[:space:]]+).*|\1|' | sort -u)
            for target in $targets; do
                [[ -z "$target" ]] && continue
                host="${target%:*}"
                port="${target##*:}"
                [[ "$host" == "$port" ]] && port=80
                reachable=false
                latency=null
                start=$(date +%s%3N 2>/dev/null || date +%s)
                if timeout 2 bash -c "exec 3<>/dev/tcp/$host/$port" 2>/dev/null; then
                    end=$(date +%s%3N 2>/dev/null || date +%s)
                    reachable=true
                    latency=$((end - start))
                    exec 3<&- 2>/dev/null || true
                    exec 3>&- 2>/dev/null || true
                fi
                [[ $first -eq 0 ]] && out+=","
                first=0
                out+=$(printf '{"service":"%s","domains":"%s","backend":"%s","reachable":%s,"latency_ms":%s}' \
                    "$svc" "$domains" "$target" "$reachable" "$latency")
            done
        done
    fi
    out+="]"
    echo "$out"
}

collect_git() {
    local available=false commit="" cdate="" cmsg="" clean=true
    if [[ -d "$REPO_DIR/.git" ]]; then
        available=true
        commit=$(git -C "$REPO_DIR" rev-parse --short HEAD 2>/dev/null || echo "")
        cdate=$(git -C "$REPO_DIR" log -1 --format=%cI 2>/dev/null || echo "")
        cmsg=$(git -C "$REPO_DIR" log -1 --format=%s 2>/dev/null | sed 's/"/\\"/g' | tr -d '\n' || echo "")
        [[ -n $(git -C "$REPO_DIR" status --porcelain 2>/dev/null) ]] && clean=false
    fi
    printf '{"available":%s,"commit":"%s","commit_date":"%s","commit_message":"%s","clean":%s}' \
        "$available" "$commit" "$cdate" "$cmsg" "$clean"
}

collect_peer() {
    local available=false data="null"
    if [[ -n "$PEER_TAILSCALE_IP" ]]; then
        local body
        body=$(curl -s -m 3 "http://${PEER_TAILSCALE_IP}:8080/api/status.json" 2>/dev/null || true)
        if [[ -n "$body" ]] && echo "$body" | jq empty 2>/dev/null; then
            available=true
            data="$body"
        fi
    fi
    printf '{"available":%s,"data":%s}' "$available" "$data"
}

# === Snapshot bauen ===
TS=$(now_iso)
UPTIME=$(collect_uptime)
LOAD=$(collect_load)
MEM=$(collect_memory)
DISK=$(collect_disk)
KA=$(collect_keepalived)
NGINX=$(collect_nginx)
CERTS=$(collect_certificates)
BACKENDS=$(collect_backends)
GIT=$(collect_git)
PEER=$(collect_peer)

cat > "${STATUS_FILE}.tmp" <<EOF
{
  "node": "$NODE_NAME",
  "role": "$NODE_ROLE",
  "peer_name": "$PEER_NAME",
  "floating_ip": "$FLOATING_IP",
  "timestamp": "$TS",
  "uptime_seconds": $UPTIME,
  "load": $LOAD,
  "memory": $MEM,
  "disk": $DISK,
  "keepalived": $KA,
  "nginx": $NGINX,
  "certificates": $CERTS,
  "backends": $BACKENDS,
  "git": $GIT,
  "peer": $PEER
}
EOF

# Validieren, dann atomisch verschieben
if jq empty "${STATUS_FILE}.tmp" 2>/dev/null; then
    mv "${STATUS_FILE}.tmp" "$STATUS_FILE"
else
    echo "FEHLER: ungültiges JSON in ${STATUS_FILE}.tmp" >&2
    exit 1
fi

# === History updaten ===
TS_EPOCH=$(now_epoch)
LOAD1=$(awk '{print $1}' /proc/loadavg)
MEM_PCT=$(echo "$MEM" | jq -r .percent)
DISK_PCT=$(echo "$DISK" | jq -r .percent)
ACTIVE=$(echo "$NGINX" | jq -r .active_connections)
REQS=$(echo "$NGINX" | jq -r .requests)

if [[ -f "$HISTORY_FILE" ]] && jq empty "$HISTORY_FILE" 2>/dev/null; then
    HIST=$(cat "$HISTORY_FILE")
else
    HIST=$(printf '{"interval_seconds":%d,"max_points":%d,"ts":[],"load1":[],"mem_pct":[],"disk_pct":[],"active_conns":[],"req_rate":[],"_last_reqs":0,"_last_ts":0}' \
        "$INTERVAL" "$MAX_POINTS")
fi

# Request-Rate berechnen (Δrequests / Δseconds)
LAST_REQS=$(echo "$HIST" | jq -r '._last_reqs // 0')
LAST_TS=$(echo "$HIST" | jq -r '._last_ts // 0')
if [[ "$LAST_TS" -gt 0 ]]; then
    DELTA_REQ=$(( REQS - LAST_REQS ))
    DELTA_T=$(( TS_EPOCH - LAST_TS ))
    [[ $DELTA_T -le 0 ]] && DELTA_T=1
    [[ $DELTA_REQ -lt 0 ]] && DELTA_REQ=0   # nginx-Reload setzt Counter zurück
    REQ_RATE=$(awk -v r="$DELTA_REQ" -v t="$DELTA_T" 'BEGIN{printf "%.2f", r/t}')
else
    REQ_RATE=0
fi

# Append + Trim
HIST=$(echo "$HIST" | jq \
    --arg ts "$TS" \
    --argjson load "$LOAD1" \
    --argjson mem "$MEM_PCT" \
    --argjson disk "$DISK_PCT" \
    --argjson active "$ACTIVE" \
    --argjson rate "$REQ_RATE" \
    --argjson reqs "$REQS" \
    --argjson tsep "$TS_EPOCH" \
    --argjson max "$MAX_POINTS" \
    '
    .ts            = (.ts            + [$ts])     | .ts            |= .[(-($max)):]
  | .load1         = (.load1         + [$load])   | .load1         |= .[(-($max)):]
  | .mem_pct       = (.mem_pct       + [$mem])    | .mem_pct       |= .[(-($max)):]
  | .disk_pct      = (.disk_pct      + [$disk])   | .disk_pct      |= .[(-($max)):]
  | .active_conns  = (.active_conns  + [$active]) | .active_conns  |= .[(-($max)):]
  | .req_rate      = (.req_rate      + [$rate])   | .req_rate      |= .[(-($max)):]
  | ._last_reqs    = $reqs
  | ._last_ts      = $tsep
    ')

echo "$HIST" > "${HISTORY_FILE}.tmp"
if jq empty "${HISTORY_FILE}.tmp" 2>/dev/null; then
    mv "${HISTORY_FILE}.tmp" "$HISTORY_FILE"
else
    rm -f "${HISTORY_FILE}.tmp"
    echo "FEHLER: History-Update produzierte ungültiges JSON" >&2
    exit 1
fi

# Healthcheck-Marker (für check_nginx.sh Cross-Check)
NGINX_OK=$(echo "$NGINX" | jq -r .active)
KA_OK=$(echo "$KA" | jq -r .service_active)
printf '{"timestamp":"%s","nginx":%s,"keepalived":%s}\n' \
    "$TS" "$NGINX_OK" "$KA_OK" > "$HEALTH_FILE"

# Permissions: root:proxy-status, lesbar für die Flask-App
chgrp proxy-status "$STATUS_FILE" "$HISTORY_FILE" 2>/dev/null || true
chmod 0640         "$STATUS_FILE" "$HISTORY_FILE" 2>/dev/null || true
