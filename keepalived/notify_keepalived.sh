#!/bin/bash
# /usr/local/bin/notify_keepalived.sh
# Wird von keepalived bei State-Changes aufgerufen.
# Loggt den Wechsel und schreibt ihn in eine Datei, die die Statusseite ausliest.

STATE="$1"
TS=$(date -Iseconds)
LOG=/var/log/keepalived-state.log
STATE_FILE=/run/keepalived-state

echo "${TS} state=${STATE}" >> "${LOG}"
echo "${STATE}" > "${STATE_FILE}"
echo "${TS}" > "${STATE_FILE}.timestamp"

# Optional: Webhook/Notification
# curl -s -X POST "${NOTIFY_WEBHOOK_URL}" -d "node=$(hostname) state=${STATE} ts=${TS}"

exit 0
