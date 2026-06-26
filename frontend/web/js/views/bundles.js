/* Distress bundles: filterable table → detail drawer (readings, relay logs,
 * sync status) with edit + delete. */
window.SUAR = window.SUAR || {};
SUAR.views = SUAR.views || {};

SUAR.views.bundles = (function () {
  const TIERS = ["Critical", "High", "Moderate", "Low", "None"];
  let filters = { tier: "" };
  let search = "", sortKey = "created";
  let allRows = [];
  const selected = new Set();

  function query() {
    const p = [];
    if (filters.tier) p.push("tier=" + encodeURIComponent(filters.tier));
    return p.length ? "?" + p.join("&") : "";
  }

  async function render(container) {
    container.innerHTML =
      '<div class="toolbar">' +
        '<select class="select" id="f-tier"><option value="">All tiers</option>' +
          TIERS.map((t) => '<option' + (filters.tier === t ? " selected" : "") + ">" + t + "</option>").join("") + "</select>" +
        '<input class="input" id="b-search" placeholder="Search device or bundle ID…" value="' + SUAR.ui.esc(search) + '" style="max-width:240px">' +
        '<select class="select" id="b-sort" style="max-width:175px">' +
          [["created", "Newest first"], ["updated", "Recently updated"], ["score", "Score high–low"], ["tier", "Tier"]]
            .map((o) => '<option value="' + o[0] + '"' + (sortKey === o[0] ? " selected" : "") + ">" + o[1] + "</option>").join("") +
        "</select>" +
        '<div class="bulkbar" id="b-bulk" style="display:none"><span class="muted" id="b-selcount"></span><button class="btn btn--danger btn--sm" data-bulk="del">Delete</button></div>' +
        '<span style="flex:1"></span>' +
        '<button class="btn btn--ghost btn--sm" id="f-refresh">Refresh</button>' +
      "</div>" +
      '<div class="card"><div class="table-wrap" id="b-table">' + SUAR.ui.spinner() + "</div></div>";

    document.getElementById("f-tier").addEventListener("change", (e) => { filters.tier = e.target.value; load(); });
    document.getElementById("b-search").addEventListener("input", (e) => { search = e.target.value; renderTable(); });
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
    const rows = visibleRows();
    el.checked = rows.length > 0 && rows.every((b) => selected.has(b.bundleid));
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
    if (q) rows = rows.filter((b) => (b.deviceid || "").toLowerCase().includes(q) || (b.bundleid || "").toLowerCase().includes(q));
    rows.sort((a, b) => {
      if (sortKey === "updated") return new Date(b.updatedat || 0) - new Date(a.updatedat || 0);
      if (sortKey === "score") return (b.priorityscore ?? -1) - (a.priorityscore ?? -1);
      if (sortKey === "tier") return TIERS.indexOf(a.prioritytier) - TIERS.indexOf(b.prioritytier);
      return new Date(b.createdat || 0) - new Date(a.createdat || 0);
    });
    return rows;
  }

  function renderTable() {
    const wrap = document.getElementById("b-table");
    if (!wrap) return;
    const rows = visibleRows();
    if (!rows.length) { wrap.innerHTML = SUAR.ui.empty(search ? "No matches" : "No bundles match", search ? "Try a different search." : "Adjust the filters or wait for a sync."); return; }
    wrap.innerHTML =
      '<table class="data"><thead><tr><th style="width:34px"><input type="checkbox" id="b-selall"></th><th>Tier</th><th>Score</th><th>Device</th><th>Hops</th><th>Location</th><th>Activity</th><th>Created</th><th></th></tr></thead><tbody>' +
      rows.map((b) =>
        '<tr class="clickable row-accent" data-id="' + SUAR.ui.esc(b.bundleid) + '" style="border-left-color:' + tierColor(b.prioritytier) + '">' +
        '<td><input type="checkbox" class="b-sel"' + (selected.has(b.bundleid) ? " checked" : "") + "></td>" +
        "<td>" + SUAR.ui.tierBadge(b.prioritytier) + "</td>" +
        '<td class="mono-cell">' + (b.priorityscore != null ? b.priorityscore.toFixed(3) : "—") + "</td>" +
        '<td class="id-trunc">' + SUAR.ui.truncId(b.deviceid, 12) + "</td>" +
        '<td class="mono-cell">' + (b.hopcount ?? 0) + "</td>" +
        '<td class="mono-cell">' + SUAR.ui.fmtCoord(b.estimatedlat, b.estimatedlng) + "</td>" +
        "<td>" + activityChip(b.updatedat) + "</td>" +
        '<td class="muted">' + SUAR.ui.fmtRelative(b.createdat) + "</td>" +
        '<td class="cell-actions"><button class="btn btn--ghost btn--sm" data-view>View</button></td></tr>'
      ).join("") + "</tbody></table>";

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
      rows.forEach((b) => e.target.checked ? selected.add(b.bundleid) : selected.delete(b.bundleid));
      updateBulkBar(); renderTable();
    });
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
    const d = await SUAR.api.get("/admin/bundles/" + encodeURIComponent(id));
    const b = d.bundle;
    const readings = d.sensorReadings || [];
    const relays = d.relayLogs || [];

    const kv = [
      former("Bundle ID", '<span class="mono">' + SUAR.ui.esc(b.bundleid) + "</span>"),
      former("Device", '<span class="mono">' + SUAR.ui.esc(b.deviceid) + "</span>"),
      former("Tier", SUAR.ui.tierBadge(b.prioritytier)),
      former("Score", '<span class="mono">' + (b.priorityscore != null ? b.priorityscore.toFixed(4) : "—") + "</span>"),
      former("Location", '<span class="mono">' + SUAR.ui.fmtCoord(b.estimatedlat, b.estimatedlng) + "</span>"),
      former("Accuracy", b.accuracymeters != null ? '<span class="mono">±' + Math.round(b.accuracymeters) + " m</span>" : "—"),
      former("Hops", '<span class="mono">' + (b.hopcount ?? 0) + "</span>"),
      former("Activity", activityChip(b.updatedat)),
      former("Created", SUAR.ui.fmtDate(b.createdat)),
    ].join("");

    const readingsRows = readings
      .map((r) =>
        `<tr><td>${SUAR.ui.esc(r.sensortype)}</td><td class="mono-cell">${fmtNum(r.rawvalue)}</td>` +
        `<td class="mono-cell">${fmtNum(r.normalisedvalue)}</td><td class="muted">${SUAR.ui.fmtDate(r.recordedat)}</td></tr>`)
      .join("");
    const relaysRows = relays
      .map((r) =>
        `<tr><td class="mono-cell">${r.hopsequence ?? "-"}</td><td class="id-trunc">${SUAR.ui.truncId(r.deviceid, 10)}</td>` +
        `<td class="id-trunc">${SUAR.ui.truncId(r.nexthopdeviceid, 10)}</td><td>${SUAR.ui.esc(r.protocol)}</td></tr>`)
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
      title: "Bundle " + SUAR.ui.truncId(b.bundleid, 8),
      body,
      actions: [
        { label: "Delete", className: "btn--danger", onClick: async (close) => {
            const ok = await SUAR.ui.confirm({ title: "Delete bundle?", message: "This also removes its sensor readings, relay logs and sync record. Cannot be undone.", confirmLabel: "Delete", danger: true });
            if (!ok) return;
            await SUAR.api.del("/admin/bundles/" + encodeURIComponent(b.bundleid));
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
            TIERS.map((t) => '<option' + (b.prioritytier === t ? " selected" : "") + ">" + t + "</option>").join("") + "</select></div>" +
          '<div class="field"><label>Score (0–1)</label><input class="input" id="e-score" type="number" step="0.001" min="0" max="1" value="' + (b.priorityscore ?? "") + '"></div>' +
        "</div>" +
        '<div class="form-row">' +
          '<div class="field"><label>Latitude</label><input class="input" id="e-lat" type="number" step="any" value="' + (b.estimatedlat ?? "") + '"></div>' +
          '<div class="field"><label>Longitude</label><input class="input" id="e-lng" type="number" step="any" value="' + (b.estimatedlng ?? "") + '"></div>' +
        "</div>",
      actions: [
        { label: "Cancel", className: "btn--ghost", onClick: (c) => c() },
        { label: "Save", className: "btn--primary", onClick: async (close, btn) => {
            const patch = {
              prioritytier: document.getElementById("e-tier").value,
              priorityscore: parseFloat(document.getElementById("e-score").value),
              estimatedlat: numOrNull(document.getElementById("e-lat").value),
              estimatedlng: numOrNull(document.getElementById("e-lng").value),
            };
            btn.disabled = true;
            try {
              await SUAR.api.patch("/admin/bundles/" + encodeURIComponent(b.bundleid), patch);
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
