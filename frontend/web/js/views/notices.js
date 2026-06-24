/* Notices: advisory broadcasts. Plain CRUD; the app polls GET /notices in a
 * later increment to show active, non-expired ones. */
window.SUAR = window.SUAR || {};
SUAR.views = SUAR.views || {};

SUAR.views.notices = (function () {
  const SEVS = ["info", "advisory", "warning", "critical"];

  async function render(container) {
    container.innerHTML =
      '<div class="view__head"><span class="eyebrow">Advisories pushed to devices</span><span class="spacer"></span>' +
      '<button class="btn btn--primary btn--sm" id="n-new">+ New notice</button></div>' +
      '<div class="card"><div class="table-wrap" id="n-table">' + SUAR.ui.spinner() + "</div></div>";
    document.getElementById("n-new").addEventListener("click", () => openForm(null));
    await load();
  }

  async function load() {
    const wrap = document.getElementById("n-table");
    wrap.innerHTML = SUAR.ui.spinner();
    const rows = await SUAR.api.get("/admin/notices");
    if (!rows.length) { wrap.innerHTML = SUAR.ui.empty("No notices", "Create one to broadcast an advisory."); return; }
    wrap.innerHTML =
      '<table class="data"><thead><tr><th>Title</th><th>Severity</th><th>Status</th><th>Expires</th><th>Updated</th><th></th></tr></thead><tbody>' +
      rows.map((n) =>
        "<tr>" +
        "<td><b>" + SUAR.ui.esc(n.title) + "</b><div class='muted' style='font-size:12px;max-width:340px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis'>" + SUAR.ui.esc(n.body) + "</div></td>" +
        "<td>" + SUAR.ui.severityBadge(n.severity) + "</td>" +
        "<td>" + (n.isactive ? '<span class="chip chip--on">active</span>' : '<span class="chip chip--off">inactive</span>') + "</td>" +
        '<td class="muted">' + (n.expiresat ? SUAR.ui.fmtDate(n.expiresat) : "—") + "</td>" +
        '<td class="muted">' + SUAR.ui.fmtRelative(n.updatedat) + "</td>" +
        '<td class="cell-actions"><button class="btn btn--ghost btn--sm" data-edit>Edit</button><button class="btn btn--danger btn--sm" data-del>Delete</button></td>' +
        "</tr>"
      ).join("") + "</tbody></table>";
    rows.forEach((n, i) => {
      const tr = wrap.querySelectorAll("tbody tr")[i];
      tr.querySelector("[data-edit]").addEventListener("click", () => openForm(n));
      tr.querySelector("[data-del]").addEventListener("click", () => del(n));
    });
  }

  function toLocalInput(iso) {
    if (!iso) return "";
    const d = new Date(iso);
    if (isNaN(d)) return "";
    const off = d.getTimezoneOffset();
    return new Date(d.getTime() - off * 60000).toISOString().slice(0, 16);
  }

  function openForm(n) {
    const editing = !!n;
    n = n || {};
    SUAR.ui.modal({
      title: editing ? "Edit notice" : "New notice",
      body:
        '<div class="field"><label>Title</label><input class="input" id="n-title" value="' + SUAR.ui.esc(n.title || "") + '"></div>' +
        '<div class="field"><label>Message</label><textarea class="textarea" id="n-body">' + SUAR.ui.esc(n.body || "") + "</textarea></div>" +
        '<div class="form-row">' +
          '<div class="field"><label>Severity</label><select class="select" id="n-sev">' +
            SEVS.map((s) => '<option' + (n.severity === s ? " selected" : "") + ">" + s + "</option>").join("") + "</select></div>" +
          '<div class="field"><label>Expires (optional)</label><input class="input" id="n-exp" type="datetime-local" value="' + toLocalInput(n.expiresat) + '"></div>' +
        "</div>" +
        '<label class="switch"><input type="checkbox" id="n-active"' + (n.isactive === false ? "" : " checked") + '><span class="switch__track"></span> Active</label>',
      actions: [
        { label: "Cancel", className: "btn--ghost", onClick: (c) => c() },
        { label: editing ? "Save" : "Create", className: "btn--primary", onClick: async (close, btn) => {
            const body = {
              title: document.getElementById("n-title").value.trim(),
              body: document.getElementById("n-body").value.trim(),
              severity: document.getElementById("n-sev").value,
              isactive: document.getElementById("n-active").checked,
              expiresat: document.getElementById("n-exp").value ? new Date(document.getElementById("n-exp").value).toISOString() : null,
            };
            if (!body.title || !body.body) { SUAR.ui.toast("Title and message required", "err"); return; }
            btn.disabled = true;
            try {
              if (editing) await SUAR.api.patch("/admin/notices/" + encodeURIComponent(n.noticeid), body);
              else await SUAR.api.post("/admin/notices", body);
              SUAR.ui.toast(editing ? "Notice updated" : "Notice created", "ok"); close(); load(); SUAR.app.refreshCounts();
            } catch (e) { SUAR.ui.toast(e.message, "err"); btn.disabled = false; }
          } },
      ],
    });
  }

  async function del(n) {
    const ok = await SUAR.ui.confirm({ title: "Delete notice?", message: 'Remove "' + n.title + '"?', confirmLabel: "Delete", danger: true });
    if (!ok) return;
    try {
      await SUAR.api.del("/admin/notices/" + encodeURIComponent(n.noticeid));
      SUAR.ui.toast("Notice deleted", "ok"); load(); SUAR.app.refreshCounts();
    } catch (e) { SUAR.ui.toast(e.message, "err"); }
  }

  return { render };
})();
