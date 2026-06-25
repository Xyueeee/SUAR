/* App orchestration: auth gate, hash router, shell chrome (nav, connection
 * pill, backend-URL config, sign-out). Views register themselves on
 * SUAR.views and expose async render(container).
 *
 * Console access requires BOTH a Supabase session AND a successful /admin/me
 * (the email is on the ADMIN_EMAILS allowlist) — a valid login alone is not
 * enough, since the anon key is public. */
window.SUAR = window.SUAR || {};

SUAR.app = (function () {
  const TITLES = {
    dashboard: "Dashboard",
    bundles: "Distress Bundles",
    devices: "Devices",
    map: "Map & Danger Zones",
    notices: "Notices",
    content: "Guides & Tips",
    prep: "Prep Plans",
  };
  const ROUTES = Object.keys(TITLES);
  const IDLE_MS = 20 * 60 * 1000; // auto sign-out after 20 min of inactivity

  let connTimer = null;
  let idleTimer = null;

  function showLogin(opts) {
    opts = opts || {};
    document.body.classList.remove("authed");
    // Don't leave credentials sitting in the form after a sign-out.
    const em = document.getElementById("login-email");
    const pw = document.getElementById("login-password");
    if (em) em.value = "";
    if (pw) pw.value = "";
    if (connTimer) { clearInterval(connTimer); connTimer = null; }
    stopIdleWatch();
    const err = document.getElementById("login-error");
    if (err) {
      if (opts.error) { err.textContent = opts.error; err.style.display = "block"; err.className = "login-note login-note--err"; }
      else if (opts.hint) { err.textContent = opts.hint; err.style.display = "block"; err.className = "login-note"; }
      else { err.style.display = "none"; }
    }
    updateUrlDot();
  }

  // Single entry gate: session -> backend URL set -> /admin/me passes -> show app.
  async function tryEnterApp() {
    const session = await SUAR.auth.getSession();
    if (!session) { showLogin(); return; }
    if (!SUAR.getBackendUrl()) { showLogin({ hint: "Set the backend URL (gear, bottom-right) to continue." }); return; }
    try {
      SUAR._adminEmail = await SUAR.auth.verifyAdmin();
    } catch (e) {
      if (e.status === 403) { await SUAR.auth.signOut(true); showLogin({ error: "This account isn't authorized for the console." }); return; }
      if (e.status === 401) { await SUAR.auth.signOut(true); showLogin({ error: "Session expired. Please sign in again." }); return; }
      if (e.status === 503) { showLogin({ error: "Admin allowlist not configured on the server (ADMIN_EMAILS)." }); return; }
      showLogin({ error: e.message || "Can't reach the backend." }); return;
    }
    await showApp();
  }

  async function showApp() {
    document.body.classList.add("authed");
    document.getElementById("sidebar-user").textContent = SUAR._adminEmail || (await SUAR.auth.getUserEmail()) || "";
    startConnPolling();
    startIdleWatch();
    refreshCounts();
    route(currentRoute());
  }

  function currentRoute() {
    const r = (location.hash || "").replace(/^#\/?/, "");
    return ROUTES.includes(r) ? r : "dashboard";
  }

  async function route(name) {
    const view = document.getElementById("view");
    document.getElementById("page-title").textContent = TITLES[name] || "SUAR";
    document.querySelectorAll(".nav__item").forEach((n) =>
      n.classList.toggle("active", n.dataset.route === name)
    );
    document.body.classList.remove("nav-open");
    view.scrollTop = 0;
    view.innerHTML = SUAR.ui.spinner();
    try {
      await SUAR.views[name].render(view);
    } catch (e) {
      view.innerHTML = SUAR.ui.empty("Couldn't load this view", e.message || String(e));
      if (e.status !== 401) SUAR.ui.toast(e.message || "Load failed", "err");
    }
  }

  async function refreshCounts() {
    try {
      const s = await SUAR.api.get("/admin/stats");
      SUAR._stats = s;
      const map = {
        bundles: s.totalBundles, devices: s.deviceCount, geofences: s.geofenceCount,
        notices: s.noticeCount, content: s.contentCount, prep: s.prepPlanCount,
      };
      document.querySelectorAll("[data-count]").forEach((el) => {
        const v = map[el.dataset.count];
        el.textContent = (v === undefined || v === null) ? "" : v;
      });
    } catch (_) { /* counts are best-effort */ }
  }

  // --- Connection pill ---
  async function pingConn() {
    const el = document.getElementById("conn");
    const txt = document.getElementById("conn-text");
    if (!SUAR.getBackendUrl()) {
      el.className = "conn conn--bad"; txt.textContent = "No backend URL";
      return;
    }
    const ok = await SUAR.api.ping();
    el.className = "conn " + (ok ? "conn--ok" : "conn--bad");
    txt.textContent = ok ? "Backend online" : "Backend unreachable";
  }
  function startConnPolling() {
    pingConn();
    if (connTimer) clearInterval(connTimer);
    connTimer = setInterval(pingConn, 15000);
  }

  // --- Idle auto sign-out ---
  function resetIdle() {
    if (idleTimer) clearTimeout(idleTimer);
    idleTimer = setTimeout(async () => {
      await SUAR.auth.signOut(true);
      showLogin({ error: "Signed out after 20 minutes of inactivity." });
    }, IDLE_MS);
  }
  function startIdleWatch() {
    ["mousemove", "keydown", "click", "scroll", "touchstart"].forEach((ev) =>
      window.addEventListener(ev, resetIdle, { passive: true })
    );
    resetIdle();
  }
  function stopIdleWatch() {
    if (idleTimer) { clearTimeout(idleTimer); idleTimer = null; }
    ["mousemove", "keydown", "click", "scroll", "touchstart"].forEach((ev) =>
      window.removeEventListener(ev, resetIdle)
    );
  }

  // --- Backend URL config ---
  function updateUrlDot() {
    const dot = document.getElementById("url-dot");
    if (!dot) return;
    const set = !!SUAR.getBackendUrl();
    dot.className = "url-dot " + (set ? "url-dot--set" : "url-dot--unset");
  }

  function openUrlConfig() {
    const cur = SUAR.getBackendUrl();
    SUAR.ui.modal({
      title: "Backend server URL",
      body:
        '<p style="margin-top:0;color:var(--muted);font-size:13px">The ngrok (or LAN) URL where the SUAR FastAPI backend is running. The console reaches all data through it.</p>' +
        '<div class="field"><label for="url-in">URL</label><input class="input" id="url-in" placeholder="https://xxxx.ngrok-free.app" value="' + SUAR.ui.esc(cur) + '"></div>' +
        '<div class="login-note login-note--err" id="url-err" style="display:none"></div>',
      actions: [
        { label: "Test & Save", className: "btn--primary", onClick: async (close, btn) => {
            const v = document.getElementById("url-in").value.trim();
            const err = document.getElementById("url-err");
            err.style.display = "none";
            if (!/^https?:\/\//.test(v)) { err.textContent = "Must start with http:// or https://"; err.style.display = "block"; return; }
            btn.disabled = true; btn.textContent = "Testing…";
            SUAR.setBackendUrl(v);
            const ok = await SUAR.api.ping();
            btn.disabled = false; btn.textContent = "Test & Save";
            updateUrlDot();
            if (!ok) { err.textContent = "Saved, but /health didn't respond. Check the server + ngrok are up."; err.style.display = "block"; return; }
            SUAR.ui.toast("Backend connected", "ok");
            close();
            if (document.body.classList.contains("authed")) { startConnPolling(); refreshCounts(); }
            else { tryEnterApp(); }  // logged in but was waiting on the URL — enter now
          } },
      ],
    });
  }

  function init() {
    const emailEl = document.getElementById("login-email");
    const pwEl = document.getElementById("login-password");
    const emailErr = document.getElementById("login-email-err");
    const pwErr = document.getElementById("login-password-err");
    const mark = (inp, errEl, msg) => {
      if (msg) { inp.classList.add("invalid"); errEl.textContent = msg; errEl.style.display = "block"; return true; }
      inp.classList.remove("invalid"); errEl.style.display = "none"; return false;
    };
    // Clear a field's error as soon as the user edits it.
    emailEl.addEventListener("input", () => mark(emailEl, emailErr, ""));
    pwEl.addEventListener("input", () => mark(pwEl, pwErr, ""));

    document.getElementById("login-form").addEventListener("submit", async (e) => {
      e.preventDefault();
      const btn = document.getElementById("login-submit");
      const err = document.getElementById("login-error");
      err.style.display = "none";
      const email = emailEl.value.trim();
      let bad = mark(emailEl, emailErr,
        !email ? "Enter your email" : (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email) ? "That doesn't look like an email" : ""));
      bad = mark(pwEl, pwErr, !pwEl.value ? "Enter your password" : "") || bad;
      if (bad) return;
      btn.disabled = true; btn.textContent = "Signing in…";
      try {
        await SUAR.auth.signIn(email, pwEl.value);
        await tryEnterApp();
      } catch (ex) {
        err.textContent = ex.message || "Sign-in failed";
        err.style.display = "block"; err.className = "login-note login-note--err";
      } finally {
        btn.disabled = false; btn.textContent = "Sign in";
      }
    });

    document.getElementById("url-fab").addEventListener("click", openUrlConfig);
    document.getElementById("signout-btn").addEventListener("click", () => SUAR.auth.signOut());
    document.getElementById("menu-toggle").addEventListener("click", () =>
      document.body.classList.toggle("nav-open")
    );
    document.querySelectorAll(".nav__item").forEach((n) =>
      n.addEventListener("click", () => { location.hash = "/" + n.dataset.route; })
    );
    window.addEventListener("hashchange", () => {
      if (document.body.classList.contains("authed")) route(currentRoute());
    });

    updateUrlDot();
    tryEnterApp();
  }

  return { init, showLogin, showApp, route, refreshCounts };
})();

document.addEventListener("DOMContentLoaded", SUAR.app.init);
