/* Devices: roster of every device that has registered or relayed, with bundle
 * counts, edit (mode/version) and delete (cascades that device's bundles). */
window.SUAR = window.SUAR || {};
SUAR.views = SUAR.views || {};

SUAR.views.devices = (function () {
  let search = "", sortKey = "lastseen";
  let allRows = [];
  let _detailOpen = false;
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
    if (q) rows = rows.filter((d) =>
      (d.deviceid || "").toLowerCase().includes(q) ||
      (d.hardwareid || "").toLowerCase().includes(q));
    rows.sort((a, b) => {
      if (sortKey === "bundles") return (b.bundleCount ?? 0) - (a.bundleCount ?? 0);
      if (sortKey === "mode") return (a.applicationmode || "").localeCompare(b.applicationmode || "");
      if (sortKey === "version") return (a.applicationversion || "").localeCompare(b.applicationversion || "");
      return new Date(b.lastseenat || 0) - new Date(a.lastseenat || 0);
    });
    return rows;
  }

  function lastSeenCell(iso) {
    if (!iso) return '<span class="muted">—</span>';
    const diff = (Date.now() - new Date(iso)) / 1000;
    const label = SUAR.ui.fmtRelative(iso);
    if (!isNaN(diff) && diff < 3600) return '<span style="color:var(--ok)">' + label + "</span>";
    if (!isNaN(diff) && diff < 86400) return '<span style="color:var(--moderate)">' + label + "</span>";
    return '<span class="muted">' + label + "</span>";
  }

  // deviceId is a random UUID that resets on reinstall/data-clear, so the
  // same physical phone can show up as several rows over its lifetime.
  // hardwareid (Settings.Secure.ANDROID_ID) survives that — count how many
  // rows share one, so a repeat can be flagged instead of silently miscounted
  // as separate devices.
  function hardwareIdCounts(rows) {
    const counts = {};
    rows.forEach((d) => { if (d.hardwareid) counts[d.hardwareid] = (counts[d.hardwareid] || 0) + 1; });
    return counts;
  }

  function hardwareIdCell(d, counts) {
    if (!d.hardwareid) return '<span class="muted">—</span>';
    const dup = counts[d.hardwareid] > 1;
    return '<span class="mono-cell"' + (dup ? ' title="Same physical phone as another device ID"' : '') + '>' +
      SUAR.ui.truncId(d.hardwareid, 12) + (dup ? ' <span class="chip chip--on">dup</span>' : '') + '</span>';
  }

  function renderTable() {
    const wrap = document.getElementById("d-table");
    if (!wrap) return;
    const rows = visibleRows();
    if (!rows.length) { wrap.innerHTML = SUAR.ui.empty(search ? "No matches" : "No devices yet", search ? "Try a different search." : "Devices register on their first sync."); return; }
    const hwCounts = hardwareIdCounts(allRows);
    wrap.innerHTML =
      '<table class="data"><thead><tr><th style="width:34px"><input type="checkbox" id="dv-selall"></th><th>Device ID</th><th>Hardware ID</th><th>Mode</th><th>Version</th><th>Bundles</th><th>Registered</th><th>Last seen</th><th></th></tr></thead><tbody>' +
      rows.map((d) =>
        '<tr class="clickable">' +
        '<td><input type="checkbox" class="dv-sel"' + (selected.has(d.deviceid) ? " checked" : "") + "></td>" +
        '<td class="mono-cell">' + SUAR.ui.esc(d.deviceid) + "</td>" +
        "<td>" + hardwareIdCell(d, hwCounts) + "</td>" +
        "<td>" + modeChip(d.applicationmode) + "</td>" +
        '<td class="mono-cell">' + SUAR.ui.esc(d.applicationversion || "—") + "</td>" +
        '<td class="mono-cell">' + (d.bundleCount ?? 0) + "</td>" +
        '<td class="muted">' + SUAR.ui.fmtRelative(d.registeredat) + "</td>" +
        "<td>" + lastSeenCell(d.lastseenat) + "</td>" +
        '<td class="cell-actions">' +
          '<button class="btn btn--danger btn--sm" data-del>Delete</button>' +
        "</td></tr>"
      ).join("") + "</tbody></table>";

    rows.forEach((d, i) => {
      const tr = wrap.querySelectorAll("tbody tr")[i];
      tr.addEventListener("click", () => openDetail(d));
      tr.querySelector(".dv-sel").addEventListener("click", (e) => e.stopPropagation());
      tr.querySelector(".dv-sel").addEventListener("change", (e) => { e.target.checked ? selected.add(d.deviceid) : selected.delete(d.deviceid); updateBulkBar(); syncSelAll(); });
      tr.querySelector("[data-del]").addEventListener("click", (e) => { e.stopPropagation(); del(d); });
    });
    const selall = wrap.querySelector("#dv-selall");
    selall.addEventListener("change", (e) => {
      rows.forEach((d) => e.target.checked ? selected.add(d.deviceid) : selected.delete(d.deviceid));
      updateBulkBar(); renderTable();
    });
    syncSelAll();
  }

  function former(k, v) { return "<dt>" + k + "</dt><dd>" + v + "</dd>"; }

  async function openDetail(d) {
    if (_detailOpen) return;
    _detailOpen = true;
    let bundles;
    try {
      bundles = await SUAR.api.get("/admin/bundles?device=" + encodeURIComponent(d.deviceid));
    } catch (e) {
      SUAR.ui.toast(e.message, "err");
      return;
    } finally {
      _detailOpen = false;
    }
    const tc = d.tierCounts || {};
    const tierBadges = ["Critical", "High", "Moderate", "Low"].filter((t) => tc[t])
      .map((t) => SUAR.ui.tierBadge(t) + " &times;" + tc[t]).join("  ");

    const kv = [
      former("Device ID", '<span class="mono">' + SUAR.ui.esc(d.deviceid) + "</span>"),
      former("Hardware ID", hardwareIdCell(d, hardwareIdCounts(allRows))),
      former("Mode", modeChip(d.applicationmode)),
      former("App version", '<span class="mono">' + SUAR.ui.esc(d.applicationversion || "—") + "</span>"),
      former("Registered", SUAR.ui.fmtDate(d.registeredat)),
      former("Last seen", SUAR.ui.fmtDate(d.lastseenat)),
      former("Bundles", (d.bundleCount ?? 0) + (tierBadges ? " &nbsp; " + tierBadges : "")),
    ].join("");

    const bundleRows = bundles.map((b) =>
      "<tr>" +
      "<td>" + SUAR.ui.tierBadge(b.prioritytier) + "</td>" +
      '<td class="mono-cell">' + (b.priorityscore != null ? b.priorityscore.toFixed(3) : "—") + "</td>" +
      '<td class="id-trunc">' + SUAR.ui.truncId(b.bundleid, 14) + "</td>" +
      '<td class="muted">' + SUAR.ui.fmtRelative(b.createdat) + "</td>" +
      "</tr>"
    ).join("");

    const body =
      '<dl class="kv">' + kv + "</dl>" +
      '<div class="section-title">Bundles (' + bundles.length + ")</div>" +
      (bundles.length
        ? '<table class="data"><thead><tr><th>Tier</th><th>Score</th><th>Bundle ID</th><th>Created</th></tr></thead><tbody>' + bundleRows + "</tbody></table>"
        : '<p class="muted" style="font-size:13px">No bundles yet.</p>');

    SUAR.ui.drawer({
      title: "Device " + SUAR.ui.truncId(d.deviceid, 14),
      body,
      actions: [
        { label: "Delete", className: "btn--danger", onClick: async (close) => {
            const ok = await SUAR.ui.confirm({ title: "Delete device?", message: "Also deletes " + (d.bundleCount ?? 0) + " bundle(s). Cannot be undone.", confirmLabel: "Delete", danger: true });
            if (!ok) return;
            try { await SUAR.api.del("/admin/devices/" + encodeURIComponent(d.deviceid)); SUAR.ui.toast("Deleted", "ok"); close(); load(); SUAR.app.refreshCounts(); }
            catch (e) { SUAR.ui.toast(e.message, "err"); }
          } },
      ],
    });
  }

  function modeChip(m) {
    if (m === "helper") return '<span class="chip chip--on">helper</span>';
    if (m === "victim") return '<span class="chip chip--victim">victim</span>';
    return '<span class="chip">' + SUAR.ui.esc(m || "—") + "</span>";
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
