/* Distress bundles: filterable table → detail drawer (readings, relay logs,
 * sync status) with edit + delete. */
window.SUAR = window.SUAR || {};
SUAR.views = SUAR.views || {};

SUAR.views.bundles = (function () {
  const TIERS = ["Critical", "High", "Moderate", "Low", "None"];
  let filters = { tier: "" };
  let search = "", sortKey = "created";
  let page = 1, pageSize = 50;
  let allRows = [];
  let _pageRows = [];
  const selected = new Set();

  function query() {
    const p = [];
    if (filters.tier) p.push("tier=" + encodeURIComponent(filters.tier));
    return p.length ? "?" + p.join("&") : "";
  }

  async function render(container) {
    container.innerHTML =
      '<div class="list-toolbar">' +
        '<select class="select" id="f-tier"><option value="">All tiers</option>' +
          TIERS.map((t) => '<option' + (filters.tier === t ? " selected" : "") + ">" + t + "</option>").join("") + "</select>" +
        '<input class="input input--search" id="b-search" placeholder="Search device ID, bundle ID or location…" value="' + SUAR.ui.esc(search) + '">' +
        '<select class="select" id="b-sort" style="max-width:175px">' +
          [["created", "Newest first"], ["updated", "Recently updated"], ["score", "Score high–low"], ["tier", "Tier"]]
            .map((o) => '<option value="' + o[0] + '"' + (sortKey === o[0] ? " selected" : "") + ">" + o[1] + "</option>").join("") +
        "</select>" +
        '<span class="spacer"></span>' +
        '<div class="bulkbar" id="b-bulk" style="display:none"><span class="muted" id="b-selcount"></span><button class="btn btn--danger btn--sm" data-bulk="del">Delete</button></div>' +
        '<button class="btn btn--ghost btn--sm" id="f-refresh">Refresh</button>' +
      "</div>" +
      '<div class="card"><div class="table-wrap" id="b-table">' + SUAR.ui.spinner() + "</div></div>";

    document.getElementById("f-tier").addEventListener("change", (e) => { filters.tier = e.target.value; page = 1; load(); });
    document.getElementById("b-search").addEventListener("input", (e) => { search = e.target.value; page = 1; renderTable(); });
    document.getElementById("b-sort").addEventListener("change", (e) => { sortKey = e.target.value; renderTable(); });
    document.getElementById("f-refresh").addEventListener("click", load);
    document.querySelectorAll("[data-bulk]").forEach((b) => b.addEventListener("click", () => bulkDelete()));
    await load();
  }

  async function load() {
    const wrap = document.getElementById("b-table");
    wrap.innerHTML = SUAR.ui.spinner();
    allRows = await SUAR.api.get("/admin/bundles" + query());
    selected.clear(); updateBulkBar();
    renderTable();
  }

  function updateBulkBar() {
    const bar = document.getElementById("b-bulk");
    if (!bar) return;
    bar.style.display = selected.size ? "flex" : "none";
    const c = document.getElementById("b-selcount");
    if (c) c.textContent = selected.size + " selected";
  }

  function syncSelAll() {
    const el = document.getElementById("b-selall");
    if (!el) return;
    el.checked = _pageRows.length > 0 && _pageRows.every((b) => selected.has(b.distress_bundle_id));
  }

  async function bulkDelete() {
    if (!selected.size) return;
    const ids = [...selected];
    const ok = await SUAR.ui.confirm({ title: "Delete " + ids.length + " bundle(s)?", message: "Also removes their sensor readings, relay logs and sync records. Cannot be undone.", confirmLabel: "Delete", danger: true });
    if (!ok) return;
    try {
      for (const id of ids) await SUAR.api.del("/admin/bundles/" + encodeURIComponent(id));
      SUAR.ui.toast("Deleted (" + ids.length + ")", "ok"); selected.clear(); load(); SUAR.app.refreshCounts();
    } catch (e) { SUAR.ui.toast(e.message, "err"); load(); }
  }

  function visibleRows() {
    let rows = allRows.slice();
    const q = search.trim().toLowerCase();
    // Location is matched against the same "lat, lng" string the table shows,
    // so typing a prefix like "3.13" or a pasted coordinate pair both hit.
    if (q) rows = rows.filter((b) =>
      (b.device_id || "").toLowerCase().includes(q) ||
      (b.distress_bundle_id || "").toLowerCase().includes(q) ||
      SUAR.ui.fmtCoord(b.estimated_lat, b.estimated_lng).toLowerCase().includes(q));
    rows.sort((a, b) => {
      if (sortKey === "updated") return new Date(b.updated_at || 0) - new Date(a.updated_at || 0);
      if (sortKey === "score") return (b.priority_score ?? -1) - (a.priority_score ?? -1);
      if (sortKey === "tier") return TIERS.indexOf(a.priority_tier) - TIERS.indexOf(b.priority_tier);
      return new Date(b.created_at || 0) - new Date(a.created_at || 0);
    });
    return rows;
  }

  function renderTable() {
    const wrap = document.getElementById("b-table");
    if (!wrap) return;
    const all = visibleRows();
    if (!all.length) { wrap.innerHTML = SUAR.ui.empty(search ? "No matches" : "No bundles match", search ? "Try a different search." : "Adjust the filters or wait for a sync."); return; }
    const total = all.length;
    page = SUAR.ui.pageClamp(page, total, pageSize);
    _pageRows = all.slice((page - 1) * pageSize, page * pageSize);
    wrap.innerHTML =
      '<table class="data"><thead><tr><th style="width:34px"><input type="checkbox" id="b-selall"></th><th>Tier</th><th>Score</th><th>Device ID</th><th>Hops</th><th>Location</th><th>Activity</th><th>Created</th></tr></thead><tbody>' +
      _pageRows.map((b) =>
        '<tr class="clickable row-accent" data-id="' + SUAR.ui.esc(b.distress_bundle_id) + '" style="border-left-color:' + tierColor(b.priority_tier) + '">' +
        '<td><input type="checkbox" class="b-sel"' + (selected.has(b.distress_bundle_id) ? " checked" : "") + "></td>" +
        "<td>" + SUAR.ui.tierBadge(b.priority_tier) + "</td>" +
        '<td class="mono-cell">' + (b.priority_score != null ? b.priority_score.toFixed(3) : "—") + "</td>" +
        '<td class="id-trunc">' + SUAR.ui.copyable(b.device_id, SUAR.ui.truncId(b.device_id, 12)) + "</td>" +
        '<td class="mono-cell">' + (b.hop_count ?? 0) + "</td>" +
        '<td class="mono-cell">' + (b.estimated_lat != null && b.estimated_lng != null ? SUAR.ui.copyable(SUAR.ui.fmtCoord(b.estimated_lat, b.estimated_lng)) : SUAR.ui.fmtCoord(b.estimated_lat, b.estimated_lng)) + "</td>" +
        "<td>" + activityChip(b.updated_at) + "</td>" +
        '<td class="muted">' + SUAR.ui.fmtRelative(b.created_at) + "</td>" +
        "</tr>"
      ).join("") + "</tbody></table>" +
      SUAR.ui.pagerControls(total, page, pageSize);

    wrap.querySelectorAll("tr[data-id]").forEach((tr) => {
      tr.addEventListener("click", () => openDetail(tr.dataset.id));
      const sel = tr.querySelector(".b-sel");
      sel.addEventListener("click", (e) => e.stopPropagation());
      sel.addEventListener("change", (e) => {
        e.target.checked ? selected.add(tr.dataset.id) : selected.delete(tr.dataset.id);
        updateBulkBar(); syncSelAll();
      });
    });
    const selall = wrap.querySelector("#b-selall");
    selall.addEventListener("click", (e) => e.stopPropagation());
    selall.addEventListener("change", (e) => {
      _pageRows.forEach((b) => e.target.checked ? selected.add(b.distress_bundle_id) : selected.delete(b.distress_bundle_id));
      updateBulkBar(); renderTable();
    });
    SUAR.ui.bindPager(wrap, total, page, pageSize, (p, s) => { page = p; pageSize = s; renderTable(); });
    syncSelAll();
  }

  function tierColor(t) {
    return { Critical: "#d64545", High: "#ec7a1c", Moderate: "#e0a500", Low: "#3fb836" }[t] || "#cbd2db";
  }

  // Same distress event keeps upserting one bundle row as it goes — a row
  // updated in the last 24h is still an ongoing situation; older means
  // nothing new has come in (device gone quiet, situation likely resolved).
  const ACTIVE_WINDOW_MS = 24 * 60 * 60 * 1000;
  function isActive(updatedAt) {
    const t = updatedAt ? new Date(updatedAt).getTime() : NaN;
    return !isNaN(t) && (Date.now() - t) < ACTIVE_WINDOW_MS;
  }
  function activityChip(updatedAt) {
    return isActive(updatedAt)
      ? '<span class="chip chip--on">active</span>'
      : '<span class="chip chip--off">inactive</span>';
  }

  async function openDetail(id) {
    let d;
    try {
      d = await SUAR.api.get("/admin/bundles/" + encodeURIComponent(id));
    } catch (e) {
      SUAR.ui.toast(e.message, "err");
      return;
    }
    const b = d.bundle;
    const readings = d.sensorReadings || [];
    const relays = d.relayLogs || [];

    const locStr = SUAR.ui.fmtCoord(b.estimated_lat, b.estimated_lng);
    const kv = [
      former("Bundle ID", '<span class="mono">' + SUAR.ui.copyable(b.distress_bundle_id) + "</span>"),
      former("Device ID", '<span class="mono">' + SUAR.ui.copyable(b.device_id) + "</span>"),
      former("Tier", SUAR.ui.tierBadge(b.priority_tier)),
      former("Score", '<span class="mono">' + (b.priority_score != null ? b.priority_score.toFixed(4) : "—") + "</span>"),
      former("Location", '<span class="mono">' + (b.estimated_lat != null && b.estimated_lng != null ? SUAR.ui.copyable(locStr) : locStr) + "</span>"),
      former("Accuracy", b.accuracy_meters != null ? '<span class="mono">±' + Math.round(b.accuracy_meters) + " m</span>" : "—"),
      former("Hops", '<span class="mono">' + (b.hop_count ?? 0) + "</span>"),
      former("Activity", activityChip(b.updated_at)),
      former("Created", SUAR.ui.fmtDate(b.created_at)),
    ].join("");

    const readingsRows = readings
      .map((r) =>
        `<tr><td>${SUAR.ui.esc(r.sensor_type)}</td><td class="mono-cell">${fmtNum(r.raw_value)}</td>` +
        `<td class="mono-cell">${fmtNum(r.normalised_value)}</td><td class="muted">${SUAR.ui.fmtDate(r.recorded_at)}</td></tr>`)
      .join("");
    const relaysRows = relays
      .map((r) =>
        `<tr><td class="mono-cell">${r.hop_sequence ?? "-"}</td><td class="id-trunc">${SUAR.ui.truncId(r.device_id, 10)}</td>` +
        `<td class="id-trunc">${SUAR.ui.truncId(r.next_hop_device_id, 10)}</td><td>${SUAR.ui.esc(r.protocol)}</td></tr>`)
      .join("");

    const noneRow = `<p class="muted" style="font-size:13px">None.</p>`;
    const body =
      `<dl class="kv">${kv}</dl>` +
      `<div class="section-title">Sensor readings (${readings.length})</div>` +
      (readings.length
        ? `<table class="data"><thead><tr><th>Sensor</th><th>Raw</th><th>Norm.</th><th>Recorded</th></tr></thead><tbody>${readingsRows}</tbody></table>`
        : noneRow) +
      `<div class="section-title">Relay path (${relays.length})</div>` +
      (relays.length
        ? `<table class="data"><thead><tr><th>#</th><th>Device</th><th>Next hop</th><th>Protocol</th></tr></thead><tbody>${relaysRows}</tbody></table>`
        : noneRow);

    const dr = SUAR.ui.drawer({
      title: "Bundle " + SUAR.ui.truncId(b.distress_bundle_id, 8),
      body,
      actions: [
        { label: "Delete", className: "btn--danger", onClick: async (close) => {
            const ok = await SUAR.ui.confirm({ title: "Delete bundle?", message: "This also removes its sensor readings, relay logs and sync record. Cannot be undone.", confirmLabel: "Delete", danger: true });
            if (!ok) return;
            await SUAR.api.del("/admin/bundles/" + encodeURIComponent(b.distress_bundle_id));
            SUAR.ui.toast("Bundle deleted", "ok"); close(); load(); SUAR.app.refreshCounts();
          } },
        { label: "Edit", className: "btn--primary", onClick: (close) => { close(); openEdit(b); } },
      ],
    });
    return dr;
  }

  function openEdit(b) {
    SUAR.ui.modal({
      title: "Edit bundle",
      body:
        '<div class="form-row">' +
          '<div class="field"><label>Tier</label><select class="select" id="e-tier">' +
            TIERS.map((t) => '<option' + (b.priority_tier === t ? " selected" : "") + ">" + t + "</option>").join("") + "</select></div>" +
          '<div class="field"><label>Score (0–1)</label><input class="input" id="e-score" type="number" step="0.001" min="0" max="1" value="' + (b.priority_score ?? "") + '"></div>' +
        "</div>" +
        '<div class="form-row">' +
          '<div class="field"><label>Latitude</label><input class="input" id="e-lat" type="number" step="any" min="-90" max="90" value="' + (b.estimated_lat ?? "") + '"></div>' +
          '<div class="field"><label>Longitude</label><input class="input" id="e-lng" type="number" step="any" min="-180" max="180" value="' + (b.estimated_lng ?? "") + '"></div>' +
        "</div>",
      actions: [
        { label: "Cancel", className: "btn--ghost", onClick: (c) => c() },
        { label: "Save", className: "btn--primary", onClick: async (close, btn) => {
            const score = parseFloat(document.getElementById("e-score").value);
            if (isNaN(score) || score < 0 || score > 1) { SUAR.ui.toast("Score must be between 0 and 1", "err"); return; }
            const latRaw = document.getElementById("e-lat").value.trim();
            const lngRaw = document.getElementById("e-lng").value.trim();
            const lat = numOrNull(latRaw);
            const lng = numOrNull(lngRaw);
            // Non-empty-but-unparseable would otherwise fall through as null and
            // silently WIPE the bundle's location instead of reporting a typo.
            if (latRaw !== "" && lat === null) { SUAR.ui.toast("Latitude must be a number", "err"); return; }
            if (lngRaw !== "" && lng === null) { SUAR.ui.toast("Longitude must be a number", "err"); return; }
            if (lat !== null && Math.abs(lat) > 90) { SUAR.ui.toast("Latitude must be between -90 and 90", "err"); return; }
            if (lng !== null && Math.abs(lng) > 180) { SUAR.ui.toast("Longitude must be between -180 and 180", "err"); return; }
            // A half-set coordinate maps to nowhere — require both or neither.
            if ((lat === null) !== (lng === null)) { SUAR.ui.toast("Set both latitude and longitude, or clear both", "err"); return; }
            const patch = {
              priority_tier: document.getElementById("e-tier").value,
              priority_score: score,
              estimated_lat: lat,
              estimated_lng: lng,
            };
            btn.disabled = true;
            try {
              await SUAR.api.patch("/admin/bundles/" + encodeURIComponent(b.distress_bundle_id), patch);
              SUAR.ui.toast("Bundle updated", "ok"); close(); load();
            } catch (e) { SUAR.ui.toast(e.message, "err"); btn.disabled = false; }
          } },
      ],
    });
  }

  // small helpers
  function former(k, v) { return "<dt>" + k + "</dt><dd>" + v + "</dd>"; }
  function fmtNum(n) { return n == null ? "—" : (Math.abs(n) >= 1000 || Number.isInteger(n) ? n : n.toFixed(3)); }
  function numOrNull(v) { const n = parseFloat(v); return isNaN(n) ? null : n; }

  return { render };
})();
