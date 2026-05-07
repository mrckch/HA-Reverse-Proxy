// admin.js — Admin-Tab: Service-Status + Cert-Übersicht + keepalived-Log

(function () {
    const REFRESH_MS = 60000;

    async function load() {
        try {
            const [snap, sysd] = await Promise.all([
                HAProxy.getJSON("/api/status.json"),
                HAProxy.getJSON("/api/services").catch(() => null),
            ]);
            renderConfig(snap);
            renderServices(sysd);
            renderCertSummary(snap);
            renderKeepalivedLog();
            HAProxy.setLastUpdate(snap.timestamp);
        } catch (e) {
            console.error("Admin-Load fehlgeschlagen:", e);
            HAProxy.setLiveIndicator("dead");
        }
    }

    function renderConfig(d) {
        document.getElementById("cfg-role").textContent = d.role || "—";
        // STATUS_BIND_IP haben wir nicht direkt im Snapshot — best effort:
        document.getElementById("cfg-bind").textContent =
            (window.location.hostname || "—") + ":" + (window.location.port || "8080");
    }

    function renderServices(s) {
        const fmt = state => {
            if (state === "active")  return HAProxy.badge("aktiv", "ok");
            if (state === "inactive")return HAProxy.badge("inaktiv", "warn");
            if (state === "failed")  return HAProxy.badge("failed", "error");
            return HAProxy.badge(state || "?", "neutral");
        };
        if (!s) return;
        const map = { nginx: "svc-nginx", keepalived: "svc-keepalived",
                      "proxy-deploy.timer": "svc-timer" };
        for (const [unit, elId] of Object.entries(map)) {
            const el = document.getElementById(elId);
            if (el) el.innerHTML = fmt(s[unit] || "unknown");
        }
    }

    function renderCertSummary(d) {
        const certs = d.certificates || [];
        const el = document.getElementById("cert-summary");
        if (!certs.length) {
            el.textContent = "Keine Zertifikate vorhanden.";
            return;
        }
        const ok    = certs.filter(c => !c.warning && !c.critical).length;
        const warn  = certs.filter(c =>  c.warning && !c.critical).length;
        const crit  = certs.filter(c =>  c.critical).length;
        el.innerHTML = `
            ${HAProxy.badge(ok + " ok", "ok")}
            ${HAProxy.badge(warn + " bald ablaufend", "warn")}
            ${HAProxy.badge(crit + " kritisch", "error")}
        `;
    }

    async function renderKeepalivedLog() {
        try {
            const r = await HAProxy.getJSON("/api/keepalived-log");
            document.getElementById("ka-log").textContent =
                r.lines && r.lines.length ? r.lines.join("\n") : "(noch keine Wechsel protokolliert)";
        } catch (e) {
            document.getElementById("ka-log").textContent = "Log nicht lesbar: " + e.message;
        }
    }

    load();
    setInterval(load, REFRESH_MS);
})();
