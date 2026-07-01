/* Dashboard: situation board. Triage-tier bar is the hero (what a coordinator
 * reads first), backed by stat tiles, a 14-day activity chart, a tier doughnut,
 * recent bundles and a mini map of located victims. */
window.SUAR = window.SUAR || {};
SUAR.views = SUAR.views || {};

SUAR.views.dashboard = (function () {
  const TIERS = ["Critical", "High", "Moderate", "Low", "None"];
  // Same colors the mobile Helper map uses for these exact tiers
  // (_VictimMarker.colorForTier in helper_mode_screen.dart: Colors.redAccent /
  // orangeAccent / amber / lightGreenAccent / grey) — app and admin now read
  // the same severity at a glance instead of two different palettes.
  const TIER_COLORS = {
    Critical: "#FF5252", High: "#FFAB40", Moderate: "#FFC107", Low: "#B2FF59", None: "#9E9E9E",
  };
  let charts = [];
  let map = null;

  function tierBarHtml(counts) {
    const total = TIERS.reduce((a, t) => a + (counts[t] || 0), 0);
    // Inline colors from TIER_COLORS (not the shared .seg-*/.sw-* CSS classes)
    // so this recolor stays scoped to the dashboard's own tier bar + legend,
    // not the tier badges used elsewhere (bundles table, etc).
    const segs = TIERS.map((t) => {
      const c = counts[t] || 0;
      if (!c) return "";
      return '<div class="tierbar__seg" style="flex-grow:' + c + ';background:' + TIER_COLORS[t] + '" title="' + t + ": " + c + '"></div>';
    }).join("");
    const legend = TIERS.map((t) =>
      '<div class="tier-legend__item"><span class="tier-legend__swatch" style="background:' + TIER_COLORS[t] + '"></span>' +
      '<span class="tier-legend__count">' + (counts[t] || 0) + '</span>' +
      '<span class="tier-legend__name">' + t + "</span></div>"
    ).join("");
    return (
      '<div class="card"><div class="card__head"><h3>Triage severity</h3><span class="spacer"></span>' +
      '<span class="eyebrow">' + total + ' bundles</span></div><div class="card__body">' +
      '<div class="tierbar">' + (total ? segs : '<div class="tierbar__seg seg-none" style="flex-grow:1"></div>') + "</div>" +
      '<div class="tier-legend">' + legend + "</div></div></div>"
    );
  }

  function statTile(label, value, sub, accent) {
    return (
      '<div class="stat">' + (accent ? '<div class="stat__accent" style="background:' + accent + '"></div>' : "") +
      '<div class="stat__label">' + label + "</div>" +
      '<div class="stat__value">' + value + "</div>" +
      (sub ? '<div class="stat__sub">' + sub + "</div>" : "") + "</div>"
    );
  }

  function skelRow(n) {
    let h = "";
    for (let i = 0; i < n; i++) h += '<div class="stat"><div class="skel" style="height:12px;width:55%;margin-bottom:10px;border-radius:4px"></div><div class="skel" style="height:28px;width:35%;border-radius:4px"></div></div>';
    return h;
  }

  async function render(container) {
    charts.forEach((c) => c.destroy()); charts = [];
    if (map) { map.remove(); map = null; }

    // Render structural shell immediately — page is no longer blank while fetching.
    container.innerHTML =
      '<div class="grid grid--stats" id="dash-tiles" style="margin-bottom:16px">' + skelRow(4) + "</div>" +
      '<div style="margin-bottom:16px" id="dash-tierbar">' + SUAR.ui.spinner() + "</div>" +
      '<div class="grid grid--2" style="margin-bottom:16px">' +
        '<div class="card"><div class="card__head"><h3>Activity — last 14 days</h3></div><div class="card__body"><canvas id="dash-activity" height="150"></canvas></div></div>' +
        '<div class="card"><div class="card__head"><h3>Severity split</h3></div><div class="card__body" style="display:grid;place-items:center"><div style="max-width:240px;width:100%"><canvas id="dash-tier"></canvas></div></div></div>' +
      "</div>" +
      '<div class="grid grid--2">' +
        '<div class="card"><div class="card__head"><h3>Recent bundles</h3><span class="spacer"></span><a href="#/bundles" class="eyebrow">View all →</a></div><div class="table-wrap" id="dash-recent">' + SUAR.ui.spinner() + "</div></div>" +
        '<div class="card"><div class="card__head"><h3>Located victims</h3><span class="spacer"></span><a href="#/map" class="eyebrow">Open map →</a></div><div class="card__body" style="padding:12px"><div class="map map--mini" id="dash-map"></div></div></div>' +
      "</div>";

    // Init map immediately — tile loading starts in parallel with the stats fetch.
    map = L.map("dash-map", { zoomControl: false, attributionControl: false });
    L.tileLayer("https://tile.openstreetmap.org/{z}/{x}/{y}.png", { maxZoom: 19 }).addTo(map);
    map.setView([3.139, 101.6869], 11); // KL default; overridden below if points exist

    const s = await SUAR.api.get("/admin/stats");

    // Stat tiles
    document.getElementById("dash-tiles").innerHTML =
      statTile("Total bundles", s.totalBundles, s.locatedCount + " located", "var(--accent)") +
      statTile("Critical + High", (s.tierCounts.Critical + s.tierCounts.High), "need attention", "var(--critical)") +
      statTile("Devices seen", s.deviceCount, s.topDevices.length + " active", "var(--accent-soft)") +
      statTile("Active (24h)", s.activeCount, s.inactiveCount + " gone quiet", "var(--accent)");

    // Tier bar
    document.getElementById("dash-tierbar").innerHTML = tierBarHtml(s.tierCounts);

    // Recent bundles
    const recent = s.recentBundles || [];
    document.getElementById("dash-recent").innerHTML = recent.length
      ? '<table class="data"><thead><tr><th>Tier</th><th>Score</th><th>Device</th><th>When</th></tr></thead><tbody>' +
        recent.map((b) =>
          "<tr><td>" + SUAR.ui.tierBadge(b.prioritytier) + "</td>" +
          '<td class="mono-cell">' + (b.priorityscore != null ? b.priorityscore.toFixed(2) : "—") + "</td>" +
          '<td class="id-trunc">' + SUAR.ui.truncId(b.deviceid, 10) + "</td>" +
          '<td class="muted">' + SUAR.ui.fmtRelative(b.createdat) + "</td></tr>"
        ).join("") + "</tbody></table>"
      : SUAR.ui.empty("No bundles yet", "They'll appear once a Helper syncs.");

    // Activity chart
    const act = s.activityByDay || [];
    charts.push(new Chart(document.getElementById("dash-activity"), {
      type: "bar",
      data: {
        labels: act.map((d) => d.date.slice(5)),
        datasets: [{ data: act.map((d) => d.count), backgroundColor: "#A8BED8", borderRadius: 4, maxBarThickness: 22 }],
      },
      options: {
        plugins: { legend: { display: false } },
        scales: { y: { beginAtZero: true, ticks: { precision: 0 }, grid: { color: "#eef1f5" } }, x: { grid: { display: false } } },
      },
    }));

    // Tier doughnut
    const tc = s.tierCounts;
    const hasTier = TIERS.some((t) => tc[t] > 0);
    charts.push(new Chart(document.getElementById("dash-tier"), {
      type: "doughnut",
      data: {
        labels: TIERS,
        datasets: [{
          data: hasTier ? TIERS.map((t) => tc[t]) : [1],
          backgroundColor: hasTier ? TIERS.map((t) => TIER_COLORS[t]) : ["#e3e8ef"],
          borderWidth: 2, borderColor: "#fff",
        }],
      },
      options: { cutout: "62%", plugins: { legend: { display: false }, tooltip: { enabled: hasTier } } },
    }));

    // Map pins (map already initialised above)
    const located = recent.filter((b) => b.estimatedlat != null && b.estimatedlng != null);
    if (located.length) {
      const pts = [];
      located.forEach((b) => {
        const color = TIER_COLORS[b.prioritytier] || "#9aa4b2";
        L.circleMarker([b.estimatedlat, b.estimatedlng], {
          radius: 7, color: "#fff", weight: 2, fillColor: color, fillOpacity: 0.95,
        }).addTo(map);
        pts.push([b.estimatedlat, b.estimatedlng]);
      });
      map.fitBounds(pts, { padding: [30, 30], maxZoom: 15 });
    }
  }

  return { render };
})();
