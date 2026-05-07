// api.js — gemeinsame Helpers (alle Seiten laden das)

window.HAProxy = (function () {

    async function getJSON(url) {
        const r = await fetch(url, { headers: { "Accept": "application/json" } });
        if (!r.ok) throw new Error(`${url} → HTTP ${r.status}`);
        return r.json();
    }

    async function postJSON(url, body) {
        const r = await fetch(url, {
            method: "POST",
            headers: { "Content-Type": "application/json", "Accept": "application/json" },
            body: body ? JSON.stringify(body) : null,
        });
        const j = await r.json().catch(() => ({}));
        if (!r.ok) throw new Error(j.error || `HTTP ${r.status}`);
        return j;
    }

    function fmtUptime(s) {
        s = Math.floor(s);
        const d = Math.floor(s / 86400);
        const h = Math.floor((s % 86400) / 3600);
        const m = Math.floor((s % 3600) / 60);
        if (d > 0) return `${d}d ${h}h ${m}m`;
        if (h > 0) return `${h}h ${m}m`;
        return `${m}m`;
    }

    function fmtTimestamp(iso) {
        try { return new Date(iso).toLocaleString("de-DE"); }
        catch (e) { return iso; }
    }

    function setLiveIndicator(state) {
        const el = document.getElementById("live-indicator");
        if (!el) return;
        el.classList.remove("stale", "dead");
        if (state === "stale") el.classList.add("stale");
        if (state === "dead")  el.classList.add("dead");
    }

    function setLastUpdate(iso) {
        const el = document.getElementById("last-update");
        if (el) el.textContent = "Stand: " + fmtTimestamp(iso);
    }

    /**
     * Rendert eine Sparkline aus einem Number-Array in ein <svg>-Element.
     * Erwartet viewBox 0 0 W H und path.line + path.area children.
     */
    function renderSparkline(svg, data) {
        if (!svg || !data || data.length < 2) return;

        // viewBox auslesen
        const vb = (svg.getAttribute("viewBox") || "0 0 200 40").split(/\s+/).map(Number);
        const W = vb[2], H = vb[3];

        const padY = 2;
        const min = Math.min(...data);
        const max = Math.max(...data);
        const range = (max - min) || 1;

        const stepX = W / (data.length - 1);
        const points = data.map((v, i) => {
            const x = i * stepX;
            const y = H - padY - ((v - min) / range) * (H - 2 * padY);
            return [x, y];
        });

        const linePath = "M " + points.map(p => `${p[0].toFixed(1)} ${p[1].toFixed(1)}`).join(" L ");
        const areaPath = linePath + ` L ${W} ${H} L 0 ${H} Z`;

        // Falls noch keine Pfade da: anlegen
        if (!svg.querySelector("path.area")) {
            svg.insertAdjacentHTML("afterbegin",
                '<path class="area"></path><path class="line"></path>');
        }
        svg.querySelector("path.line").setAttribute("d", linePath);
        svg.querySelector("path.area").setAttribute("d", areaPath);
    }

    function badge(text, kind) {
        const k = kind || "neutral";
        return `<span class="badge badge-${k}">${text}</span>`;
    }

    return { getJSON, postJSON, fmtUptime, fmtTimestamp,
             setLiveIndicator, setLastUpdate, renderSparkline, badge };
})();
