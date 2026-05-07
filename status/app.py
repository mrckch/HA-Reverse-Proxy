#!/usr/bin/env python3
"""
HA-Reverse-Proxy Statusseite.

Liest Snapshots aus /var/lib/proxy-status/ (von update-site-info.sh via cron
alle 5 Minuten geschrieben). Bietet drei UI-Tabs (Status / Operations / Admin)
und einen Action-Catalog für privilegierte Operationen via sudoers-Whitelist.

Lauscht standardmäßig auf 127.0.0.1:8080 — wird in Produktion via systemd
auf die Tailscale-IP gebunden (siehe systemd/proxy-status.service).
"""

from __future__ import annotations

import json
import os
import socket
import subprocess
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from flask import Flask, jsonify, render_template

app = Flask(__name__)

# ============================================================================
# Konfiguration
# ============================================================================
NODE_NAME = os.environ.get("NODE_NAME") or socket.gethostname()
NODE_ROLE = os.environ.get("NODE_ROLE", "UNKNOWN")
PEER_NAME = os.environ.get("PEER_NAME", "")
FLOATING_IP = os.environ.get("FLOATING_IP", "")

DATA_DIR = Path(os.environ.get("STATUS_DATA_DIR", "/var/lib/proxy-status"))
STATUS_FILE = DATA_DIR / "system-status.json"
HISTORY_FILE = DATA_DIR / "metrics-history.json"
KA_LOG = Path("/var/log/keepalived-state.log")

STALE_AFTER = 600  # Sekunden — danach gilt der Snapshot als veraltet

# ============================================================================
# Action-Catalog
# Befehle laufen via sudo. /etc/sudoers.d/proxy-status definiert die
# NOPASSWD-Whitelist. Niemals user-input direkt einbauen — nur ID-Lookup.
# ============================================================================
ACTIONS: list[dict[str, Any]] = [
    {
        "id": "nginx-test",
        "label": "nginx-Config testen",
        "category": "Services",
        "description": "Syntax + Semantik der nginx-Config prüfen.",
        "cmd": ["/usr/bin/sudo", "/usr/sbin/nginx", "-t"],
        "timeout": 10,
    },
    {
        "id": "nginx-reload",
        "label": "nginx neu laden",
        "category": "Services",
        "description": "Config-Reload ohne Down-Time.",
        "cmd": ["/usr/bin/sudo", "/bin/systemctl", "reload", "nginx"],
        "timeout": 15,
    },
    {
        "id": "keepalived-reload",
        "label": "keepalived neu laden",
        "category": "Services",
        "description": "VRRP-Konfiguration neu einlesen.",
        "cmd": ["/usr/bin/sudo", "/bin/systemctl", "reload", "keepalived"],
        "timeout": 15,
    },
    {
        "id": "git-pull-deploy",
        "label": "Repo pullen + deployen",
        "category": "Deployment",
        "description": "deploy.sh ausführen (git pull + rsync + nginx reload).",
        "cmd": ["/usr/bin/sudo", "/opt/reverse-proxy/scripts/deploy.sh"],
        "timeout": 90,
    },
    {
        "id": "status-refresh",
        "label": "Status sofort sammeln",
        "category": "Deployment",
        "description": "update-site-info.sh manuell ausführen.",
        "cmd": ["/usr/bin/sudo", "/opt/reverse-proxy/scripts/update-site-info.sh"],
        "timeout": 30,
    },
    {
        "id": "cert-list",
        "label": "Zertifikate auflisten",
        "category": "Zertifikate",
        "description": "Alle Let's-Encrypt-Zertifikate inkl. Ablauf anzeigen.",
        "cmd": ["/usr/bin/sudo", "/usr/bin/certbot", "certificates"],
        "timeout": 30,
    },
    {
        "id": "cert-renew",
        "label": "Zertifikate erneuern (wenn fällig)",
        "category": "Zertifikate",
        "description": "certbot renew — nur Certs <30 Tage Restlaufzeit.",
        "cmd": ["/usr/bin/sudo", "/usr/bin/certbot", "renew", "--quiet"],
        "timeout": 300,
    },
    {
        "id": "apt-update",
        "label": "apt update",
        "category": "System",
        "description": "Paket-Listen aktualisieren (kein Upgrade).",
        "cmd": ["/usr/bin/sudo", "/usr/bin/apt-get", "update"],
        "timeout": 120,
    },
    {
        "id": "security-upgrades-dry",
        "label": "Security-Updates: Dry-Run",
        "category": "System",
        "description": "Zeigt was unattended-upgrade installieren würde.",
        "cmd": ["/usr/bin/sudo", "/usr/bin/unattended-upgrade", "--dry-run", "-d"],
        "timeout": 60,
    },
    {
        "id": "security-upgrades",
        "label": "Security-Updates installieren",
        "category": "System",
        "description": "unattended-upgrade JETZT ausführen.",
        "cmd": ["/usr/bin/sudo", "/usr/bin/unattended-upgrade", "-d"],
        "timeout": 600,
        "danger": True,
        "confirm": "Security-Updates jetzt installieren? "
                   "Eventuell sind danach Reboots oder Service-Restarts nötig.",
    },
    {
        "id": "vm-reboot",
        "label": "VM neu starten",
        "category": "Gefährlich",
        "description": "Reboot dieser Node. Bei MASTER übernimmt BACKUP automatisch.",
        "cmd": ["/usr/bin/sudo", "/sbin/reboot"],
        "timeout": 5,
        "danger": True,
        "confirm": "DIESE Node JETZT neu starten? "
                   "Bei korrekt konfiguriertem keepalived übernimmt der Peer "
                   "automatisch die Floating-IP innerhalb von ~3 Sekunden.",
    },
]

ACTIONS_BY_ID = {a["id"]: a for a in ACTIONS}


# ============================================================================
# Helpers
# ============================================================================
def _read_json(path: Path) -> Any:
    try:
        with path.open("r") as f:
            return json.load(f)
    except (OSError, json.JSONDecodeError):
        return None


def _file_age_seconds(path: Path) -> float | None:
    try:
        return time.time() - path.stat().st_mtime
    except OSError:
        return None


def _load_snapshot() -> dict[str, Any]:
    data = _read_json(STATUS_FILE)
    if isinstance(data, dict):
        age = _file_age_seconds(STATUS_FILE)
        data["_age_seconds"] = age
        data["_stale"] = (age is not None and age > STALE_AFTER)
        return data

    # Fallback: noch nichts gesammelt
    return {
        "node": NODE_NAME,
        "role": NODE_ROLE,
        "peer_name": PEER_NAME,
        "floating_ip": FLOATING_IP,
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "uptime_seconds": 0,
        "load": [0, 0, 0],
        "memory": {"total_mb": 0, "used_mb": 0, "available_mb": 0, "percent": 0},
        "disk": {"total_gb": 0, "used_gb": 0, "free_gb": 0, "percent": 0},
        "keepalived": {"state": "UNKNOWN", "since": "", "service_active": False},
        "nginx": {"active": False, "version": "", "active_connections": 0,
                  "accepts": 0, "handled": 0, "requests": 0,
                  "reading": 0, "writing": 0, "waiting": 0},
        "certificates": [],
        "backends": [],
        "git": {"available": False, "commit": "", "commit_date": "",
                "commit_message": "", "clean": True},
        "peer": {"available": False, "data": None},
        "_age_seconds": None,
        "_stale": True,
        "_warning": "Noch kein Snapshot — update-site-info.sh wurde noch nicht ausgeführt.",
    }


def _systemctl_state(unit: str) -> str:
    try:
        r = subprocess.run(
            ["/bin/systemctl", "is-active", unit],
            capture_output=True, text=True, timeout=3, check=False,
        )
        return r.stdout.strip() or "unknown"
    except (subprocess.SubprocessError, FileNotFoundError):
        return "unknown"


def _run_action(action: dict[str, Any]) -> dict[str, Any]:
    cmd: list[str] = action["cmd"]
    timeout: int = action.get("timeout", 30)
    started = time.time()
    base = {
        "cmd_display": " ".join(cmd),
        "finished_at": datetime.now(timezone.utc).isoformat(),
    }
    try:
        r = subprocess.run(cmd, capture_output=True, text=True,
                           timeout=timeout, check=False)
        return {**base,
                "exit_code": r.returncode,
                "stdout": r.stdout,
                "stderr": r.stderr,
                "duration_ms": int((time.time() - started) * 1000)}
    except subprocess.TimeoutExpired as e:
        return {**base,
                "exit_code": 124,
                "stdout": e.stdout or "",
                "stderr": (e.stderr or "") + f"\n[TIMEOUT nach {timeout}s]",
                "duration_ms": int((time.time() - started) * 1000)}
    except FileNotFoundError as e:
        return {**base,
                "exit_code": 127,
                "stdout": "",
                "stderr": f"Befehl nicht gefunden: {e}",
                "duration_ms": int((time.time() - started) * 1000)}


def _common_ctx(active_tab: str) -> dict[str, Any]:
    return {
        "node": NODE_NAME,
        "role": NODE_ROLE,
        "peer": PEER_NAME,
        "floating_ip": FLOATING_IP,
        "active_tab": active_tab,
    }


# ============================================================================
# UI-Routes
# ============================================================================
@app.route("/")
def page_status():
    return render_template("status.html", **_common_ctx("status"))


@app.route("/ops")
def page_ops():
    return render_template("ops.html", **_common_ctx("ops"))


@app.route("/admin")
def page_admin():
    return render_template("admin.html", **_common_ctx("admin"))


# ============================================================================
# JSON-API
# ============================================================================
@app.route("/api/status.json")
def api_status():
    return jsonify(_load_snapshot())


@app.route("/api/history.json")
def api_history():
    data = _read_json(HISTORY_FILE) or {
        "interval_seconds": 300,
        "max_points": 288,
        "ts": [], "load1": [], "mem_pct": [],
        "disk_pct": [], "active_conns": [], "req_rate": [],
    }
    if isinstance(data, dict):
        data.pop("_last_reqs", None)
        data.pop("_last_ts", None)
    return jsonify(data)


@app.route("/api/health")
def api_health():
    state = _systemctl_state("nginx")
    if state == "active":
        return "OK", 200
    return f"FAIL ({state})", 503


@app.route("/api/services")
def api_services():
    units = ["nginx", "keepalived", "proxy-status", "proxy-deploy.timer"]
    return jsonify({u: _systemctl_state(u) for u in units})


@app.route("/api/keepalived-log")
def api_keepalived_log():
    lines: list[str] = []
    try:
        with KA_LOG.open("r") as f:
            lines = f.readlines()[-30:]
    except OSError:
        pass
    return jsonify({"lines": [line.rstrip("\n") for line in lines]})


@app.route("/api/actions", methods=["GET"])
def api_actions_list():
    visible = [
        {k: v for k, v in a.items() if k != "cmd"}
        for a in ACTIONS
    ]
    return jsonify({"actions": visible})


@app.route("/api/actions/<action_id>", methods=["POST"])
def api_actions_run(action_id: str):
    action = ACTIONS_BY_ID.get(action_id)
    if not action:
        return jsonify({"error": f"Unbekannte Aktion: {action_id}"}), 404
    return jsonify(_run_action(action))


# ============================================================================
# Main (nur fürs Direkt-Aufrufen, in Prod läuft gunicorn)
# ============================================================================
if __name__ == "__main__":
    bind = os.environ.get("STATUS_BIND_IP", "127.0.0.1")
    port = int(os.environ.get("STATUS_PORT", "8080"))
    app.run(host=bind, port=port, debug=False)
