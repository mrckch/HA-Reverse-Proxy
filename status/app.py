#!/usr/bin/env python3
"""
Reverse-Proxy-Statusseite.

Lauscht standardmäßig auf 127.0.0.1:8080 — wird in Produktion via systemd
auf die Tailscale-IP gebunden (siehe systemd/proxy-status.service).

Endpoints:
  /                  HTML-Dashboard
  /api/status.json   Vollständiger Status als JSON
  /api/health        Simpler 200/503 Health-Check
"""

import json
import os
import re
import socket
import ssl
import subprocess
import time
from datetime import datetime, timezone
from pathlib import Path

import requests
from flask import Flask, jsonify, render_template

app = Flask(__name__)

# === Konfiguration ===
NODE_NAME = os.environ.get("NODE_NAME", socket.gethostname())
PEER_NAME = os.environ.get("PEER_NAME", "")
PEER_URL = os.environ.get("PEER_STATUS_URL", "")  # z.B. http://proxy02:8080/api/status.json
NGINX_CONFIG_DIR = Path(os.environ.get("NGINX_CONFIG_DIR", "/etc/nginx/sites-enabled"))
LETSENCRYPT_LIVE = Path(os.environ.get("LETSENCRYPT_LIVE", "/etc/letsencrypt/live"))
KEEPALIVED_STATE_FILE = Path("/run/keepalived-state")
GIT_REPO_DIR = Path(os.environ.get("GIT_REPO_DIR", "/opt/reverse-proxy"))
NGINX_STATUS_URL = "http://127.0.0.1:8081/nginx_status"
HEALTHCHECK_FILE = Path("/run/proxy-healthcheck.json")


# === Helpers ===
def run(cmd, timeout=5):
    """Shell-Command ausführen und Stdout zurückgeben."""
    try:
        r = subprocess.run(
            cmd, shell=isinstance(cmd, str), capture_output=True,
            text=True, timeout=timeout
        )
        return r.stdout.strip(), r.returncode
    except (subprocess.TimeoutExpired, FileNotFoundError):
        return "", 1


def get_uptime():
    try:
        with open("/proc/uptime") as f:
            return float(f.read().split()[0])
    except OSError:
        return 0


def get_load():
    try:
        with open("/proc/loadavg") as f:
            parts = f.read().split()
            return [float(parts[0]), float(parts[1]), float(parts[2])]
    except OSError:
        return [0, 0, 0]


def get_memory():
    info = {}
    try:
        with open("/proc/meminfo") as f:
            for line in f:
                key, val = line.split(":")
                info[key.strip()] = int(val.strip().split()[0])  # in kB
    except OSError:
        return {}
    total = info.get("MemTotal", 0)
    available = info.get("MemAvailable", 0)
    used = total - available
    return {
        "total_mb": total // 1024,
        "used_mb": used // 1024,
        "available_mb": available // 1024,
        "percent": round(used / total * 100, 1) if total else 0,
    }


def get_disk(path="/"):
    s = os.statvfs(path)
    total = s.f_blocks * s.f_frsize
    free = s.f_bavail * s.f_frsize
    used = total - free
    return {
        "total_gb": round(total / 1024**3, 1),
        "used_gb": round(used / 1024**3, 1),
        "free_gb": round(free / 1024**3, 1),
        "percent": round(used / total * 100, 1) if total else 0,
    }


def get_keepalived_state():
    state = "UNKNOWN"
    ts = None
    if KEEPALIVED_STATE_FILE.exists():
        state = KEEPALIVED_STATE_FILE.read_text().strip()
        ts_file = Path(str(KEEPALIVED_STATE_FILE) + ".timestamp")
        if ts_file.exists():
            ts = ts_file.read_text().strip()
    out, rc = run("systemctl is-active keepalived")
    return {
        "state": state,
        "since": ts,
        "service_active": out == "active",
    }


def get_nginx_status():
    out, rc = run("systemctl is-active nginx")
    active = out == "active"
    metrics = {}
    if active:
        try:
            r = requests.get(NGINX_STATUS_URL, timeout=2)
            if r.ok:
                # Format:
                # Active connections: 5
                # server accepts handled requests
                #  100 100 200
                # Reading: 0 Writing: 1 Waiting: 4
                lines = r.text.splitlines()
                m = re.search(r"Active connections:\s+(\d+)", r.text)
                if m:
                    metrics["active"] = int(m.group(1))
                if len(lines) >= 3:
                    parts = lines[2].split()
                    if len(parts) >= 3:
                        metrics["accepts"] = int(parts[0])
                        metrics["handled"] = int(parts[1])
                        metrics["requests"] = int(parts[2])
                m = re.search(r"Reading:\s+(\d+)\s+Writing:\s+(\d+)\s+Waiting:\s+(\d+)", r.text)
                if m:
                    metrics["reading"] = int(m.group(1))
                    metrics["writing"] = int(m.group(2))
                    metrics["waiting"] = int(m.group(3))
        except requests.RequestException:
            pass
    version, _ = run("nginx -v 2>&1")
    return {
        "active": active,
        "version": version.replace("nginx version: ", ""),
        "metrics": metrics,
    }


def get_certificates():
    """Ablaufdatum jedes Let's-Encrypt-Zertifikats."""
    certs = []
    if not LETSENCRYPT_LIVE.exists():
        return certs
    for domain_dir in sorted(LETSENCRYPT_LIVE.iterdir()):
        if not domain_dir.is_dir():
            continue
        cert_path = domain_dir / "cert.pem"
        if not cert_path.exists():
            continue
        try:
            out, _ = run(f"openssl x509 -in {cert_path} -noout -enddate")
            # Format: notAfter=May 14 12:00:00 2026 GMT
            if out.startswith("notAfter="):
                date_str = out.split("=", 1)[1]
                expiry = datetime.strptime(date_str, "%b %d %H:%M:%S %Y %Z")
                expiry = expiry.replace(tzinfo=timezone.utc)
                days_left = (expiry - datetime.now(timezone.utc)).days
                certs.append({
                    "domain": domain_dir.name,
                    "expires": expiry.isoformat(),
                    "days_left": days_left,
                    "warning": days_left < 30,
                    "critical": days_left < 14,
                })
        except (ValueError, OSError):
            continue
    return certs


def get_backends():
    """Liest sites-enabled aus, extrahiert proxy_pass und checkt sie."""
    backends = []
    if not NGINX_CONFIG_DIR.exists():
        return backends
    for conf in sorted(NGINX_CONFIG_DIR.glob("*.conf")):
        try:
            text = conf.read_text()
        except OSError:
            continue
        # server_name
        names = re.findall(r"server_name\s+([^;]+);", text)
        domains = []
        for n in names:
            for d in n.split():
                if d not in ("_", "default_server"):
                    domains.append(d)
        # proxy_pass-Targets
        targets = re.findall(r"proxy_pass\s+https?://([^;/\s]+)", text)
        targets = list(dict.fromkeys(targets))  # uniq, Reihenfolge
        for target in targets:
            status = check_backend(target)
            backends.append({
                "service": conf.stem,
                "domains": domains[:3],  # nur erste 3
                "backend": target,
                "reachable": status["reachable"],
                "latency_ms": status["latency_ms"],
            })
    return backends


def check_backend(target):
    """TCP-Connect-Test auf host:port."""
    if ":" in target:
        host, port = target.rsplit(":", 1)
        try:
            port = int(port)
        except ValueError:
            return {"reachable": False, "latency_ms": None}
    else:
        host, port = target, 80
    start = time.time()
    try:
        with socket.create_connection((host, port), timeout=2):
            return {"reachable": True, "latency_ms": round((time.time() - start) * 1000, 1)}
    except (socket.error, OSError):
        return {"reachable": False, "latency_ms": None}


def get_git_status():
    info = {"available": False}
    if not GIT_REPO_DIR.exists():
        return info
    info["available"] = True
    out, _ = run(f"git -C {GIT_REPO_DIR} rev-parse --short HEAD")
    info["commit"] = out
    out, _ = run(f"git -C {GIT_REPO_DIR} log -1 --format=%cd --date=iso")
    info["commit_date"] = out
    out, _ = run(f"git -C {GIT_REPO_DIR} log -1 --format=%s")
    info["commit_message"] = out
    out, _ = run(f"git -C {GIT_REPO_DIR} status --porcelain")
    info["clean"] = (out == "")
    return info


def get_peer_status():
    """Statusseite des Peers abfragen (für Cluster-Übersicht)."""
    if not PEER_URL:
        return {"available": False}
    try:
        r = requests.get(PEER_URL, timeout=3)
        if r.ok:
            return {"available": True, "data": r.json()}
    except requests.RequestException:
        pass
    return {"available": False}


def collect_status():
    return {
        "node": NODE_NAME,
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "uptime_seconds": get_uptime(),
        "load": get_load(),
        "memory": get_memory(),
        "disk": get_disk(),
        "keepalived": get_keepalived_state(),
        "nginx": get_nginx_status(),
        "certificates": get_certificates(),
        "backends": get_backends(),
        "git": get_git_status(),
        "peer": get_peer_status(),
    }


# === Routes ===
@app.route("/")
def index():
    return render_template("status.html", node=NODE_NAME, peer=PEER_NAME)


@app.route("/api/status.json")
def status_json():
    return jsonify(collect_status())


@app.route("/api/health")
def health():
    nginx = get_nginx_status()
    if nginx["active"]:
        return "OK", 200
    return "FAIL", 503


if __name__ == "__main__":
    bind = os.environ.get("STATUS_BIND", "127.0.0.1")
    port = int(os.environ.get("STATUS_PORT", "8080"))
    app.run(host=bind, port=port, debug=False)
