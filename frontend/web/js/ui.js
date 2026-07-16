/* Shared UI helpers: formatting, toasts, modals/drawers, confirm. Views build
 * HTML strings and lean on these so each view file stays focused. */
window.SUAR = window.SUAR || {};

SUAR.ui = (function () {
  function esc(s) {
    if (s === null || s === undefined) return "";
    return String(s)
      .replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;").replace(/'/g, "&#39;");
  }

  function fmtDate(iso) {
    if (!iso) return "—";
    const d = new Date(iso);
    if (isNaN(d)) return "—";
    return d.toLocaleString(undefined, {
      year: "numeric", month: "short", day: "numeric",
      hour: "2-digit", minute: "2-digit",
    });
  }

  function fmtRelative(iso) {
    if (!iso) return "—";
    const diff = (Date.now() - new Date(iso)) / 1000;
    if (isNaN(diff)) return "—";
    if (diff < 60) return "just now";
    if (diff < 3600) return Math.floor(diff / 60) + "m ago";
    if (diff < 86400) return Math.floor(diff / 3600) + "h ago";
    return Math.floor(diff / 86400) + "d ago";
  }

  function fmtCoord(lat, lng) {
    if (lat === null || lat === undefined || lng === null || lng === undefined) return "—";
    const latNum = Number(lat), lngNum = Number(lng);
    if (!Number.isFinite(latNum) || !Number.isFinite(lngNum)) return "—";
    return latNum.toFixed(5) + ", " + lngNum.toFixed(5);
  }

  function truncId(id, n) {
    if (!id) return "—";
    n = n || 8;
    // Escaped here because every caller drops the result straight into
    // innerHTML — ids come from the UNAUTHENTICATED /sync endpoint, so an
    // attacker-crafted deviceId/bundleId would otherwise be stored XSS in
    // the admin console.
    return esc(id.length > n ? id.slice(0, n) + "…" : id);
  }

  function tierBadge(tier) {
    const t = tier || "None";
    return '<span class="badge badge--' + esc(t) + '">' + esc(t) + "</span>";
  }

  function severityBadge(sev) {
    return '<span class="badge badge--' + esc(sev) + '">' + esc(sev) + "</span>";
  }

  function spinner() { return '<div class="spinner"></div>'; }

  function empty(title, desc) {
    return '<div class="empty"><h3>' + esc(title) + "</h3><p>" + esc(desc || "") + "</p></div>";
  }

  // --- Toasts ---
  function toast(msg, type, ms) {
    const stack = document.getElementById("toast-stack");
    const t = document.createElement("div");
    t.className = "toast" + (type ? " toast--" + type : "");
    t.textContent = msg;
    stack.appendChild(t);
    const dur = ms != null ? ms : (type === "err" ? 5200 : 3000);
    setTimeout(() => {
      t.style.transition = "opacity .3s, transform .3s";
      t.style.opacity = "0";
      t.style.transform = "translateY(8px)";
      setTimeout(() => t.remove(), 320);
    }, dur);
  }

  // --- Click-to-copy ---
  // copyable(full, inner) wraps display HTML in a span that copies `full` (the
  // untruncated value) on click. One delegated listener below serves every such
  // span; it stops propagation so copying an ID inside a table row does NOT also
  // open that row's drawer.
  function copyable(full, inner, extra) {
    if (full === null || full === undefined || full === "") return inner != null ? inner : "—";
    const disp = inner != null ? inner : esc(String(full));
    return '<span class="copyable' + (extra ? " " + extra : "") + '" data-copy="' + esc(String(full)) + '" title="Click to copy">' + disp + "</span>";
  }
  function copy(text) {
    if (!text) return;
    const ok = () => toast("Copied to clipboard", "ok", 1100);
    if (navigator.clipboard && navigator.clipboard.writeText) {
      navigator.clipboard.writeText(text).then(ok).catch(() => fallbackCopy(text, ok));
    } else fallbackCopy(text, ok);
  }
  function fallbackCopy(text, done) {
    const ta = document.createElement("textarea");
    ta.value = text; ta.style.position = "fixed"; ta.style.opacity = "0";
    document.body.appendChild(ta); ta.select();
    try { document.execCommand("copy"); done(); } catch (_) { toast("Copy failed", "err"); }
    ta.remove();
  }
  // Capture phase: a copyable cell often sits inside a clickable table row.
  // Intercepting here (before the row's own bubble-phase handler) lets us copy
  // and stopPropagation so clicking an ID copies it WITHOUT also opening the
  // row's drawer.
  document.addEventListener("click", (e) => {
    const el = e.target.closest("[data-copy]");
    if (!el) return;
    e.stopPropagation();
    copy(el.getAttribute("data-copy"));
  }, true);

  // --- Pagination ---
  // Shared pager for any list view. State (page, pageSize) lives in the view;
  // pagerControls() renders the footer HTML and bindPager() wires it. Hidden
  // entirely when the list has 10 or fewer rows, for a cleaner UI.
  const PAGE_SIZES = [10, 50, 100, 200];
  function pageClamp(page, total, pageSize) {
    const pages = Math.max(1, Math.ceil(total / pageSize));
    return Math.min(Math.max(1, page), pages);
  }
  function pagerControls(total, page, pageSize) {
    if (total <= 10) return "";
    const pages = Math.max(1, Math.ceil(total / pageSize));
    page = pageClamp(page, total, pageSize);
    const from = (page - 1) * pageSize + 1, to = Math.min(total, page * pageSize);
    return '<div class="pager">' +
      '<span class="pager__info">' + from + "–" + to + " of " + total + "</span>" +
      '<span class="pager__spacer"></span>' +
      '<label class="pager__size">Rows <select class="select" data-pgsize>' +
        PAGE_SIZES.map((s) => '<option value="' + s + '"' + (s === pageSize ? " selected" : "") + ">" + s + "</option>").join("") +
      "</select></label>" +
      '<button class="btn btn--ghost btn--sm" data-pgprev' + (page <= 1 ? " disabled" : "") + ">‹ Prev</button>" +
      '<span class="pager__page">' + page + " / " + pages + "</span>" +
      '<button class="btn btn--ghost btn--sm" data-pgnext' + (page >= pages ? " disabled" : "") + ">Next ›</button>" +
    "</div>";
  }
  function bindPager(scope, total, page, pageSize, cb) {
    const pages = Math.max(1, Math.ceil(total / pageSize));
    page = pageClamp(page, total, pageSize);
    const sz = scope.querySelector("[data-pgsize]");
    if (sz) sz.addEventListener("change", (e) => cb(1, +e.target.value));
    const pv = scope.querySelector("[data-pgprev]");
    if (pv) pv.addEventListener("click", () => { if (page > 1) cb(page - 1, pageSize); });
    const nx = scope.querySelector("[data-pgnext]");
    if (nx) nx.addEventListener("click", () => { if (page < pages) cb(page + 1, pageSize); });
  }

  // --- Overlay (modal / drawer) ---
  function _mount(kind, opts) {
    const overlay = document.createElement("div");
    overlay.className = "overlay";
    const panel = document.createElement("div");
    panel.className = kind + (opts.wide ? " " + kind + "--wide" : "");
    panel.innerHTML =
      '<div class="' + kind + '__head"><h3>' + esc(opts.title || "") + '</h3>' +
      '<button class="icon-btn" data-close aria-label="Close"><svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><line x1="18" y1="6" x2="6" y2="18"/><line x1="6" y1="6" x2="18" y2="18"/></svg></button></div>' +
      '<div class="' + kind + '__body"></div>' +
      '<div class="' + kind + '__foot"></div>';
    overlay.appendChild(panel);
    document.body.appendChild(overlay);

    const body = panel.querySelector("." + kind + "__body");
    const foot = panel.querySelector("." + kind + "__foot");
    if (typeof opts.body === "string") body.innerHTML = opts.body; else if (opts.body) body.appendChild(opts.body);

    function close() {
      overlay.classList.remove("open");
      setTimeout(() => overlay.remove(), 200);
      document.removeEventListener("keydown", onKey);
      if (opts.onClose) opts.onClose();
    }
    function onKey(e) { if (e.key === "Escape") close(); }
    overlay.addEventListener("click", (e) => { if (e.target === overlay) close(); });
    panel.querySelector("[data-close]").addEventListener("click", close);
    document.addEventListener("keydown", onKey);

    (opts.actions || []).forEach((a) => {
      const b = document.createElement("button");
      b.className = "btn " + (a.className || "btn--ghost");
      b.textContent = a.label;
      b.addEventListener("click", () => a.onClick(close, b));
      foot.appendChild(b);
    });
    if (!opts.actions || !opts.actions.length) foot.style.display = "none";

    requestAnimationFrame(() => overlay.classList.add("open"));
    return { overlay, panel, body, foot, close };
  }

  const modal = (opts) => _mount("modal", opts);
  const drawer = (opts) => _mount("drawer", opts);

  function confirm(opts) {
    return new Promise((resolve) => {
      const m = modal({
        title: opts.title || "Confirm",
        body: '<p style="margin:0;color:var(--muted)">' + esc(opts.message || "") + "</p>",
        // Any close path (X button, Escape) must settle the promise — an
        // unresolved confirm left the caller awaiting forever.
        onClose: () => resolve(false),
        actions: [
          { label: opts.cancelLabel || "Cancel", className: "btn--ghost", onClick: (close) => { resolve(false); close(); } },
          { label: opts.confirmLabel || "Confirm", className: opts.danger ? "btn--danger" : "btn--primary", onClick: (close) => { resolve(true); close(); } },
        ],
      });
      m.overlay.addEventListener("click", (e) => { if (e.target === m.overlay) resolve(false); });
    });
  }

  return { esc, fmtDate, fmtRelative, fmtCoord, truncId, tierBadge, severityBadge, spinner, empty, toast, modal, drawer, confirm, copyable, copy, pagerControls, bindPager, pageClamp, PAGE_SIZES };
})();
