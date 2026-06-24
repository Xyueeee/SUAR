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

  async function render(container) {
    if (map) { map.remove(); map = null; }
    container.innerHTML =
      '<div class="card" style="margin-bottom:16px"><div class="card__body" style="padding:12px">' +
        '<div class="map" id="zone-map"></div>' +
        '<p class="muted" style="font-size:12.5px;margin:10px 4px 0">Use the draw tools (top-left) to add a hazard zone — polygon, rectangle or circle. Victim markers are coloured by triage tier; the faint ring is GPS accuracy.</p>' +
      "</div></div>" +
      '<div class="card"><div class="card__head"><h3>Hazard zones</h3><span class="spacer"></span><span class="eyebrow" id="zone-count"></span></div>' +
        '<div class="table-wrap" id="zone-list">' + SUAR.ui.spinner() + "</div></div>";

    map = L.map("zone-map");
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
    rows.filter((b) => b.estimatedlat != null && b.estimatedlng != null).forEach((b) => {
      const color = TIER_COLORS[b.prioritytier] || "#9aa4b2";
      if (b.accuracymeters) {
        L.circle([b.estimatedlat, b.estimatedlng], {
          radius: b.accuracymeters, color, weight: 1, fillColor: color, fillOpacity: 0.08,
        }).addTo(victimsLayer);
      }
      L.circleMarker([b.estimatedlat, b.estimatedlng], {
        radius: 7, color: "#fff", weight: 2, fillColor: color, fillOpacity: 0.95,
      }).bindPopup(
        "<b>" + SUAR.ui.esc(b.prioritytier) + "</b> · score " + (b.priorityscore != null ? b.priorityscore.toFixed(2) : "—") +
        "<br><span class='mono' style='font-size:11px'>" + SUAR.ui.esc(b.deviceid) + "</span>" +
        "<br>" + SUAR.ui.fmtCoord(b.estimatedlat, b.estimatedlng)
      ).addTo(victimsLayer);
    });
  }

  async function loadZones() {
    zonesLayer.clearLayers();
    const zones = await SUAR.api.get("/admin/geofences");
    document.getElementById("zone-count").textContent = zones.length + " zone(s)";
    zones.forEach((z) => drawZone(z));
    renderList(zones);
  }

  function drawZone(z) {
    const color = SEV_COLORS[z.severity] || SEV_COLORS.warning;
    const opts = { color, weight: 2, fillColor: color, fillOpacity: z.isactive ? 0.18 : 0.05, dashArray: z.isactive ? null : "5,5" };
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
      "<b>" + SUAR.ui.esc(z.name) + "</b><br>" + SUAR.ui.esc(z.hazardtype) + " · " + SUAR.ui.esc(z.severity) +
      (z.isactive ? "" : " · inactive")
    );
    layer.addTo(zonesLayer);
  }

  function renderList(zones) {
    const wrap = document.getElementById("zone-list");
    if (!zones.length) { wrap.innerHTML = SUAR.ui.empty("No hazard zones", "Draw one on the map to warn nearby devices (app-side, later)."); return; }
    wrap.innerHTML =
      '<table class="data"><thead><tr><th>Name</th><th>Hazard</th><th>Severity</th><th>Shape</th><th>Active</th><th>Created</th><th></th></tr></thead><tbody>' +
      zones.map((z) =>
        "<tr>" +
        "<td><b>" + SUAR.ui.esc(z.name) + "</b></td>" +
        '<td><span class="chip">' + SUAR.ui.esc(z.hazardtype) + "</span></td>" +
        "<td>" + SUAR.ui.severityBadge(z.severity) + "</td>" +
        '<td class="muted">' + SUAR.ui.esc(z.shape) + "</td>" +
        "<td>" + (z.isactive ? '<span class="chip chip--on">active</span>' : '<span class="chip chip--off">inactive</span>') + "</td>" +
        '<td class="muted">' + SUAR.ui.fmtRelative(z.createdat) + "</td>" +
        '<td class="cell-actions"><button class="btn btn--ghost btn--sm" data-edit>Edit</button><button class="btn btn--danger btn--sm" data-del>Delete</button></td>' +
        "</tr>"
      ).join("") + "</tbody></table>";
    zones.forEach((z, i) => {
      const tr = wrap.querySelectorAll("tbody tr")[i];
      tr.querySelector("[data-edit]").addEventListener("click", () => openEditMeta(z));
      tr.querySelector("[data-del]").addEventListener("click", () => del(z));
    });
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
    return (
      '<div class="field"><label>Name</label><input class="input" id="z-name" placeholder="e.g. Riverside flood area" value="' + SUAR.ui.esc(z.name || "") + '"></div>' +
      '<div class="form-row">' +
        '<div class="field"><label>Hazard type</label><select class="select" id="z-hazard">' +
          HAZARDS.map((h) => '<option' + (z.hazardtype === h ? " selected" : "") + ">" + h + "</option>").join("") + "</select></div>" +
        '<div class="field"><label>Severity</label><select class="select" id="z-sev">' +
          ["info", "warning", "danger"].map((sv) => '<option' + (z.severity === sv ? " selected" : "") + ">" + sv + "</option>").join("") + "</select></div>" +
      "</div>" +
      '<label class="switch"><input type="checkbox" id="z-active"' + (z.isactive === false ? "" : " checked") + '><span class="switch__track"></span> Active</label>'
    );
  }

  function readZoneForm() {
    return {
      name: document.getElementById("z-name").value.trim(),
      hazardtype: document.getElementById("z-hazard").value,
      severity: document.getElementById("z-sev").value,
      isactive: document.getElementById("z-active").checked,
    };
  }

  // Create form (with geometry from the drawn layer).
  function openZoneForm(drawn, onCancel) {
    const m = SUAR.ui.modal({
      title: "New hazard zone",
      body: zoneFormBody({ severity: "danger", isactive: true }),
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
    m.overlay.addEventListener("click", (e) => { if (e.target === m.overlay) onCancel(); });
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
              await SUAR.api.patch("/admin/geofences/" + encodeURIComponent(z.geofenceid), f);
              SUAR.ui.toast("Zone updated", "ok"); close(); loadZones();
            } catch (e) { SUAR.ui.toast(e.message, "err"); btn.disabled = false; }
          } },
      ],
    });
  }

  async function del(z) {
    const ok = await SUAR.ui.confirm({ title: "Delete zone?", message: 'Remove "' + z.name + '"?', confirmLabel: "Delete", danger: true });
    if (!ok) return;
    try {
      await SUAR.api.del("/admin/geofences/" + encodeURIComponent(z.geofenceid));
      SUAR.ui.toast("Zone deleted", "ok"); loadZones(); SUAR.app.refreshCounts();
    } catch (e) { SUAR.ui.toast(e.message, "err"); }
  }

  return { render };
})();
