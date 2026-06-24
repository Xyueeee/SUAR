/* Devices: roster of every device that has registered or relayed, with bundle
 * counts, edit (mode/version) and delete (cascades that device's bundles). */
window.SUAR = window.SUAR || {};
SUAR.views = SUAR.views || {};

SUAR.views.devices = (function () {
  async function render(container) {
    container.innerHTML = '<div class="card"><div class="table-wrap" id="d-table">' + SUAR.ui.spinner() + "</div></div>";
    await load();
  }

  async function load() {
    const wrap = document.getElementById("d-table");
    wrap.innerHTML = SUAR.ui.spinner();
    const rows = await SUAR.api.get("/admin/devices");
    if (!rows.length) { wrap.innerHTML = SUAR.ui.empty("No devices yet", "Devices register on their first sync."); return; }
    wrap.innerHTML =
      '<table class="data"><thead><tr><th>Device ID</th><th>Mode</th><th>Version</th><th>Bundles</th><th>Last seen</th><th></th></tr></thead><tbody>' +
      rows.map((d) =>
        "<tr>" +
        '<td class="mono-cell">' + SUAR.ui.esc(d.deviceid) + "</td>" +
        "<td>" + modeChip(d.applicationmode) + "</td>" +
        '<td class="mono-cell">' + SUAR.ui.esc(d.applicationversion || "—") + "</td>" +
        '<td class="mono-cell">' + (d.bundleCount ?? 0) + "</td>" +
        '<td class="muted">' + SUAR.ui.fmtRelative(d.lastseenat) + "</td>" +
        '<td class="cell-actions">' +
          '<button class="btn btn--ghost btn--sm" data-edit>Edit</button>' +
          '<button class="btn btn--danger btn--sm" data-del>Delete</button>' +
        "</td></tr>"
      ).join("") + "</tbody></table>";

    rows.forEach((d, i) => {
      const tr = wrap.querySelectorAll("tbody tr")[i];
      tr.querySelector("[data-edit]").addEventListener("click", () => openEdit(d));
      tr.querySelector("[data-del]").addEventListener("click", () => del(d));
    });
  }

  function modeChip(m) {
    if (m === "helper") return '<span class="chip chip--on">helper</span>';
    if (m === "victim") return '<span class="badge badge--High">victim</span>';
    return '<span class="chip">' + SUAR.ui.esc(m || "—") + "</span>";
  }

  function openEdit(d) {
    SUAR.ui.modal({
      title: "Edit device",
      body:
        '<div class="field"><label>Device ID</label><input class="input mono" value="' + SUAR.ui.esc(d.deviceid) + '" disabled></div>' +
        '<div class="form-row">' +
          '<div class="field"><label>Mode</label><select class="select" id="d-mode">' +
            '<option value="victim"' + (d.applicationmode === "victim" ? " selected" : "") + ">victim</option>" +
            '<option value="helper"' + (d.applicationmode === "helper" ? " selected" : "") + ">helper</option></select></div>" +
          '<div class="field"><label>App version</label><input class="input" id="d-ver" value="' + SUAR.ui.esc(d.applicationversion || "") + '"></div>' +
        "</div>",
      actions: [
        { label: "Cancel", className: "btn--ghost", onClick: (c) => c() },
        { label: "Save", className: "btn--primary", onClick: async (close, btn) => {
            btn.disabled = true;
            try {
              await SUAR.api.patch("/admin/devices/" + encodeURIComponent(d.deviceid), {
                applicationmode: document.getElementById("d-mode").value,
                applicationversion: document.getElementById("d-ver").value,
              });
              SUAR.ui.toast("Device updated", "ok"); close(); load();
            } catch (e) { SUAR.ui.toast(e.message, "err"); btn.disabled = false; }
          } },
      ],
    });
  }

  async function del(d) {
    const ok = await SUAR.ui.confirm({
      title: "Delete device?",
      message: "Deleting " + SUAR.ui.truncId(d.deviceid, 12) + " also deletes its " + (d.bundleCount ?? 0) + " bundle(s) and their data. Cannot be undone.",
      confirmLabel: "Delete", danger: true,
    });
    if (!ok) return;
    try {
      await SUAR.api.del("/admin/devices/" + encodeURIComponent(d.deviceid));
      SUAR.ui.toast("Device deleted", "ok"); load(); SUAR.app.refreshCounts();
    } catch (e) { SUAR.ui.toast(e.message, "err"); }
  }

  return { render };
})();
