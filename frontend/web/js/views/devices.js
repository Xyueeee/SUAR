/* Devices: roster of every device that has registered or relayed, with bundle
 * counts, edit (mode/version) and delete (cascades that device's bundles). */
window.SUAR = window.SUAR || {};
SUAR.views = SUAR.views || {};

SUAR.views.devices = (function () {
  let search = "", sortKey = "lastseen";
  let allRows = [];
  const selected = new Set();

  async function render(container) {
    container.innerHTML =
      '<div class="list-toolbar">' +
        '<input class="input" id="dv-search" placeholder="Search device ID…" value="' + SUAR.ui.esc(search) + '" style="max-width:240px">' +
        '<select class="select" id="dv-sort" style="max-width:175px">' +
          [["lastseen", "Last seen"], ["bundles", "Bundle count"], ["mode", "Mode"], ["version", "App version"]]
            .map((o) => '<option value="' + o[0] + '"' + (sortKey === o[0] ? " selected" : "") + ">" + o[1] + "</option>").join("") +
        "</select>" +
        '<div class="bulkbar" id="dv-bulk" style="display:none"><span class="muted" id="dv-selcount"></span><button class="btn btn--danger btn--sm" data-bulk="del">Delete</button></div>' +
      "</div>" +
      '<div class="card"><div class="table-wrap" id="d-table">' + SUAR.ui.spinner() + "</div></div>";
    document.getElementById("dv-search").addEventListener("input", (e) => { search = e.target.value; renderTable(); });
    document.getElementById("dv-sort").addEventListener("change", (e) => { sortKey = e.target.value; renderTable(); });
    document.querySelectorAll("[data-bulk]").forEach((b) => b.addEventListener("click", () => bulkDelete()));
    await load();
  }

  async function load() {
    const wrap = document.getElementById("d-table");
    wrap.innerHTML = SUAR.ui.spinner();
    allRows = await SUAR.api.get("/admin/devices");
    selected.clear(); updateBulkBar();
    renderTable();
  }

  function updateBulkBar() {
    const bar = document.getElementById("dv-bulk");
    if (!bar) return;
    bar.style.display = selected.size ? "flex" : "none";
    const c = document.getElementById("dv-selcount");
    if (c) c.textContent = selected.size + " selected";
  }

  function syncSelAll() {
    const el = document.getElementById("dv-selall");
    if (!el) return;
    const rows = visibleRows();
    el.checked = rows.length > 0 && rows.every((d) => selected.has(d.deviceid));
  }

  async function bulkDelete() {
    if (!selected.size) return;
    const ids = [...selected];
    const ok = await SUAR.ui.confirm({ title: "Delete " + ids.length + " device(s)?", message: "Also deletes their bundles and data. Cannot be undone.", confirmLabel: "Delete", danger: true });
    if (!ok) return;
    try {
      for (const id of ids) await SUAR.api.del("/admin/devices/" + encodeURIComponent(id));
      SUAR.ui.toast("Deleted (" + ids.length + ")", "ok"); selected.clear(); load(); SUAR.app.refreshCounts();
    } catch (e) { SUAR.ui.toast(e.message, "err"); load(); }
  }

  function visibleRows() {
    let rows = allRows.slice();
    const q = search.trim().toLowerCase();
    if (q) rows = rows.filter((d) => (d.deviceid || "").toLowerCase().includes(q));
    rows.sort((a, b) => {
      if (sortKey === "bundles") return (b.bundleCount ?? 0) - (a.bundleCount ?? 0);
      if (sortKey === "mode") return (a.applicationmode || "").localeCompare(b.applicationmode || "");
      if (sortKey === "version") return (a.applicationversion || "").localeCompare(b.applicationversion || "");
      return new Date(b.lastseenat || 0) - new Date(a.lastseenat || 0);
    });
    return rows;
  }

  function renderTable() {
    const wrap = document.getElementById("d-table");
    if (!wrap) return;
    const rows = visibleRows();
    if (!rows.length) { wrap.innerHTML = SUAR.ui.empty(search ? "No matches" : "No devices yet", search ? "Try a different search." : "Devices register on their first sync."); return; }
    wrap.innerHTML =
      '<table class="data"><thead><tr><th style="width:34px"><input type="checkbox" id="dv-selall"></th><th>Device ID</th><th>Mode</th><th>Version</th><th>Bundles</th><th>Last seen</th><th></th></tr></thead><tbody>' +
      rows.map((d) =>
        "<tr>" +
        '<td><input type="checkbox" class="dv-sel"' + (selected.has(d.deviceid) ? " checked" : "") + "></td>" +
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
      tr.querySelector(".dv-sel").addEventListener("change", (e) => { e.target.checked ? selected.add(d.deviceid) : selected.delete(d.deviceid); updateBulkBar(); syncSelAll(); });
      tr.querySelector("[data-edit]").addEventListener("click", () => openEdit(d));
      tr.querySelector("[data-del]").addEventListener("click", () => del(d));
    });
    const selall = wrap.querySelector("#dv-selall");
    selall.addEventListener("change", (e) => {
      rows.forEach((d) => e.target.checked ? selected.add(d.deviceid) : selected.delete(d.deviceid));
      updateBulkBar(); renderTable();
    });
    syncSelAll();
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
