#!/bin/bash
# /usr/local/bin/check_nginx.sh
# Prüft ob nginx läuft und Requests beantwortet.
# Bei Exit-Code != 0 senkt keepalived die Priorität → BACKUP übernimmt.

set -u

# Ist der Prozess da?
if ! pgrep -x nginx >/dev/null; then
    exit 1
fi

# Antwortet er auch?
if ! curl -s -f -m 2 -o /dev/null http://127.0.0.1:8081/nginx_status; then
    exit 1
fi

exit 0
