/* Devices: roster of every device that has registered or relayed, with bundle
 * counts, edit (mode/version) and delete (cascades that device's bundles). */
window.SUAR = window.SUAR || {};
SUAR.views = SUAR.views || {};

SUAR.views.devices = (function () {
  let search = "", sortKey = "lastseen", filterMode = "", filterVersion = "";
  let page = 1, pageSize = 50;
  let allRows = [];
  let _pageRows = [];
  let _detailOpen = false;
  const selected = new Set();

  async function render(container) {
    container.innerHTML =
      '<div class="list-toolbar">' +
        '<select class="select" id="dv-mode" style="max-width:140px"><option value="">All modes</option>' +
          ["helper", "victim"].map((m) => '<option value="' + m + '"' + (filterMode === m ? " selected" : "") + ">" + titleCase(m) + "</option>").join("") + "</select>" +
        '<select class="select" id="dv-version" style="max-width:150px"></select>' +
        '<input class="input input--search" id="dv-search" placeholder="Search device or hardware ID…" value="' + SUAR.ui.esc(search) + '">' +
        '<select class="select" id="dv-sort" style="max-width:175px">' +
          [["lastseen", "Last seen"], ["bundles", "Bundle count"], ["mode", "Mode"], ["version", "App version"]]
            .map((o) => '<option value="' + o[0] + '"' + (sortKey === o[0] ? " selected" : "") + ">" + o[1] + "</option>").join("") +
        "</select>" +
        '<span class="spacer"></span>' +
        '<div class="bulkbar" id="dv-bulk" style="display:none"><span class="muted" id="dv-selcount"></span><button class="btn btn--danger btn--sm" data-bulk="del">Delete</button></div>' +
      "</div>" +
      '<div class="card"><div class="table-wrap" id="d-table">' + SUAR.ui.spinner() + "</div></div>";
    document.getElementById("dv-mode").addEventListener("change", (e) => { filterMode = e.target.value; page = 1; renderTable(); });
    document.getElementById("dv-version").addEventListener("change", (e) => { filterVersion = e.target.value; page = 1; renderTable(); });
    document.getElementById("dv-search").addEventListener("input", (e) => { search = e.target.value; page = 1; renderTable(); });
    document.getElementById("dv-sort").addEventListener("change", (e) => { sortKey = e.target.value; renderTable(); });
    document.querySelectorAll("[data-bulk]").forEach((b) => b.addEventListener("click", () => bulkDelete()));
    await load();
  }

  // Rebuild the version dropdown from whatever versions exist in the data, so a
  // newly-seen app version shows up as a filter option automatically.
  function refreshVersionOptions() {
    const sel = document.getElementById("dv-version");
    if (!sel) return;
    const versions = [...new Set(allRows.map((d) => d.application_version).filter(Boolean))].sort();
    if (filterVersion && !versions.includes(filterVersion)) filterVersion = "";
    sel.innerHTML = '<option value="">All versions</option>' +
      versions.map((v) => '<option value="' + SUAR.ui.esc(v) + '"' + (filterVersion === v ? " selected" : "") + ">" + SUAR.ui.esc(v) + "</option>").join("");
  }

  async function load() {
    const wrap = document.getElementById("d-table");
    wrap.innerHTML = SUAR.ui.spinner();
    allRows = await SUAR.api.get("/admin/devices");
    selected.clear(); updateBulkBar();
    refreshVersionOptions();
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
    el.checked = _pageRows.length > 0 && _pageRows.every((d) => selected.has(d.device_id));
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
    if (filterMode) rows = rows.filter((d) => d.application_mode === filterMode);
    if (filterVersion) rows = rows.filter((d) => d.application_version === filterVersion);
    const q = search.trim().toLowerCase();
    if (q) rows = rows.filter((d) =>
      (d.device_id || "").toLowerCase().includes(q) ||
      (d.hardware_id || "").toLowerCase().includes(q));
    rows.sort((a, b) => {
      if (sortKey === "bundles") return (b.bundleCount ?? 0) - (a.bundleCount ?? 0);
      if (sortKey === "mode") return (a.application_mode || "").localeCompare(b.application_mode || "");
      if (sortKey === "version") return (a.application_version || "").localeCompare(b.application_version || "");
      return new Date(b.last_seen_at || 0) - new Date(a.last_seen_at || 0);
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
  // hardware_id (Settings.Secure.ANDROID_ID) survives that — count how many
  // rows share one, so a repeat can be flagged instead of silently miscounted
  // as separate devices.
  function hardwareIdCounts(rows) {
    const counts = {};
    rows.forEach((d) => { if (d.hardware_id) counts[d.hardware_id] = (counts[d.hardware_id] || 0) + 1; });
    return counts;
  }

  function hardwareIdCell(d, counts) {
    if (!d.hardware_id) return '<span class="muted">—</span>';
    const dup = counts[d.hardware_id] > 1;
    return '<span class="mono-cell">' + SUAR.ui.copyable(d.hardware_id, SUAR.ui.truncId(d.hardware_id, 12)) +
      (dup ? ' <span class="dup-ico" title="Same physical phone as another device ID">!</span>' : '') + '</span>';
  }

  function renderTable() {
    const wrap = document.getElementById("d-table");
    if (!wrap) return;
    const all = visibleRows();
    const filtering = search || filterMode || filterVersion;
    if (!all.length) { wrap.innerHTML = SUAR.ui.empty(filtering ? "No matches" : "No devices yet", filtering ? "Try a different search or filter." : "Devices register on their first sync."); return; }
    const total = all.length;
    page = SUAR.ui.pageClamp(page, total, pageSize);
    _pageRows = all.slice((page - 1) * pageSize, page * pageSize);
    const hwCounts = hardwareIdCounts(allRows);
    wrap.innerHTML =
      '<table class="data"><thead><tr><th style="width:34px"><input type="checkbox" id="dv-selall"></th><th>Device ID</th><th>Hardware ID</th><th>Mode</th><th>Version</th><th>Bundles</th><th>Registered</th><th>Last seen</th><th></th></tr></thead><tbody>' +
      _pageRows.map((d) =>
        '<tr class="clickable">' +
        '<td><input type="checkbox" class="dv-sel"' + (selected.has(d.device_id) ? " checked" : "") + "></td>" +
        '<td class="mono-cell">' + SUAR.ui.copyable(d.device_id) + "</td>" +
        "<td>" + hardwareIdCell(d, hwCounts) + "</td>" +
        "<td>" + modeChip(d.application_mode) + "</td>" +
        '<td class="mono-cell">' + SUAR.ui.esc(d.application_version || "—") + "</td>" +
        '<td class="mono-cell">' + (d.bundleCount ?? 0) + "</td>" +
        '<td class="muted">' + SUAR.ui.fmtRelative(d.registered_at) + "</td>" +
        "<td>" + lastSeenCell(d.last_seen_at) + "</td>" +
        '<td class="cell-actions">' +
          '<button class="btn btn--danger btn--sm" data-del>Delete</button>' +
        "</td></tr>"
      ).join("") + "</tbody></table>" +
      SUAR.ui.pagerControls(total, page, pageSize);

    _pageRows.forEach((d, i) => {
      const tr = wrap.querySelectorAll("tbody tr")[i];
      tr.addEventListener("click", () => openDetail(d));
      tr.querySelector(".dv-sel").addEventListener("click", (e) => e.stopPropagation());
      tr.querySelector(".dv-sel").addEventListener("change", (e) => { e.target.checked ? selected.add(d.device_id) : selected.delete(d.device_id); updateBulkBar(); syncSelAll(); });
      tr.querySelector("[data-del]").addEventListener("click", (e) => { e.stopPropagation(); del(d); });
    });
    const selall = wrap.querySelector("#dv-selall");
    selall.addEventListener("change", (e) => {
      _pageRows.forEach((d) => e.target.checked ? selected.add(d.device_id) : selected.delete(d.device_id));
      updateBulkBar(); renderTable();
    });
    SUAR.ui.bindPager(wrap, total, page, pageSize, (p, s) => { page = p; pageSize = s; renderTable(); });
    syncSelAll();
  }

  function former(k, v) { return "<dt>" + k + "</dt><dd>" + v + "</dd>"; }

  async function openDetail(d) {
    if (_detailOpen) return;
    _detailOpen = true;
    let bundles;
    try {
      bundles = await SUAR.api.get("/admin/bundles?device=" + encodeURIComponent(d.device_id));
    } catch (e) {
      SUAR.ui.toast(e.message, "err");
      return;
    } finally {
      _detailOpen = false;
    }
    const tc = d.tierCounts || {};
    const tierBadges = ["Critical", "High", "Moderate", "Low"].filter((t) => tc[t])
      .map((t) => SUAR.ui.tierBadge(t) + " &times;" + tc[t]).join("  ");

    const siblings = d.hardware_id
      ? allRows.filter((r) => r.hardware_id === d.hardware_id && r.device_id !== d.device_id)
      : [];

    const kv = [
      former("Device ID", '<span class="mono">' + SUAR.ui.copyable(d.device_id) + "</span>"),
      former("Hardware ID", hardwareIdCell(d, hardwareIdCounts(allRows))),
      former("Mode", modeChip(d.application_mode)),
      former("App version", '<span class="mono">' + SUAR.ui.esc(d.application_version || "—") + "</span>"),
      former("Registered", SUAR.ui.fmtDate(d.registered_at)),
      former("Last seen", SUAR.ui.fmtDate(d.last_seen_at)),
      former("Bundles", (d.bundleCount ?? 0) + (tierBadges ? " &nbsp; " + tierBadges : "")),
    ].join("");

    const bundleRows = bundles.map((b) =>
      "<tr>" +
      "<td>" + SUAR.ui.tierBadge(b.priority_tier) + "</td>" +
      '<td class="mono-cell">' + (b.priority_score != null ? b.priority_score.toFixed(3) : "—") + "</td>" +
      '<td class="id-trunc">' + SUAR.ui.truncId(b.distress_bundle_id, 14) + "</td>" +
      '<td class="muted">' + SUAR.ui.fmtRelative(b.created_at) + "</td>" +
      "</tr>"
    ).join("");

    const aliasSection = siblings.length
      ? '<div class="section-title">Same phone (' + siblings.length + " other ID" + (siblings.length > 1 ? "s" : "") + ")</div>" +
        '<p class="muted" style="font-size:12px;margin:0 0 8px">This phone re-registered under these device IDs (app reinstall or data clear). Click one to view it.</p>' +
        '<table class="data"><thead><tr><th>Device ID</th><th>Mode</th><th>Last seen</th></tr></thead><tbody>' +
        siblings.map((s) =>
          '<tr class="clickable" data-alias="' + SUAR.ui.esc(s.device_id) + '">' +
          '<td class="mono-cell">' + SUAR.ui.esc(s.device_id) + "</td>" +
          "<td>" + modeChip(s.application_mode) + "</td>" +
          '<td class="muted">' + SUAR.ui.fmtRelative(s.last_seen_at) + "</td></tr>"
        ).join("") + "</tbody></table>"
      : "";

    const body =
      '<dl class="kv">' + kv + "</dl>" +
      aliasSection +
      '<div class="section-title">Bundles (' + bundles.length + ")</div>" +
      (bundles.length
        ? '<table class="data"><thead><tr><th>Tier</th><th>Score</th><th>Bundle ID</th><th>Created</th></tr></thead><tbody>' + bundleRows + "</tbody></table>"
        : '<p class="muted" style="font-size:13px">No bundles yet.</p>');

    const dw = SUAR.ui.drawer({
      title: "Device " + SUAR.ui.truncId(d.device_id, 14),
      body,
      actions: [
        { label: "Delete", className: "btn--danger", onClick: async (close) => {
            const ok = await SUAR.ui.confirm({ title: "Delete device?", message: "Also deletes " + (d.bundleCount ?? 0) + " bundle(s). Cannot be undone.", confirmLabel: "Delete", danger: true });
            if (!ok) return;
            try { await SUAR.api.del("/admin/devices/" + encodeURIComponent(d.device_id)); SUAR.ui.toast("Deleted", "ok"); close(); load(); SUAR.app.refreshCounts(); }
            catch (e) { SUAR.ui.toast(e.message, "err"); }
          } },
      ],
    });
    dw.body.querySelectorAll("[data-alias]").forEach((tr) =>
      tr.addEventListener("click", () => {
        const sib = allRows.find((r) => r.device_id === tr.getAttribute("data-alias"));
        if (sib) { dw.close(); openDetail(sib); }
      }));
  }

  // Display-only capitalisation — the stored/queried value stays lowercase to
  // match the device.application_mode CHECK constraint.
  function titleCase(s) { return s ? s.charAt(0).toUpperCase() + s.slice(1) : ""; }

  function modeChip(m) {
    if (m === "helper") return '<span class="chip chip--on">Helper</span>';
    if (m === "victim") return '<span class="chip chip--victim">Victim</span>';
    return '<span class="chip">' + SUAR.ui.esc(titleCase(m) || "—") + "</span>";
  }

  async function del(d) {
    const ok = await SUAR.ui.confirm({
      title: "Delete device?",
      message: "Deleting " + SUAR.ui.truncId(d.device_id, 12) + " also deletes its " + (d.bundleCount ?? 0) + " bundle(s) and their data. Cannot be undone.",
      confirmLabel: "Delete", danger: true,
    });
    if (!ok) return;
    try {
      await SUAR.api.del("/admin/devices/" + encodeURIComponent(d.device_id));
      SUAR.ui.toast("Device deleted", "ok"); load(); SUAR.app.refreshCounts();
    } catch (e) { SUAR.ui.toast(e.message, "err"); }
  }

  return { render };
})();
