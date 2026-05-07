// ops.js — Operations-Tab: Action-Liste laden, Buttons rendern, Aktionen ausführen

(function () {
    let actions = [];
    let running = false;

    async function init() {
        try {
            const data = await HAProxy.getJSON("/api/actions");
            actions = data.actions || [];
            renderList();
        } catch (e) {
            document.getElementById("ops-list").innerHTML =
                `<div class="muted">Fehler: ${e.message}</div>`;
        }
    }

    function renderList() {
        const list = document.getElementById("ops-list");
        if (!actions.length) {
            list.innerHTML = '<div class="muted">Keine Aktionen verfügbar.</div>';
            return;
        }

        // Nach Kategorie gruppieren
        const groups = {};
        for (const a of actions) {
            (groups[a.category] = groups[a.category] || []).push(a);
        }

        let html = "";
        for (const cat of Object.keys(groups).sort()) {
            html += `<div class="ops-category">${cat}</div>`;
            for (const a of groups[cat]) {
                const cls = a.danger ? "ops-button danger" : "ops-button";
                const icon = a.danger ? '<span class="icon-warn">⚠</span>' : "";
                html += `
                    <button class="${cls}" data-id="${a.id}"
                            ${a.confirm ? `data-confirm="${a.confirm}"` : ""}
                            title="${a.description || ""}">
                        ${icon}<span>${a.label}</span>
                    </button>`;
            }
        }
        list.innerHTML = html;

        list.querySelectorAll(".ops-button").forEach(btn => {
            btn.addEventListener("click", () => runAction(btn));
        });
    }

    function setRunning(state) {
        running = state;
        document.querySelectorAll(".ops-button").forEach(b => b.disabled = state);
    }

    async function runAction(btn) {
        if (running) return;
        const id = btn.dataset.id;
        const action = actions.find(a => a.id === id);
        if (!action) return;

        const confirmText = btn.dataset.confirm;
        if (confirmText && !window.confirm(confirmText)) return;

        const out = document.getElementById("ops-output");
        const badge = document.getElementById("ops-status-badge");
        const cur   = document.getElementById("ops-current-action");

        out.className = "ops-output running";
        out.textContent = "▶ " + action.label + "\n\n  läuft...\n";
        badge.className = "badge badge-info";
        badge.textContent = "läuft";
        cur.textContent = action.label;
        setRunning(true);

        try {
            const result = await HAProxy.postJSON(`/api/actions/${id}`);
            const exit = result.exit_code;
            out.className = "ops-output " + (exit === 0 ? "success" : "failure");
            badge.className = "badge " + (exit === 0 ? "badge-ok" : "badge-error");
            badge.textContent = exit === 0 ? "erfolgreich" : `Exit ${exit}`;

            const stamp = HAProxy.fmtTimestamp(result.finished_at || new Date().toISOString());
            out.textContent =
                `▶ ${action.label}  (${stamp})\n` +
                `  Befehl: ${result.cmd_display || "(intern)"}\n` +
                `  Exit-Code: ${exit}  Dauer: ${result.duration_ms} ms\n` +
                `\n--- STDOUT ---\n${result.stdout || "(leer)"}` +
                `\n\n--- STDERR ---\n${result.stderr || "(leer)"}`;
        } catch (e) {
            out.className = "ops-output failure";
            badge.className = "badge badge-error";
            badge.textContent = "Fehler";
            out.textContent = "FEHLER: " + e.message;
        } finally {
            setRunning(false);
        }
    }

    init();
})();
