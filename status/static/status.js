// status.js — Status-Tab: lädt Snapshot + History, rendert Sparklines, Tabellen

(function () {
    const REFRESH_MS = 30000;
    const STALE_AFTER_MS = 10 * 60 * 1000;

    async function loadAll() {
        try {
            const [snap, hist] = await Promise.all([
                HAProxy.getJSON("/api/status.json"),
                HAProxy.getJSON("/api/history.json"),
            ]);
            renderSnapshot(snap);
            renderHistory(hist);

            HAProxy.setLastUpdate(snap.timestamp);
            const age = Date.now() - new Date(snap.timestamp).getTime();
            HAProxy.setLiveIndicator(age > STALE_AFTER_MS ? "stale" : "ok");
        } catch (e) {
            HAProxy.setLiveIndicator("dead");
            console.error("Status-Load fehlgeschlagen:", e);
        }
    }

    function progressClass(pct) {
        return pct >= 85 ? "crit" : pct >= 70 ? "warn" : "";
    }

    function renderSnapshot(d) {
        // Cluster
        const selfState = d.keepalived.state || "?";
        document.getElementById("self-state").innerHTML =
            HAProxy.badge(selfState, roleKind(selfState));
        const selfCard = document.getElementById("cluster-self");
        selfCard.className = "cluster-node is-" + selfState.toLowerCase();

        if (d.peer && d.peer.available && d.peer.data) {
            const ps = d.peer.data.keepalived.state;
            document.getElementById("peer-state").innerHTML =
                HAProxy.badge(ps, roleKind(ps));
            document.getElementById("cluster-peer").className =
                "cluster-node is-" + ps.toLowerCase();
        } else {
            document.getElementById("peer-state").innerHTML =
                HAProxy.badge("offline", "warn");
        }

        // System-Metriken
        document.getElementById("m-load").textContent = d.load[0].toFixed(2);

        document.getElementById("m-mem").textContent =
            `${d.memory.percent}% (${d.memory.used_mb}/${d.memory.total_mb} MB)`;
        const memBar = document.getElementById("bar-mem");
        memBar.style.width = d.memory.percent + "%";
        memBar.className = "progress-bar " + progressClass(d.memory.percent);

        document.getElementById("m-disk").textContent =
            `${d.disk.percent}% (${d.disk.used_gb}/${d.disk.total_gb} GB)`;
        const diskBar = document.getElementById("bar-disk");
        diskBar.style.width = d.disk.percent + "%";
        diskBar.className = "progress-bar " + progressClass(d.disk.percent);

        document.getElementById("m-conns").textContent = d.nginx.active_connections ?? "—";

        document.getElementById("m-uptime").textContent = HAProxy.fmtUptime(d.uptime_seconds);
        document.getElementById("m-version").textContent = "nginx: " + (d.nginx.version || "?");

        // Zertifikate
        const certBody = document.querySelector("#tbl-certs tbody");
        if (!d.certificates || d.certificates.length === 0) {
            certBody.innerHTML = '<tr><td colspan="4" class="muted">Keine Zertifikate</td></tr>';
        } else {
            certBody.innerHTML = d.certificates.map(c => `
                <tr>
                    <td><code>${c.domain}</code></td>
                    <td>${c.expires.split("T")[0]}</td>
                    <td>${c.days_left} d</td>
                    <td>${HAProxy.badge(
                        c.critical ? "kritisch" : c.warning ? "bald" : "ok",
                        c.critical ? "error"   : c.warning ? "warn" : "ok"
                    )}</td>
                </tr>
            `).join("");
        }

        // Backends
        const beBody = document.querySelector("#tbl-backends tbody");
        if (!d.backends || d.backends.length === 0) {
            beBody.innerHTML = '<tr><td colspan="5" class="muted">Keine Backends konfiguriert</td></tr>';
        } else {
            beBody.innerHTML = d.backends.map(b => `
                <tr>
                    <td>${b.service}</td>
                    <td><code>${b.domains}</code></td>
                    <td><code>${b.backend}</code></td>
                    <td>${b.latency_ms != null ? b.latency_ms + " ms" : "—"}</td>
                    <td>${HAProxy.badge(
                        b.reachable ? "online" : "offline",
                        b.reachable ? "ok" : "error"
                    )}</td>
                </tr>
            `).join("");
        }

        // Git
        const g = d.git || {};
        if (g.available) {
            document.getElementById("git-commit").textContent = g.commit || "—";
            document.getElementById("git-date").textContent   = g.commit_date ? HAProxy.fmtTimestamp(g.commit_date) : "—";
            document.getElementById("git-msg").textContent    = g.commit_message || "—";
            document.getElementById("git-clean").innerHTML    = g.clean
                ? HAProxy.badge("clean", "ok")
                : HAProxy.badge("dirty", "warn");
        } else {
            document.getElementById("git-commit").textContent = "Repo nicht gefunden";
        }
    }

    function roleKind(state) {
        switch ((state || "").toUpperCase()) {
            case "MASTER": return "ok";
            case "BACKUP": return "info";
            case "FAULT":  return "error";
            default:       return "neutral";
        }
    }

    function renderHistory(h) {
        if (!h || !h.ts) return;

        // Aktuelle Werte unten in den Cards setzen, falls noch nichts gerendert
        const last = arr => arr && arr.length ? arr[arr.length - 1] : null;
        const reqRate = last(h.req_rate);
        if (reqRate != null) {
            document.getElementById("m-rate").textContent = reqRate.toFixed(2);
        }

        // Sparklines
        document.querySelectorAll("svg.sparkline[data-series]").forEach(svg => {
            const series = svg.dataset.series;
            const data = h[series];
            if (Array.isArray(data) && data.length >= 2) {
                HAProxy.renderSparkline(svg, data);
            }
        });
    }

    loadAll();
    setInterval(loadAll, REFRESH_MS);
})();
