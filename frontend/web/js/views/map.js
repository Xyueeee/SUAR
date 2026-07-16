/* Map & Danger Zones: OpenStreetMap (same tiles as the mobile app) with
 * tier-coloured victim markers + accuracy radius, plus admin-drawn hazard
 * geofences (polygon / rectangle / circle) stored via the backend.
 *
 * ponytail: geometry of an existing zone is edited by delete + redraw, not an
 * in-place vertex editor. Add leaflet-draw's edit toolbar if that becomes a
 * real need. */
window.SUAR = window.SUAR || {};
SUAR.views = SUAR.views || {};

SUAR.views.map = (function () {
  const TIER_COLORS = { Critical: "#d64545", High: "#ec7a1c", Moderate: "#e0a500", Low: "#3fb836", None: "#9aa4b2" };
  const SEV_COLORS = { info: "#3e6fa8", warning: "#ec7a1c", danger: "#d64545" };
  const HAZARDS = ["flood", "fire", "landslide", "collapse", "other"];

  let map = null;
  let zonesLayer = null;
  let victimsLayer = null;
  let allZones = [], zSearch = "", zSev = "", zActive = "";
  let zPage = 1, zPageSize = 50, _zPageRows = [];

  async function render(container) {
    if (map) { map.remove(); map = null; }
    container.innerHTML =
      '<div class="card" style="margin-bottom:16px"><div class="card__body" style="padding:12px">' +
        '<div class="map" id="zone-map"></div>' +
        '<p class="muted" style="font-size:12.5px;margin:10px 4px 0">Use the draw tools (top-left) to add a hazard zone — polygon, rectangle or circle. Victim markers are coloured by triage tier; the faint ring is GPS accuracy.</p>' +
      "</div></div>" +
      '<div class="card"><div class="card__head"><h3>Hazard zones</h3><span class="spacer"></span><span class="eyebrow" id="zone-count"></span></div>' +
        '<div class="card__body" style="padding-bottom:0">' +
          '<div class="list-toolbar">' +
            '<select class="select" id="z-sev" style="max-width:150px"><option value="">All severities</option>' +
              ["info", "warning", "danger"].map((s) => '<option value="' + s + '"' + (zSev === s ? " selected" : "") + ">" + s + "</option>").join("") + "</select>" +
            '<select class="select" id="z-active" style="max-width:140px"><option value="">All</option><option value="active"' + (zActive === "active" ? " selected" : "") + ">Active</option><option value=\"inactive\"" + (zActive === "inactive" ? " selected" : "") + ">Inactive</option></select>" +
            '<input class="input input--search" id="z-search" placeholder="Search name or hazard…" value="' + SUAR.ui.esc(zSearch) + '">' +
          "</div></div>" +
        '<div class="table-wrap" id="zone-list">' + SUAR.ui.spinner() + "</div></div>";

    // minZoom/maxZoom bound the camera: without minZoom the user can pinch out
    // to whole-globe (z0); maxZoom caps at OSM's deepest real tile (z19).
    map = L.map("zone-map", { minZoom: 3, maxZoom: 19 });
    L.tileLayer("https://tile.openstreetmap.org/{z}/{x}/{y}.png", {
      maxZoom: 19, attribution: "&copy; OpenStreetMap",
    }).addTo(map);
    map.setView([3.139, 101.6869], 11);

    zonesLayer = L.featureGroup().addTo(map);
    victimsLayer = L.featureGroup().addTo(map);

    // Draw controls (create only).
    const drawn = new L.FeatureGroup().addTo(map);
    const drawControl = new L.Control.Draw({
      draw: { marker: false, polyline: false, circlemarker: false,
              polygon: { shapeOptions: { color: SEV_COLORS.danger } },
              rectangle: { shapeOptions: { color: SEV_COLORS.danger } },
              circle: { shapeOptions: { color: SEV_COLORS.danger } } },
      edit: false,
    });
    map.addControl(drawControl);
    map.on(L.Draw.Event.CREATED, (e) => onDrawn(e.layer, drawn));

    document.getElementById("z-sev").addEventListener("change", (e) => { zSev = e.target.value; zPage = 1; renderList(); });
    document.getElementById("z-active").addEventListener("change", (e) => { zActive = e.target.value; zPage = 1; renderList(); });
    document.getElementById("z-search").addEventListener("input", (e) => { zSearch = e.target.value; zPage = 1; renderList(); });

    addLegend();
    await Promise.all([loadVictims(), loadZones()]);
  }

  function addLegend() {
    const legend = L.control({ position: "bottomright" });
    legend.onAdd = function () {
      const div = L.DomUtil.create("div", "map-legend");
      div.innerHTML = Object.keys(TIER_COLORS).map((t) =>
        '<div><span class="tier-legend__swatch" style="background:' + TIER_COLORS[t] + '"></span>' + t + "</div>"
      ).join("");
      return div;
    };
    legend.addTo(map);
  }

  async function loadVictims() {
    victimsLayer.clearLayers();
    let rows = [];
    try { rows = await SUAR.api.get("/admin/bundles?limit=500"); } catch (_) { return; }
    rows.filter((b) => b.estimated_lat != null && b.estimated_lng != null).forEach((b) => {
      const color = TIER_COLORS[b.priority_tier] || "#9aa4b2";
      if (b.accuracy_meters) {
        L.circle([b.estimated_lat, b.estimated_lng], {
          radius: b.accuracy_meters, color, weight: 1, fillColor: color, fillOpacity: 0.08,
        }).addTo(victimsLayer);
      }
      L.circleMarker([b.estimated_lat, b.estimated_lng], {
        radius: 7, color: "#fff", weight: 2, fillColor: color, fillOpacity: 0.95,
      }).bindPopup(
        "<b>" + SUAR.ui.esc(b.priority_tier) + "</b> · score " + (b.priority_score != null ? b.priority_score.toFixed(2) : "—") +
        "<br><span class='mono' style='font-size:11px'>" + SUAR.ui.esc(b.device_id) + "</span>" +
        "<br>" + SUAR.ui.fmtCoord(b.estimated_lat, b.estimated_lng)
      ).addTo(victimsLayer);
    });
  }

  async function loadZones() {
    zonesLayer.clearLayers();
    allZones = await SUAR.api.get("/admin/geofences");
    document.getElementById("zone-count").textContent = allZones.length + " zone(s)";
    allZones.forEach((z) => drawZone(z));
    renderList();
  }

  function drawZone(z) {
    const color = SEV_COLORS[z.severity] || SEV_COLORS.warning;
    const opts = { color, weight: 2, fillColor: color, fillOpacity: z.is_active ? 0.18 : 0.05, dashArray: z.is_active ? null : "5,5" };
    let layer = null;
    try {
      if (z.shape === "circle" && z.geometry && z.geometry.center) {
        layer = L.circle(z.geometry.center, Object.assign({ radius: z.geometry.radius_m || 100 }, opts));
      } else if (z.geometry && z.geometry.length) {
        layer = L.polygon(z.geometry, opts);
      }
    } catch (_) { return; }
    if (!layer) return;
    layer.bindPopup(
      "<b>" + SUAR.ui.esc(z.name) + "</b><br>" + SUAR.ui.esc(z.hazard_type) + " · " + SUAR.ui.esc(z.severity) +
      (z.is_active ? "" : " · inactive")
    );
    layer.addTo(zonesLayer);
  }

  function renderList() {
    const wrap = document.getElementById("zone-list");
    if (!wrap) return;
    let rows = allZones.slice();
    if (zSev) rows = rows.filter((z) => z.severity === zSev);
    if (zActive) rows = rows.filter((z) => zActive === "active" ? z.is_active !== false : z.is_active === false);
    const q = zSearch.trim().toLowerCase();
    if (q) rows = rows.filter((z) => (z.name || "").toLowerCase().includes(q) || (z.hazard_type || "").toLowerCase().includes(q));
    const filtering = zSearch || zSev || zActive;
    if (!rows.length) { wrap.innerHTML = SUAR.ui.empty(filtering ? "No matches" : "No hazard zones yet", filtering ? "Try a different search or filter." : "Use the draw tools on the map (polygon, rectangle or circle) to add one."); return; }
    const total = rows.length;
    zPage = SUAR.ui.pageClamp(zPage, total, zPageSize);
    _zPageRows = rows.slice((zPage - 1) * zPageSize, zPage * zPageSize);
    wrap.innerHTML =
      '<table class="data"><thead><tr><th>Name</th><th>Hazard</th><th>Severity</th><th>Shape</th><th>Active</th><th>Created</th><th></th></tr></thead><tbody>' +
      _zPageRows.map((z) =>
        "<tr>" +
        "<td><b>" + SUAR.ui.esc(z.name) + "</b></td>" +
        '<td><span class="chip">' + SUAR.ui.esc(z.hazard_type) + "</span></td>" +
        "<td>" + SUAR.ui.severityBadge(z.severity) + "</td>" +
        '<td class="muted">' + SUAR.ui.esc(z.shape) + "</td>" +
        "<td>" + (z.is_active ? '<span class="chip chip--on">active</span>' : '<span class="chip chip--off">inactive</span>') + "</td>" +
        '<td class="muted">' + SUAR.ui.fmtRelative(z.created_at) + "</td>" +
        '<td class="cell-actions"><button class="btn btn--ghost btn--sm" data-edit>Edit</button><button class="btn btn--danger btn--sm" data-del>Delete</button></td>' +
        "</tr>"
      ).join("") + "</tbody></table>" + SUAR.ui.pagerControls(total, zPage, zPageSize);
    _zPageRows.forEach((z, i) => {
      const tr = wrap.querySelectorAll("tbody tr")[i];
      tr.querySelector("[data-edit]").addEventListener("click", () => openEditMeta(z));
      tr.querySelector("[data-del]").addEventListener("click", () => del(z));
    });
    SUAR.ui.bindPager(wrap, total, zPage, zPageSize, (p, s) => { zPage = p; zPageSize = s; renderList(); });
  }

  // New shape drawn → capture geometry, ask for metadata, POST.
  function onDrawn(layer, drawnGroup) {
    let shape, geometry;
    if (layer instanceof L.Circle) {
      shape = "circle";
      const c = layer.getLatLng();
      geometry = { center: [c.lat, c.lng], radius_m: Math.round(layer.getRadius()) };
    } else {
      shape = layer instanceof L.Rectangle ? "polygon" : "polygon";
      geometry = layer.getLatLngs()[0].map((p) => [p.lat, p.lng]);
    }
    drawnGroup.addLayer(layer); // temporary preview
    openZoneForm({ shape, geometry }, () => drawnGroup.removeLayer(layer));
  }

  function zoneFormBody(z) {
    const isCustom = z.hazard_type && !HAZARDS.includes(z.hazard_type);
    const sel = isCustom ? "other" : (z.hazard_type || HAZARDS[0]);
    return (
      '<div class="field"><label>Name</label><input class="input" id="z-name" maxlength="80" placeholder="e.g. Riverside flood area" value="' + SUAR.ui.esc(z.name || "") + '"></div>' +
      '<div class="form-row">' +
        '<div class="field"><label>Hazard type</label><select class="select" id="z-hazard">' +
          HAZARDS.map((h) => '<option' + (sel === h ? " selected" : "") + ">" + h + "</option>").join("") + "</select>" +
          '<input class="input" id="z-hazard-custom" maxlength="40" placeholder="Custom hazard type" style="margin-top:6px;' + (sel === "other" ? "" : "display:none") + '" value="' + SUAR.ui.esc(isCustom ? z.hazard_type : "") + '"></div>' +
        '<div class="field"><label>Severity</label><select class="select" id="z-sev">' +
          ["info", "warning", "danger"].map((sv) => '<option' + (z.severity === sv ? " selected" : "") + ">" + sv + "</option>").join("") + "</select></div>" +
      "</div>" +
      '<label class="switch"><input type="checkbox" id="z-active"' + (z.is_active === false ? "" : " checked") + '><span class="switch__track"></span> Active</label>'
    );
  }

  // Reveal the custom-hazard input only when "other" is chosen.
  function bindHazardToggle() {
    const sel = document.getElementById("z-hazard");
    if (!sel) return;
    sel.addEventListener("change", (e) => {
      document.getElementById("z-hazard-custom").style.display = e.target.value === "other" ? "" : "none";
    });
  }

  function readZoneForm() {
    let hazard_type = document.getElementById("z-hazard").value;
    if (hazard_type === "other") {
      const custom = document.getElementById("z-hazard-custom").value.trim();
      if (custom) hazard_type = custom;
    }
    return {
      name: document.getElementById("z-name").value.trim(),
      hazard_type: hazard_type,
      severity: document.getElementById("z-sev").value,
      is_active: document.getElementById("z-active").checked,
    };
  }

  // Create form (with geometry from the drawn layer).
  function openZoneForm(drawn, onCancel) {
    const m = SUAR.ui.modal({
      title: "New hazard zone",
      body: zoneFormBody({ severity: "danger", is_active: true }),
      actions: [
        { label: "Discard", className: "btn--ghost", onClick: (c) => { onCancel(); c(); } },
        { label: "Save zone", className: "btn--primary", onClick: async (close, btn) => {
            const f = readZoneForm();
            if (!f.name) { SUAR.ui.toast("Name required", "err"); return; }
            btn.disabled = true;
            try {
              await SUAR.api.post("/admin/geofences", Object.assign(f, { shape: drawn.shape, geometry: drawn.geometry }));
              onCancel(); // remove the temp preview; loadZones re-draws from server
              SUAR.ui.toast("Hazard zone saved", "ok"); close(); loadZones(); SUAR.app.refreshCounts();
            } catch (e) { SUAR.ui.toast(e.message, "err"); btn.disabled = false; }
          } },
      ],
    });
    bindHazardToggle();
    // Closing the form any way (X, Esc, backdrop) must remove the temp drawing,
    // not leave an unsaved box on the map. onCancel is idempotent.
    m.overlay.addEventListener("click", (e) => { if (e.target === m.overlay) onCancel(); });
    m.panel.querySelector("[data-close]").addEventListener("click", onCancel);
    const escCancel = (e) => { if (e.key === "Escape") { onCancel(); document.removeEventListener("keydown", escCancel); } };
    document.addEventListener("keydown", escCancel);
  }

  // Edit metadata only (not geometry).
  function openEditMeta(z) {
    SUAR.ui.modal({
      title: "Edit hazard zone",
      body: zoneFormBody(z) + '<p class="muted" style="font-size:12px;margin-bottom:0">To change the shape, delete this zone and draw a new one.</p>',
      actions: [
        { label: "Cancel", className: "btn--ghost", onClick: (c) => c() },
        { label: "Save", className: "btn--primary", onClick: async (close, btn) => {
            const f = readZoneForm();
            if (!f.name) { SUAR.ui.toast("Name required", "err"); return; }
            btn.disabled = true;
            try {
              await SUAR.api.patch("/admin/geofences/" + encodeURIComponent(z.geofence_id), f);
              SUAR.ui.toast("Zone updated", "ok"); close(); loadZones();
            } catch (e) { SUAR.ui.toast(e.message, "err"); btn.disabled = false; }
          } },
      ],
    });
    bindHazardToggle();
  }

  async function del(z) {
    const ok = await SUAR.ui.confirm({ title: "Delete zone?", message: 'Remove "' + z.name + '"?', confirmLabel: "Delete", danger: true });
    if (!ok) return;
    try {
      await SUAR.api.del("/admin/geofences/" + encodeURIComponent(z.geofence_id));
      SUAR.ui.toast("Zone deleted", "ok"); loadZones(); SUAR.app.refreshCounts();
    } catch (e) { SUAR.ui.toast(e.message, "err"); }
  }

  return { render };
})();
