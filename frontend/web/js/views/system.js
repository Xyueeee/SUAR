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
    wmotion: 38, wbattery: 22, wmic: 18, wbarometer: 12, wlight: 6, wproximity: 4,
    scorecap: 200, criticalthreshold: 75, highthreshold: 50, moderatethreshold: 25,
    fallenabled: true, fallboost: 25, falllatchseconds: 45,
    faintenabled: true, faintboost: 55, faintimmobileseconds: 20,
    lowbatteryenabled: true, lowbatterythreshold: 30, lowbatteryboost: 40,
    criticalbatteryenabled: true, criticalbatterythreshold: 15, criticalbatteryboost: 80,
    batterycomfortlevel: 40, pressuremaxdeviationhpa: 5, micmindb: 55, micmaxdb: 90,
    darkbelowlux: 40, brightabovelux: 25000, batteryfastdrainpermin: 2,
  };

  const FIELD_GROUPS = [
    { title: "Sensor weights", fields: [
      ["wmotion", "Motion (accel + gyro)"], ["wbattery", "Battery"], ["wmic", "Microphone"],
      ["wbarometer", "Barometer"], ["wlight", "Ambient light"], ["wproximity", "Proximity"],
    ] },
    { title: "Score & tiers", fields: [
      ["scorecap", "Score cap"], ["criticalthreshold", "Critical at"],
      ["highthreshold", "High at"], ["moderatethreshold", "Moderate at"],
    ] },
    { title: "Fall / faint rules", fields: [
      ["fallboost", "Fall: adds"], ["falllatchseconds", "Fall: stays on for (s)"],
      ["faintboost", "Faint: adds"], ["faintimmobileseconds", "Faint: no movement for (s)"],
    ] },
    { title: "Battery rules", fields: [
      ["lowbatterythreshold", "Low battery at (%)"], ["lowbatteryboost", "Low battery: adds"],
      ["criticalbatterythreshold", "Critical battery at (%)"], ["criticalbatteryboost", "Critical battery: adds"],
      ["batterycomfortlevel", "Battery healthy above (%)"],
    ] },
    { title: "Normalisation ranges", fields: [
      ["pressuremaxdeviationhpa", "Pressure: full risk at (hPa)"],
      ["micmindb", "Mic: quiet floor (dB)"], ["micmaxdb", "Mic: loud ceiling (dB)"],
      ["darkbelowlux", "Light: dark below (lx)"], ["brightabovelux", "Light: bright above (lx)"],
      ["batteryfastdrainpermin", "Battery: fast drain at (%/min)"],
    ] },
  ];

  const FIELD_LABELS = {};
  FIELD_GROUPS.forEach((g) => g.fields.forEach(([k, l]) => { FIELD_LABELS[k] = l; }));

  const TOGGLE_FIELDS = [
    ["fallenabled", "Fall detection enabled"],
    ["faintenabled", "Faint detection enabled"],
    ["lowbatteryenabled", "Low-battery rule enabled"],
    ["criticalbatteryenabled", "Critical-battery rule enabled"],
  ];

  // Same 6-color set already used across the console (dashboard tier chips,
  // stat accents, the connection pill) — not tier-severity colors here, just
  // reusing the existing palette so this reads as part of the same design.
  const SENSOR_METERS = [
    ["wmotion", "Motion", "var(--critical)"],
    ["wbattery", "Battery", "var(--high)"],
    ["wmic", "Microphone", "var(--moderate)"],
    ["wbarometer", "Barometer", "var(--accent)"],
    ["wlight", "Ambient light", "var(--accent-soft)"],
    ["wproximity", "Proximity", "var(--ok)"],
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
    return '<div class="field"><label>' + SUAR.ui.esc(label) + '</label>' +
      '<input class="input" type="number" step="any" data-field="' + key + '" value="' + v + '"></div>';
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
      '<input class="input" type="password" id="lock-password" placeholder="Leave blank to keep current password"></div>' +
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
    let bad = null;
    document.querySelectorAll("[data-field]").forEach((el) => {
      if (el.type === "checkbox") { payload[el.dataset.field] = el.checked; return; }
      const v = Number(el.value);
      if (el.value.trim() === "" || !Number.isFinite(v) || v < 0) bad = bad || el.dataset.field;
      payload[el.dataset.field] = v;
    });
    if (bad) {
      SUAR.ui.toast('"' + (FIELD_LABELS[bad] || bad) + '" needs a number of 0 or more', "err");
      return null;
    }
    // Device-side tier classification is first-match-wins (critical, then
    // high, then moderate), so out-of-order thresholds silently kill tiers.
    if (!(payload.criticalthreshold > payload.highthreshold &&
          payload.highthreshold > payload.moderatethreshold)) {
      SUAR.ui.toast("Tier thresholds must descend: Critical > High > Moderate", "err");
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
      cfg = await SUAR.api.patch("/admin/triage-config", collectTriagePayload());
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
