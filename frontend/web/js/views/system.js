/* System Settings: admin default for triage scoring weights/tiers/rules
 * (mirrors the mobile Settings > Debugging Options > Triage Logic page —
 * see triage_config.dart on the app side), and the password lock in front
 * of that same debugging menu on-device.
 *
 * Precedence: a device with its own local Triage Logic edits keeps them —
 * this only sets the default for devices that never touched it, and what
 * their "Reset" button reverts to. */
window.SUAR = window.SUAR || {};
SUAR.views = SUAR.views || {};

SUAR.views.system = (function () {
  // Mirrors TriageConfig.defaults() in triage_config.dart — kept in sync by
  // hand since it's a small, stable, hand-picked calibration, not generated.
  const DEFAULTS = {
    w_motion: 38, w_battery: 22, w_mic: 18, w_barometer: 12, w_light: 6, w_proximity: 4,
    score_cap: 200, critical_threshold: 75, high_threshold: 50, moderate_threshold: 25,
    fall_enabled: true, fall_boost: 25, fall_latch_seconds: 45,
    faint_enabled: true, faint_boost: 55, faint_immobile_seconds: 20,
    low_battery_enabled: true, low_battery_threshold: 30, low_battery_boost: 40,
    critical_battery_enabled: true, critical_battery_threshold: 15, critical_battery_boost: 80,
    battery_comfort_level: 40, pressure_max_deviation_hpa: 5, mic_min_db: 55, mic_max_db: 90,
    dark_below_lux: 40, bright_above_lux: 25000, battery_fast_drain_per_min: 2,
  };

  // Per-field [min, max]. The backend already rejects non-finite/negative
  // numbers; these add the bounds it can't know — percentages are 0-100, and
  // the rest get a sane ceiling so a fat-fingered 500 (meant 50) can't ship a
  // nonsense default to every device. Also drives the inputs' min/max attrs.
  const RANGES = {
    w_motion: [0, 100], w_battery: [0, 100], w_mic: [0, 100],
    w_barometer: [0, 100], w_light: [0, 100], w_proximity: [0, 100],
    score_cap: [1, 1000],
    critical_threshold: [0, 1000], high_threshold: [0, 1000], moderate_threshold: [0, 1000],
    fall_boost: [0, 500], fall_latch_seconds: [1, 3600],
    faint_boost: [0, 500], faint_immobile_seconds: [1, 3600],
    low_battery_threshold: [0, 100], low_battery_boost: [0, 500],
    critical_battery_threshold: [0, 100], critical_battery_boost: [0, 500],
    battery_comfort_level: [0, 100],
    pressure_max_deviation_hpa: [0.1, 500],
    mic_min_db: [0, 200], mic_max_db: [0, 200],
    dark_below_lux: [0, 200000], bright_above_lux: [0, 200000],
    battery_fast_drain_per_min: [0.01, 100],
  };

  // [greater, lesser, message] — each pair must strictly descend or the rule
  // it feeds becomes unreachable / inverted on the device.
  const ORDER_RULES = [
    ["critical_threshold", "high_threshold", "Tier thresholds must descend: Critical at > High at"],
    ["high_threshold", "moderate_threshold", "Tier thresholds must descend: High at > Moderate at"],
    ["mic_max_db", "mic_min_db", "Mic loud ceiling must be above the quiet floor"],
    ["bright_above_lux", "dark_below_lux", "Light: bright-above must be higher than dark-below"],
    ["low_battery_threshold", "critical_battery_threshold", "Low battery % must be above critical battery %"],
  ];

  const FIELD_GROUPS = [
    { title: "Sensor weights", fields: [
      ["w_motion", "Motion (accel + gyro)"], ["w_battery", "Battery"], ["w_mic", "Microphone"],
      ["w_barometer", "Barometer"], ["w_light", "Ambient light"], ["w_proximity", "Proximity"],
    ] },
    { title: "Score & tiers", fields: [
      ["score_cap", "Score cap"], ["critical_threshold", "Critical at"],
      ["high_threshold", "High at"], ["moderate_threshold", "Moderate at"],
    ] },
    { title: "Fall / faint rules", fields: [
      ["fall_boost", "Fall: adds"], ["fall_latch_seconds", "Fall: stays on for (s)"],
      ["faint_boost", "Faint: adds"], ["faint_immobile_seconds", "Faint: observe (75% low) (s)"],
    ] },
    { title: "Battery rules", fields: [
      ["low_battery_threshold", "Low battery at (%)"], ["low_battery_boost", "Low battery: adds"],
      ["critical_battery_threshold", "Critical battery at (%)"], ["critical_battery_boost", "Critical battery: adds"],
      ["battery_comfort_level", "Battery healthy above (%)"],
    ] },
    { title: "Normalisation ranges", fields: [
      ["pressure_max_deviation_hpa", "Pressure: full risk at (hPa)"],
      ["mic_min_db", "Mic: quiet floor (dB)"], ["mic_max_db", "Mic: loud ceiling (dB)"],
      ["dark_below_lux", "Light: dark below (lx)"], ["bright_above_lux", "Light: bright above (lx)"],
      ["battery_fast_drain_per_min", "Battery: fast drain at (%/min)"],
    ] },
  ];

  const FIELD_LABELS = {};
  FIELD_GROUPS.forEach((g) => g.fields.forEach(([k, l]) => { FIELD_LABELS[k] = l; }));

  const TOGGLE_FIELDS = [
    ["fall_enabled", "Fall detection enabled"],
    ["faint_enabled", "Faint detection enabled"],
    ["low_battery_enabled", "Low-battery rule enabled"],
    ["critical_battery_enabled", "Critical-battery rule enabled"],
  ];

  // Same 6-color set already used across the console (dashboard tier chips,
  // stat accents, the connection pill) — not tier-severity colors here, just
  // reusing the existing palette so this reads as part of the same design.
  const SENSOR_METERS = [
    ["w_motion", "Motion", "var(--critical)"],
    ["w_battery", "Battery", "var(--high)"],
    ["w_mic", "Microphone", "var(--moderate)"],
    ["w_barometer", "Barometer", "var(--accent)"],
    ["w_light", "Ambient light", "var(--accent-soft)"],
    ["w_proximity", "Proximity", "var(--ok)"],
  ];

  let cfg = null;
  let lock = null;

  async function render(container) {
    container.innerHTML = SUAR.ui.spinner();
    try {
      [cfg, lock] = await Promise.all([
        SUAR.api.get("/admin/triage-config"),
        SUAR.api.get("/admin/debug-lock"),
      ]);
    } catch (e) {
      container.innerHTML = SUAR.ui.empty("Couldn't load system settings", e.message || String(e));
      return;
    }
    // Endpoints return null if the settings row was never seeded — fall back
    // to the built-in defaults instead of crashing the whole view.
    cfg = cfg || { ...DEFAULTS };
    lock = lock || { enabled: true };
    draw(container);
  }

  function numField(key, label) {
    const v = cfg[key] ?? DEFAULTS[key];
    const r = RANGES[key];
    return '<div class="field"><label>' + SUAR.ui.esc(label) + '</label>' +
      '<input class="input" type="number" step="any"' +
      (r ? ' min="' + r[0] + '" max="' + r[1] + '"' : "") +
      ' data-field="' + key + '" value="' + v + '"></div>';
  }

  function toggleField(key, label) {
    const on = !!(cfg[key] ?? DEFAULTS[key]);
    return '<label class="switch"><input type="checkbox" data-field="' + key + '"' + (on ? " checked" : "") +
      '><span class="switch__track"></span>' + SUAR.ui.esc(label) + "</label>";
  }

  // Reads current values straight from the inputs (not the possibly-stale
  // `cfg`), so it stays live as you type. Falls back to cfg/DEFAULTS before
  // the inputs exist yet (first render).
  function currentWeights() {
    return SENSOR_METERS.map(([k, l, c]) => {
      const el = document.querySelector('[data-field="' + k + '"]');
      const v = el ? Number(el.value) || 0 : (cfg[k] ?? DEFAULTS[k]);
      return { key: k, label: l, color: c, value: v };
    });
  }

  // One singular bar — same signature stacked bar as the dashboard's tier
  // bar (.tierbar/.tierbar__seg, flex-grow per segment), just colored by
  // sensor instead of tier. "Max" is the live sum of all six weights, so a
  // segment's width is always that sensor's live share of the whole —
  // exactly what the triage score cares about, not a fixed slider ceiling.
  function weightBarHtml() {
    const weights = currentWeights();
    const total = weights.reduce((a, w) => a + w.value, 0);
    const segs = weights.map((w) => {
      if (!w.value) return "";
      return '<div class="tierbar__seg" style="flex-grow:' + w.value + ";background:" + w.color + '" title="' +
        w.label + ": " + w.value + '"></div>';
    }).join("");
    const legend = weights.map((w) =>
      '<div class="tier-legend__item"><span class="tier-legend__swatch" style="background:' + w.color + '"></span>' +
      '<span class="tier-legend__count">' + Math.round(w.value) + "</span>" +
      '<span class="tier-legend__name">' + SUAR.ui.esc(w.label) + "</span></div>"
    ).join("");
    return (
      '<div class="card" style="margin-bottom:16px" id="weight-bar-card">' +
      '<div class="card__head"><h3>Sensor weight balance</h3><span class="spacer"></span>' +
      '<span class="eyebrow">' + Math.round(total) + " total</span></div>" +
      '<div class="card__body"><div class="tierbar">' +
      (total ? segs : '<div class="tierbar__seg" style="flex-grow:1;background:var(--line)"></div>') +
      "</div>" +
      '<div class="tier-legend">' + legend + "</div></div></div>"
    );
  }

  function refreshWeightBar() {
    const el = document.getElementById("weight-bar-card");
    if (el) el.outerHTML = weightBarHtml();
    // outerHTML replaces the node, so re-bind this card's own listeners.
    wireWeightBar();
  }

  function wireWeightBar() {
    SENSOR_METERS.forEach(([k]) => {
      const el = document.querySelector('[data-field="' + k + '"]');
      if (el) el.addEventListener("input", refreshWeightBar);
    });
  }

  function draw(container) {
    const sections = FIELD_GROUPS.map((g) =>
      '<div class="card"><div class="card__head"><h3>' + SUAR.ui.esc(g.title) + "</h3></div>" +
      '<div class="card__body grid grid--2">' + g.fields.map(([k, l]) => numField(k, l)).join("") + "</div></div>"
    ).join("");

    container.innerHTML =
      '<div class="section-title">Triage weights</div>' +
      '<p class="muted" style="font-size:13px;margin:0 0 12px">Live-tunable on the device too ' +
      "(Settings &gt; Debugging Options &gt; Triage Logic). A device with its own local edits keeps " +
      "them — this only sets the default for devices that have never tuned it, and what their " +
      "Reset button reverts to.</p>" +
      weightBarHtml() +
      sections +
      '<div class="card"><div class="card__head"><h3>Safety rule toggles</h3></div><div class="card__body">' +
      TOGGLE_FIELDS.map(([k, l]) => '<div style="margin-bottom:10px">' + toggleField(k, l) + "</div>").join("") +
      "</div></div>" +
      '<div style="display:flex;gap:10px;margin:16px 0 28px">' +
      '<button class="btn btn--primary" id="sys-save">Save changes</button>' +
      '<button class="btn btn--ghost" id="sys-reset">Reset to built-in defaults</button>' +
      "</div>" +
      '<div class="section-title">Debugging Options lock</div>' +
      '<div class="card"><div class="card__body">' +
      '<p class="muted" style="font-size:13px;margin:0 0 12px">Requires a password on the app before ' +
      "Settings &gt; Debugging Options opens. Devices cache this, so it still applies offline.</p>" +
      '<label class="switch" style="margin-bottom:14px"><input type="checkbox" id="lock-enabled"' +
      (lock.enabled ? " checked" : "") + '><span class="switch__track"></span>Require password</label>' +
      '<div class="field"><label>Set new password</label>' +
      '<input class="input" type="password" id="lock-password" minlength="4" autocomplete="new-password" placeholder="Leave blank to keep current password"></div>' +
      '<button class="btn btn--primary btn--sm" id="lock-save">Save lock settings</button>' +
      "</div></div>";

    document.getElementById("sys-save").addEventListener("click", saveTriage);
    document.getElementById("sys-reset").addEventListener("click", resetTriage);
    document.getElementById("lock-save").addEventListener("click", saveLock);
    wireWeightBar();
  }

  // Returns null (with a toast naming the bad field) rather than sending an
  // empty box as 0 or free text as NaN — every triage column is a
  // non-negative NOT NULL number server-side.
  function collectTriagePayload() {
    const payload = {};
    let bad = null, badMsg = "";
    document.querySelectorAll("[data-field]").forEach((el) => {
      if (el.type === "checkbox") { payload[el.dataset.field] = el.checked; return; }
      const key = el.dataset.field;
      const v = Number(el.value);
      if (el.value.trim() === "" || !Number.isFinite(v) || v < 0) {
        if (!bad) { bad = key; badMsg = "needs a number of 0 or more"; }
      } else {
        const r = RANGES[key];
        if (r && (v < r[0] || v > r[1]) && !bad) { bad = key; badMsg = "must be between " + r[0] + " and " + r[1]; }
      }
      payload[key] = v;
    });
    if (bad) {
      SUAR.ui.toast('"' + (FIELD_LABELS[bad] || bad) + '" ' + badMsg, "err");
      return null;
    }
    // Device-side tier classification is first-match-wins (critical, then high,
    // then moderate) and the normalisation ranges divide by (max - min), so any
    // inverted pair silently kills a tier or a sensor.
    for (const [hi, lo, msg] of ORDER_RULES) {
      if (!(payload[hi] > payload[lo])) { SUAR.ui.toast(msg, "err"); return null; }
    }
    // A score is capped at score_cap, so a Critical threshold above the cap can
    // never be reached — the tier would be dead on every device.
    if (payload.critical_threshold > payload.score_cap) {
      SUAR.ui.toast("Critical at (" + payload.critical_threshold + ") can never be reached above the score cap (" + payload.score_cap + ")", "err");
      return null;
    }
    // All-zero weights means every bundle scores 0 and nothing ever triages.
    const weightSum = SENSOR_METERS.reduce((a, [k]) => a + (payload[k] || 0), 0);
    if (weightSum <= 0) {
      SUAR.ui.toast("At least one sensor weight must be above 0", "err");
      return null;
    }
    return payload;
  }

  async function saveTriage() {
    const payload = collectTriagePayload();
    if (!payload) return;
    const btn = document.getElementById("sys-save");
    btn.disabled = true;
    try {
      cfg = await SUAR.api.patch("/admin/triage-config", payload);
      SUAR.ui.toast("Triage config saved", "ok");
    } catch (e) {
      SUAR.ui.toast(e.message, "err");
    } finally {
      btn.disabled = false;
    }
  }

  async function resetTriage() {
    const ok = await SUAR.ui.confirm({
      title: "Reset to built-in defaults?",
      message: "Overwrites the admin default with SUAR's original factory weights. Devices with their own local tuning are unaffected.",
    });
    if (!ok) return;
    try {
      cfg = await SUAR.api.patch("/admin/triage-config", DEFAULTS);
      SUAR.ui.toast("Reset to defaults", "ok");
      draw(document.getElementById("view"));
    } catch (e) {
      SUAR.ui.toast(e.message, "err");
    }
  }

  async function saveLock() {
    const btn = document.getElementById("lock-save");
    const enabled = document.getElementById("lock-enabled").checked;
    const password = document.getElementById("lock-password").value.trim();
    // Mirrors the backend's >= 4 rule so it fails here instead of round-tripping.
    if (password && password.length < 4) {
      SUAR.ui.toast("Password must be at least 4 characters", "err");
      return;
    }
    btn.disabled = true;
    try {
      const payload = { enabled };
      if (password) payload.password = password;
      lock = await SUAR.api.patch("/admin/debug-lock", payload);
      document.getElementById("lock-password").value = "";
      SUAR.ui.toast("Lock settings saved", "ok");
    } catch (e) {
      SUAR.ui.toast(e.message, "err");
    } finally {
      btn.disabled = false;
    }
  }

  return { render };
})();
