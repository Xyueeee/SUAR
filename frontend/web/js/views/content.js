/* Unified content editor — ONE editor + renderer for survival / first_aid /
 * prep. A doc is a tree of nodes: a `section` groups children and can show/tally
 * a %; a leaf is a checklist field (check/text/number) or a `guide` (pages of
 * blocks). Stored in `appdoc.structure`; the Flutter app renders this
 * identically, and the right-pane phone preview is an interactive mirror.
 * Both the "Guides & Tips" and "Prep Plans" nav routes use this same module. */
window.SUAR = window.SUAR || {};
SUAR.views = SUAR.views || {};

SUAR.views._docsEditor = (function () {
  const CAT_LABELS = { survival: "Survival", first_aid: "First Aid", preparation: "Preparation", prep: "Disaster Prep" };
  const SWATCHES = ["#1A1A1A", "#C0392B", "#E0A800", "#2E7D32", "#3E6FA8", "#6D28D9"];
  const TIERS = [{ v: 3, label: "Essential" }, { v: 2, label: "Recommended" }, { v: 1, label: "Optional" }];
  const KINDS = [["section", "Section"], ["check", "Checkbox"], ["text", "Text field"], ["number", "Number field"], ["guide", "Content (pages)"]];
  function tierVal(w) { const n = Number(w) || 0; return n >= 3 ? 3 : (n >= 2 ? 2 : 1); }

  function makeView(categories, opts) {
    opts = opts || {};
    const NOTICE = !!opts.notice;                       // announcements mode
    const EP = NOTICE ? "/admin/notices" : "/admin/docs";
    const PK = NOTICE ? "noticeid" : "docid";
    const STATUS = NOTICE ? "isactive" : "ispublished"; // "active" vs "published"
    const LEVELS = ["info", "advisory", "warning", "critical"];
    const lvlLabel = (v) => v ? v.charAt(0).toUpperCase() + v.slice(1) : "";
    let active = categories[0];
    let allRows = [], search = "", sortKey = NOTICE ? "updated" : "order";
    const selected = new Set();

    async function render(container) {
      const tabs = (!NOTICE && categories.length > 1)
        ? '<div class="tabs" id="d-tabs">' + categories.map((c) => '<div class="tab' + (c === active ? " active" : "") + '" data-cat="' + c + '">' + CAT_LABELS[c] + "</div>").join("") + "</div>"
        : "";
      const sortOpts = NOTICE
        ? ["updated|Recently updated", "title|Title A–Z", "status|Status"]
        : ["order|Manual order", "updated|Recently updated", "title|Title A–Z", "status|Status"];
      container.innerHTML =
        '<div class="view__head"><span class="eyebrow">' + (NOTICE ? "Broadcast announcements — shown in the app" : "One editor for tips & prep — shown offline in the app") + '</span><span class="spacer"></span>' +
        '<button class="btn btn--primary btn--sm" id="d-new">+ New ' + (NOTICE ? "notice" : (categories.length > 1 ? "guide" : "plan")) + "</button></div>" +
        tabs +
        '<div class="list-toolbar">' +
          '<input class="input" id="d-search" placeholder="Search title…" value="' + SUAR.ui.esc(search) + '" style="max-width:240px">' +
          '<select class="select" id="d-sort" style="max-width:175px">' +
            sortOpts.map((o) => { const p = o.split("|"); return '<option value="' + p[0] + '"' + (sortKey === p[0] ? " selected" : "") + ">" + p[1] + "</option>"; }).join("") +
          '</select><span class="spacer"></span>' +
          '<div class="bulkbar" id="d-bulk" style="display:none"><span class="muted" id="d-selcount"></span><button class="btn btn--ghost btn--sm" data-bulk="pub">Publish</button><button class="btn btn--ghost btn--sm" data-bulk="unpub">Unpublish</button><button class="btn btn--danger btn--sm" data-bulk="del">Delete</button></div>' +
        "</div>" +
        '<div class="card"><div class="table-wrap" id="d-table">' + SUAR.ui.spinner() + "</div></div>";
      document.getElementById("d-new").addEventListener("click", () => openEditor(null, active));
      container.querySelectorAll(".tab").forEach((t) => t.addEventListener("click", () => { active = t.dataset.cat; selected.clear(); render(container); }));
      document.getElementById("d-search").addEventListener("input", (e) => { search = e.target.value; renderTable(); });
      document.getElementById("d-sort").addEventListener("change", (e) => { sortKey = e.target.value; renderTable(); });
      document.querySelectorAll("[data-bulk]").forEach((b) => b.addEventListener("click", () => bulkAction(b.dataset.bulk)));
      await load();
    }

    async function load() {
      const wrap = document.getElementById("d-table");
      wrap.innerHTML = SUAR.ui.spinner();
      const all = await SUAR.api.get(EP);
      allRows = NOTICE ? all.slice() : all.filter((d) => d.category === active);
      selected.clear(); updateBulkBar();
      renderTable();
    }

    function visibleRows() {
      let rows = allRows.slice();
      const q = search.trim().toLowerCase();
      if (q) rows = rows.filter((d) => (d.title || "").toLowerCase().includes(q));
      rows.sort((a, b) => {
        if (sortKey === "order") return (a.orderindex || 0) - (b.orderindex || 0) || new Date(a.updatedat || 0) - new Date(b.updatedat || 0);
        if (sortKey === "title") return (a.title || "").localeCompare(b.title || "");
        if (sortKey === "status") return (b[STATUS] ? 1 : 0) - (a[STATUS] ? 1 : 0);
        return new Date(b.updatedat || 0) - new Date(a.updatedat || 0);
      });
      return rows;
    }

    function renderTable() {
      const wrap = document.getElementById("d-table");
      if (!wrap) return;
      const rows = visibleRows();
      if (!rows.length) { wrap.innerHTML = SUAR.ui.empty(search ? "No matches" : "Nothing here yet", search ? "Try a different search." : (NOTICE ? "Create a notice." : "Create a " + CAT_LABELS[active] + " doc.")); return; }
      const head = NOTICE
        ? '<th style="width:34px"><input type="checkbox" id="d-selall"></th><th>Title</th><th>Level</th><th>Updated</th><th>Active</th><th></th>'
        : '<th style="width:34px"><input type="checkbox" id="d-selall"></th><th>Title</th><th>Structure</th><th>Updated</th><th>Published</th><th></th>';
      wrap.innerHTML =
        '<table class="data"><thead><tr>' + head + '</tr></thead><tbody>' +
        rows.map((d) => {
          let mid;
          if (NOTICE) {
            mid = '<td>' + SUAR.ui.severityBadge(d.severity || "info") + "</td>";
          } else {
            const s = parseStruct(d.structure); const c = countNodes(s.nodes);
            mid = '<td class="muted">' + c.sections + " sec / " + c.items + " items" + (s.usePercent ? " · %" : "") + "</td>";
          }
          const acts = (NOTICE ? "" : '<button class="icon-btn" data-up title="Move up">↑</button><button class="icon-btn" data-down title="Move down">↓</button>') +
            '<button class="btn btn--ghost btn--sm" data-edit>Edit</button><button class="btn btn--danger btn--sm" data-del>Delete</button>';
          return "<tr>" +
            '<td><input type="checkbox" class="d-sel"' + (selected.has(d[PK]) ? " checked" : "") + "></td>" +
            '<td><b class="d-view">' + SUAR.ui.esc(d.title) + "</b></td>" +
            mid +
            '<td class="muted">' + SUAR.ui.fmtRelative(d.updatedat) + "</td>" +
            '<td><label class="switch switch--sm"><input type="checkbox" class="d-pubsw"' + (d[STATUS] ? " checked" : "") + '><span class="switch__track"></span></label></td>' +
            '<td class="cell-actions">' + acts + "</td></tr>";
        }).join("") + "</tbody></table>";
      const trs = wrap.querySelectorAll("tbody tr");
      rows.forEach((d, i) => {
        const tr = trs[i];
        const view = tr.querySelector(".d-view"); view.classList.add("row-link"); view.title = "Click to view"; view.addEventListener("click", () => openViewer(d));
        tr.querySelector(".d-sel").addEventListener("change", (e) => { e.target.checked ? selected.add(d[PK]) : selected.delete(d[PK]); updateBulkBar(); syncSelAll(); });
        tr.querySelector(".d-pubsw").addEventListener("change", async (e) => {
          const want = e.target.checked; const patch = {}; patch[STATUS] = want;
          try { await SUAR.api.patch(EP + "/" + encodeURIComponent(d[PK]), patch); d[STATUS] = want; SUAR.ui.toast("Saved", "ok"); SUAR.app.refreshCounts(); }
          catch (err) { e.target.checked = !want; SUAR.ui.toast(err.message, "err"); }
        });
        tr.querySelector("[data-edit]").addEventListener("click", () => openEditor(d, active));
        tr.querySelector("[data-del]").addEventListener("click", () => del(d));
        const up = tr.querySelector("[data-up]"); if (up) up.addEventListener("click", () => reorder(d, -1));
        const dn = tr.querySelector("[data-down]"); if (dn) dn.addEventListener("click", () => reorder(d, 1));
      });
      const selall = wrap.querySelector("#d-selall");
      selall.addEventListener("change", (e) => { rows.forEach((d) => e.target.checked ? selected.add(d.docid) : selected.delete(d.docid)); updateBulkBar(); renderTable(); });
      syncSelAll();
    }

    function syncSelAll() { const el = document.getElementById("d-selall"); if (!el) return; const rows = visibleRows(); el.checked = rows.length > 0 && rows.every((d) => selected.has(d[PK])); }
    function updateBulkBar() { const bar = document.getElementById("d-bulk"); if (!bar) return; bar.style.display = selected.size ? "flex" : "none"; const c = document.getElementById("d-selcount"); if (c) c.textContent = selected.size + " selected"; }

    async function bulkAction(act) {
      if (!selected.size) return;
      const ids = [...selected];
      if (act === "del") { const ok = await SUAR.ui.confirm({ title: "Delete " + ids.length + " item(s)?", message: "This can't be undone.", confirmLabel: "Delete", danger: true }); if (!ok) return; }
      try {
        for (const id of ids) {
          if (act === "del") { await SUAR.api.del(EP + "/" + encodeURIComponent(id)); }
          else { const p = {}; p[STATUS] = act === "pub"; await SUAR.api.patch(EP + "/" + encodeURIComponent(id), p); }
        }
        SUAR.ui.toast("Done (" + ids.length + ")", "ok"); selected.clear(); load(); SUAR.app.refreshCounts();
      } catch (e) { SUAR.ui.toast(e.message, "err"); load(); }
    }

    // Reorder a doc up/down; persists positions to orderindex so the app shows
    // the same order (it sorts published docs by orderindex).
    async function reorder(d, dir) {
      const rows = visibleRows();
      const i = rows.findIndex((r) => r.docid === d.docid);
      const j = i + dir;
      if (i < 0 || j < 0 || j >= rows.length) return;
      const tmp = rows[i]; rows[i] = rows[j]; rows[j] = tmp;
      try {
        await Promise.all(rows.map((r, idx) => SUAR.api.patch(EP + "/" + encodeURIComponent(r[PK]), { orderindex: idx })));
        load();
      } catch (e) { SUAR.ui.toast(e.message, "err"); }
    }

    async function del(d) {
      const ok = await SUAR.ui.confirm({ title: "Delete?", message: 'Remove "' + d.title + '"?', confirmLabel: "Delete", danger: true });
      if (!ok) return;
      try { await SUAR.api.del(EP + "/" + encodeURIComponent(d[PK])); SUAR.ui.toast("Deleted", "ok"); load(); SUAR.app.refreshCounts(); }
      catch (e) { SUAR.ui.toast(e.message, "err"); }
    }

    function countNodes(nodes, acc) {
      acc = acc || { sections: 0, items: 0 };
      (nodes || []).forEach((n) => { if (n.kind === "section") { acc.sections++; countNodes(n.children, acc); } else acc.items++; });
      return acc;
    }

    // ===================================================================== editor
    function openEditor(d, category) {
      const editing = !!d;
      const s = parseStruct(d ? d.structure : null);
      const state = {
        id: d ? d[PK] : null,
        category: NOTICE ? ((d && d.severity) || category || "info") : category,
        title: (d && d.title) || "",
        subtitle: (d && d.subtitle) || "",
        ispublished: NOTICE ? (d ? d.isactive !== false : true) : (d ? !!d.ispublished : false),
        usePercent: s.usePercent, percentText: s.percentText, nodes: s.nodes,
      };
      // A brand-new prep plan shows the overall % card by default.
      if (!d && !NOTICE && category === "prep") state.usePercent = true;
      let activeCe = null;
      const pv = { path: [], guide: null, gpage: 0, checks: new Set(), fields: new Map() }; // preview nav state

      const catControl = NOTICE
        ? '<select class="select" id="d-cat" style="max-width:150px">' + LEVELS.map((c) => '<option value="' + c + '"' + (state.category === c ? " selected" : "") + ">" + lvlLabel(c) + "</option>").join("") + "</select>"
        : (categories.length > 1
            ? '<select class="select" id="d-cat" style="max-width:150px">' + categories.map((c) => '<option value="' + c + '"' + (state.category === c ? " selected" : "") + ">" + CAT_LABELS[c] + "</option>").join("") + "</select>"
            : '<span class="chip">' + CAT_LABELS[state.category] + "</span>");

      const overlay = document.createElement("div");
      overlay.className = "editor-overlay";
      overlay.innerHTML =
        '<div class="editor"><div class="editor__bar">' +
          '<input class="input editor__title" id="d-title" placeholder="' + (NOTICE ? "Notice title" : "Document title") + '" value="' + SUAR.ui.esc(state.title) + '">' +
          catControl +
          (NOTICE ? '<input class="input" id="d-sub" placeholder="Subtitle (one line)" value="' + SUAR.ui.esc(state.subtitle) + '" style="flex:1;min-width:200px">' : "") +
          '<label class="switch switch--inline"><input type="checkbox" id="d-pub"' + (state.ispublished ? " checked" : "") + '><span class="switch__track"></span> ' + (NOTICE ? "Active" : "Published") + "</label>" +
          '<span class="spacer"></span>' +
          '<button class="btn btn--ghost btn--sm" id="d-cancel">Cancel</button>' +
          '<button class="btn btn--primary btn--sm" id="d-save">' + (editing ? "Save changes" : "Create") + "</button>" +
        '</div><div class="editor__main"><div class="editor__left">' +
          '<div class="docset">' +
            (NOTICE ? "" :
              '<label class="switch switch--inline"><input type="checkbox" id="d-pct"' + (state.usePercent ? " checked" : "") + '><span class="switch__track"></span> Show overall % card</label>' +
              '<input class="input" id="d-pcttext" placeholder="You are {p}% prepared:" value="' + SUAR.ui.esc(state.percentText) + '"' + (state.usePercent ? "" : ' style="display:none"') + ">") +
            '<span class="spacer"></span><button class="btn btn--ghost btn--sm" id="d-raw" title="Edit / copy the raw JSON">Raw JSON</button>' +
          '</div><div class="tree" id="d-tree"></div></div>' +
          '<div class="editor__right"><div class="phone-wrap"><div class="phone" id="d-preview"></div></div><div class="phone-note">Live preview — what the app shows</div></div>' +
        "</div></div>";
      document.body.appendChild(overlay);
      requestAnimationFrame(() => overlay.classList.add("open"));

      const treeEl = overlay.querySelector("#d-tree");
      const previewEl = overlay.querySelector("#d-preview");
      // Interactive phone preview — shared with the read-only viewer. Defined
      // here (before any handler references it) to avoid a const TDZ error.
      const renderPreview = mountPhone(previewEl, state, () => overlay.querySelector("#d-title").value, pv);
      // Editor is a DOM overlay, not a route — integrate with browser history so
      // the Back button (and Esc / Cancel) all close it consistently.
      let closed = false;
      const actuallyClose = () => { if (closed) return; closed = true; overlay.classList.remove("open"); setTimeout(() => overlay.remove(), 180); document.removeEventListener("keydown", onKey); window.removeEventListener("popstate", onPop); };
      const onPop = () => actuallyClose();
      const close = () => { if (closed) return; history.back(); }; // -> popstate -> actuallyClose
      const onKey = (e) => { if (e.key === "Escape" && !activeCe) close(); };
      document.addEventListener("keydown", onKey);
      history.pushState({ suarEditor: true }, "");
      window.addEventListener("popstate", onPop);
      overlay.querySelector("#d-cancel").addEventListener("click", async () => {
        if (await SUAR.ui.confirm({ title: "Discard changes?", message: "Any unsaved edits will be lost.", confirmLabel: "Discard", danger: true })) close();
      });
      overlay.querySelector("#d-save").addEventListener("click", save);
      overlay.querySelector("#d-title").addEventListener("input", renderPreview);
      const pctEl = overlay.querySelector("#d-pct");
      if (pctEl) pctEl.addEventListener("change", (e) => { state.usePercent = e.target.checked; overlay.querySelector("#d-pcttext").style.display = state.usePercent ? "" : "none"; renderPreview(); });
      const pctTextEl = overlay.querySelector("#d-pcttext");
      if (pctTextEl) pctTextEl.addEventListener("input", (e) => { state.percentText = e.target.value; renderPreview(); });

      // Advanced: edit / copy the raw JSON in place of the visual tree.
      let rawMode = false;
      overlay.querySelector("#d-raw").addEventListener("click", toggleRaw);
      function toggleRaw() {
        if (!rawMode) {
          rawMode = true;
          treeEl.innerHTML = '<textarea class="raw-editor" id="d-rawta" spellcheck="false"></textarea>';
          document.getElementById("d-rawta").value = JSON.stringify({ usePercent: state.usePercent, percentText: state.percentText, nodes: clean(state.nodes) }, null, 2);
          overlay.querySelector("#d-raw").textContent = "Apply & visual";
        } else {
          let parsed;
          try { parsed = JSON.parse(document.getElementById("d-rawta").value); }
          catch (e) { SUAR.ui.toast("Invalid JSON: " + e.message, "err"); return; }
          const s2 = parseStruct(parsed);
          state.usePercent = s2.usePercent; state.percentText = s2.percentText; state.nodes = s2.nodes;
          if (pctEl) pctEl.checked = state.usePercent;
          if (pctTextEl) { pctTextEl.style.display = state.usePercent ? "" : "none"; pctTextEl.value = state.percentText; }
          rawMode = false;
          overlay.querySelector("#d-raw").textContent = "Raw JSON";
          renderTree();
        }
        renderPreview();
      }

      // Scoped formatting: each text block carries its own toolbar; it acts on
      // the contenteditable being edited inside that block (event-delegated).
      treeEl.addEventListener("mousedown", (e) => {
        const btn = e.target.closest(".minibar button"); if (!btn) return;
        const bar = btn.closest(".minibar");
        // Only act if the focused editable belongs to this toolbar's block.
        if (!activeCe || bar.dataset.owner !== activeCe.dataset.owner) { e.preventDefault(); return; }
        e.preventDefault(); activeCe.focus();
        document.execCommand("styleWithCSS", false, true);
        if (btn.dataset.color) document.execCommand("foreColor", false, btn.dataset.color);
        else if (btn.dataset.cmd) document.execCommand(btn.dataset.cmd, false, null);
        syncCe(activeCe); renderPreview();
      });

      // ---- tree helpers (path "0.1.2") ----
      function nodeAt(path) { let arr = state.nodes, n = null; for (const s of path.split(".")) { n = arr[+s]; if (!n) return null; arr = n.children || []; } return n; }
      function parentArr(path) { const segs = path.split("."); const idx = +segs.pop(); let arr = state.nodes; for (const s of segs) arr = arr[+s].children; return { arr, idx }; }

      function renderTree() {
        treeEl.innerHTML = state.nodes.map((n, i) => nodeHtml(n, "" + i)).join("") +
          '<div class="tree-add"><button class="chip-btn" data-rootadd="section">+ Section</button><button class="chip-btn" data-rootadd="check">+ Checklist item</button><button class="chip-btn" data-rootadd="guide">+ Content</button></div>';
        bindTree();
      }

      function nodeHtml(n, path) {
        const acts = rowActs("act", "data-p='" + path + "'");
        const kindSel = '<select class="select kindsel" data-p="' + path + '">' + KINDS.map((k) => '<option value="' + k[0] + '"' + (n.kind === k[0] ? " selected" : "") + ">" + k[1] + "</option>").join("") + "</select>";
        const tier = n.kind === "guide" ? "" : (
          (Number(n.weight) || 0) <= 0
            ? '<button class="chip-btn weight-on" data-p="' + path + '" title="include in the %">+ weight</button>'
            : '<select class="select tiersel" data-p="' + path + '" title="importance (weight in the %)">' + TIERS.map((t) => '<option value="' + t.v + '"' + (tierVal(n.weight) === t.v ? " selected" : "") + ">" + t.label + "</option>").join("") + '</select><button class="icon-btn weight-off" data-p="' + path + '" title="exclude from the %">∅</button>'
        );
        const titles =
          '<input class="input nt-title" data-p="' + path + '" placeholder="Title" value="' + SUAR.ui.esc(n.title || "") + '">' +
          '<input class="input nt-sub" data-p="' + path + '" placeholder="Subtitle (small grey text, optional)" value="' + SUAR.ui.esc(n.subtitle || "") + '">';
        let body = "";
        if (n.kind === "section") {
          body =
            '<label class="mini"><input type="checkbox" class="nt-pct" data-p="' + path + '"' + (n.usePercent ? " checked" : "") + "> show % for this section</label>" +
            '<div class="node__children">' + (n.children || []).map((c, i) => nodeHtml(c, path + "." + i)).join("") +
              '<div class="tree-add"><button class="chip-btn" data-add="section" data-p="' + path + '">+ Sub-section</button><button class="chip-btn" data-add="check" data-p="' + path + '">+ Checkbox</button><button class="chip-btn" data-add="text" data-p="' + path + '">+ Text</button><button class="chip-btn" data-add="number" data-p="' + path + '">+ Number</button><button class="chip-btn" data-add="guide" data-p="' + path + '">+ Content</button></div></div>';
        } else if (n.kind === "guide") {
          body =
            '<label class="mini">Layout <select class="select nt-layout" data-p="' + path + '"><option value="steps"' + (n.layout !== "scroll" ? " selected" : "") + ">Steps (swipe)</option><option value=\"scroll\"" + (n.layout === "scroll" ? " selected" : "") + ">Scroll</option></select></label>" +
            '<div class="pages">' + (n.pages || []).map((p, pi) => pageHtml(p, path, pi)).join("") + '<button class="chip-btn add-wide" data-pageadd="' + path + '">+ Page</button></div>';
        }
        return '<div class="node node--' + n.kind + '"><div class="node__row"><span class="node__tag">' + (n.kind === "section" ? "▣" : n.kind === "guide" ? "▤" : "☑") + "</span>" + kindSel + titles + tier + acts + "</div>" + (body ? '<div class="node__body">' + body + "</div>" : "") + "</div>";
      }

      function pageHtml(p, path, pi) {
        return '<div class="pg"><div class="pg__head"><span class="pg__badge">Page ' + (pi + 1) + "</span>" +
          '<input class="input pg-title" data-p="' + path + '" data-pi="' + pi + '" placeholder="Page title (optional)" value="' + SUAR.ui.esc(p.title || "") + '">' +
          rowActs("pageact", "data-p='" + path + "' data-pi='" + pi + "'") + "</div>" +
          '<input class="input pg-sub" data-p="' + path + '" data-pi="' + pi + '" placeholder="Page subtitle (optional)" value="' + SUAR.ui.esc(p.subtitle || "") + '">' +
          '<div class="pg-blocks">' + (p.blocks || []).map((b, bi) => blockHtml(b, path, pi, bi)).join("") + "</div>" +
          '<div class="add-blocks">' + [["heading", "Heading"], ["paragraph", "Text"], ["bullets", "List"], ["image", "Image"], ["divider", "Divider"]].map((x) => '<button class="chip-btn" data-blockadd="' + x[0] + '" data-p="' + path + '" data-pi="' + pi + '">+ ' + x[1] + "</button>").join("") + "</div></div>";
      }

      function blockHtml(b, path, pi, bi) {
        const acts = rowActs("blockact", "data-p='" + path + "' data-pi='" + pi + "' data-bi='" + bi + "'");
        const D = 'data-p="' + path + '" data-pi="' + pi + '" data-bi="' + bi + '"';
        const owner = path + ":" + pi + ":" + bi;
        if (b.type === "heading")
          return blk("H" + (b.level || 2), '<select class="select blk-level" ' + D + ">" + [1, 2, 3].map((l) => '<option value="' + l + '"' + (b.level === l ? " selected" : "") + ">H" + l + "</option>").join("") + "</select>" + acts, miniBar(owner) + ce(path, pi, bi, null, b.runs, "Heading text", owner));
        if (b.type === "paragraph")
          return blk("¶", acts, miniBar(owner) + ce(path, pi, bi, null, b.runs, "Body text…", owner));
        if (b.type === "bullets") {
          const items = (b.items || []).map((it, ii) => '<div class="bullet-row">' + ce(path, pi, bi, ii, it, "List item", owner) + '<button class="icon-btn" data-bullet="del" ' + D + ' data-ii="' + ii + '">✕</button></div>').join("");
          return blk("•", '<label class="mini"><input type="checkbox" class="blk-ord" ' + D + (b.ordered ? " checked" : "") + "> numbered</label>" + acts, miniBar(owner) + '<div class="bullets">' + items + '<button class="chip-btn" data-bullet="add" ' + D + ">+ item</button></div>");
        }
        if (b.type === "image")
          return blk("🖼", acts, '<div class="img-block">' + (b.url ? '<img class="img-thumb" src="' + SUAR.ui.esc(b.url) + '">' : '<div class="img-thumb img-thumb--empty">No image</div>') + '<div class="img-fields"><button class="btn btn--ghost btn--sm" data-upload ' + D + '>Upload</button><input class="input blk-url" ' + D + ' placeholder="or paste URL" value="' + SUAR.ui.esc(b.url || "") + '"><input class="input blk-cap" ' + D + ' placeholder="Caption" value="' + SUAR.ui.esc(b.caption || "") + '"></div></div>');
        return blk("―", acts, '<span class="muted" style="font-size:12px">Divider line</span>');
      }
      function blk(tag, head, body) { return '<div class="blk"><div class="blk__row"><span class="blk__tag">' + tag + "</span>" + head + "</div>" + body + "</div>"; }
      function rowActs(act, data) { return '<div class="row-acts"><button class="icon-btn" data-' + act + '="up" ' + data + ' title="Move up">↑</button><button class="icon-btn" data-' + act + '="down" ' + data + ' title="Move down">↓</button><button class="icon-btn" data-' + act + '="dup" ' + data + ' title="Duplicate">⧉</button><button class="icon-btn" data-' + act + '="del" ' + data + ' style="color:var(--danger)" title="Delete">✕</button></div>'; }
      function miniBar(owner) {
        return '<div class="minibar" data-owner="' + owner + '">' +
          '<button class="mb" data-cmd="bold"><b>B</b></button><button class="mb" data-cmd="italic"><i>I</i></button><button class="mb" data-cmd="underline"><u>U</u></button><button class="mb" data-cmd="strikeThrough"><s>S</s></button>' +
          SWATCHES.map((c) => '<button class="mb mb-sw" data-color="' + c + '" style="background:' + c + '"></button>').join("") +
          '<button class="mb" data-cmd="removeFormat" title="clear">⌫</button></div>';
      }
      function ce(path, pi, bi, ii, runs, ph, owner) {
        return '<div class="ce" contenteditable="true" data-owner="' + owner + '" data-p="' + path + '" data-pi="' + pi + '" data-bi="' + bi + '"' + (ii !== null ? ' data-ii="' + ii + '"' : "") + ' data-ph="' + SUAR.ui.esc(ph) + '">' + runsToHtml(runs) + "</div>";
      }
      function blockOf(el) { return nodeAt(el.dataset.p).pages[+el.dataset.pi].blocks[+el.dataset.bi]; }
      function pageOf(el) { return nodeAt(el.dataset.p).pages[+el.dataset.pi]; }
      function syncCe(el) { const b = blockOf(el); const runs = htmlToRuns(el); if (el.dataset.ii != null) b.items[+el.dataset.ii] = runs; else b.runs = runs; }

      function bindTree() {
        const q = (s) => treeEl.querySelectorAll(s);
        q(".kindsel").forEach((s) => s.addEventListener("change", (e) => changeKind(e.target.dataset.p, e.target.value)));
        q(".tiersel").forEach((s) => s.addEventListener("change", (e) => { nodeAt(e.target.dataset.p).weight = Number(e.target.value) || 1; renderPreview(); }));
        q(".weight-off").forEach((b) => b.addEventListener("click", () => { nodeAt(b.dataset.p).weight = 0; renderTree(); renderPreview(); }));
        q(".weight-on").forEach((b) => b.addEventListener("click", () => { nodeAt(b.dataset.p).weight = 2; renderTree(); renderPreview(); }));
        q(".nt-title").forEach((i) => i.addEventListener("input", (e) => { nodeAt(e.target.dataset.p).title = e.target.value; renderPreview(); }));
        q(".nt-sub").forEach((i) => i.addEventListener("input", (e) => { nodeAt(e.target.dataset.p).subtitle = e.target.value; renderPreview(); }));
        q(".nt-pct").forEach((i) => i.addEventListener("change", (e) => { nodeAt(e.target.dataset.p).usePercent = e.target.checked; renderPreview(); }));
        q(".nt-layout").forEach((i) => i.addEventListener("change", (e) => { nodeAt(e.target.dataset.p).layout = e.target.value; renderPreview(); }));
        q("[data-rootadd]").forEach((b) => b.addEventListener("click", () => { state.nodes.push(newNode(b.dataset.rootadd)); renderTree(); renderPreview(); }));
        q("[data-add]").forEach((b) => b.addEventListener("click", () => { const n = nodeAt(b.dataset.p); n.children = n.children || []; n.children.push(newNode(b.dataset.add)); renderTree(); renderPreview(); }));
        q("[data-act]").forEach((b) => b.addEventListener("click", () => nodeAct(b.dataset.act, b.dataset.p)));
        q(".pg-title").forEach((i) => i.addEventListener("input", (e) => { pageOf(e.target).title = e.target.value; renderPreview(); }));
        q(".pg-sub").forEach((i) => i.addEventListener("input", (e) => { pageOf(e.target).subtitle = e.target.value; renderPreview(); }));
        q("[data-pageadd]").forEach((b) => b.addEventListener("click", () => { nodeAt(b.dataset.pageadd).pages.push({ title: "", subtitle: "", blocks: [] }); renderTree(); renderPreview(); }));
        q("[data-pageact]").forEach((b) => b.addEventListener("click", () => pageAct(b.dataset.pageact, b.dataset.p, +b.dataset.pi)));
        q("[data-blockadd]").forEach((b) => b.addEventListener("click", () => addBlock(b.dataset.p, +b.dataset.pi, b.dataset.blockadd)));
        q("[data-blockact]").forEach((b) => b.addEventListener("click", () => blockAct(b.dataset.blockact, b.dataset.p, +b.dataset.pi, +b.dataset.bi)));
        q(".blk-level").forEach((s) => s.addEventListener("change", (e) => { blockOf(e.target).level = +e.target.value; renderPreview(); }));
        q(".blk-ord").forEach((c) => c.addEventListener("change", (e) => { blockOf(e.target).ordered = e.target.checked; renderPreview(); }));
        q(".blk-url").forEach((i) => i.addEventListener("input", (e) => { blockOf(e.target).url = e.target.value; renderPreview(); }));
        q(".blk-cap").forEach((i) => i.addEventListener("input", (e) => { blockOf(e.target).caption = e.target.value; renderPreview(); }));
        q("[data-bullet]").forEach((b) => b.addEventListener("click", () => bulletAct(b.dataset.bullet, b.dataset.p, +b.dataset.pi, +b.dataset.bi, b.dataset.ii != null ? +b.dataset.ii : null)));
        q("[data-upload]").forEach((b) => b.addEventListener("click", () => uploadImage(b.dataset.p, +b.dataset.pi, +b.dataset.bi)));
        q(".ce").forEach((el) => { el.addEventListener("input", () => { syncCe(el); renderPreview(); }); el.addEventListener("focusin", () => { activeCe = el; }); });
      }

      function changeKind(path, kind) {
        const n = nodeAt(path); n.kind = kind;
        if (kind === "section") { n.children = n.children || []; delete n.pages; delete n.layout; }
        else if (kind === "guide") { n.pages = (n.pages && n.pages.length) ? n.pages : [{ title: "", subtitle: "", blocks: [] }]; n.layout = n.layout || "steps"; delete n.children; delete n.usePercent; }
        else { delete n.children; delete n.pages; delete n.layout; delete n.usePercent; }
        renderTree(); renderPreview();
      }
      function nodeAct(act, path) { const { arr, idx } = parentArr(path); if (act === "del") arr.splice(idx, 1); else if (act === "up" && idx > 0) arr.splice(idx - 1, 0, arr.splice(idx, 1)[0]); else if (act === "down" && idx < arr.length - 1) arr.splice(idx + 1, 0, arr.splice(idx, 1)[0]); else if (act === "dup") arr.push(JSON.parse(JSON.stringify(arr[idx]))); pv.path = []; pv.guide = null; renderTree(); renderPreview(); }
      function pageAct(act, path, pi) { const ps = nodeAt(path).pages; if (act === "del") { ps.splice(pi, 1); if (!ps.length) ps.push({ title: "", subtitle: "", blocks: [] }); } else if (act === "up" && pi > 0) ps.splice(pi - 1, 0, ps.splice(pi, 1)[0]); else if (act === "down" && pi < ps.length - 1) ps.splice(pi + 1, 0, ps.splice(pi, 1)[0]); else if (act === "dup") ps.push(JSON.parse(JSON.stringify(ps[pi]))); renderTree(); renderPreview(); }
      function addBlock(path, pi, type) { const b = type === "heading" ? { type, level: 2, runs: [] } : type === "paragraph" ? { type, runs: [] } : type === "bullets" ? { type, ordered: false, items: [[]] } : type === "image" ? { type, url: "", caption: "" } : { type: "divider" }; nodeAt(path).pages[pi].blocks.push(b); renderTree(); renderPreview(); }
      function blockAct(act, path, pi, bi) { const bs = nodeAt(path).pages[pi].blocks; if (act === "del") bs.splice(bi, 1); else if (act === "up" && bi > 0) bs.splice(bi - 1, 0, bs.splice(bi, 1)[0]); else if (act === "down" && bi < bs.length - 1) bs.splice(bi + 1, 0, bs.splice(bi, 1)[0]); else if (act === "dup") bs.splice(bi + 1, 0, JSON.parse(JSON.stringify(bs[bi]))); renderTree(); renderPreview(); }
      function bulletAct(act, path, pi, bi, ii) { const b = nodeAt(path).pages[pi].blocks[bi]; if (act === "add") b.items.push([]); else if (act === "del") { b.items.splice(ii, 1); if (!b.items.length) b.items.push([]); } renderTree(); renderPreview(); }
      function uploadImage(path, pi, bi) {
        const input = document.createElement("input"); input.type = "file"; input.accept = "image/*";
        input.onchange = async () => { const f = input.files && input.files[0]; if (!f) return; SUAR.ui.toast("Uploading…"); try { const r = await SUAR.api.upload("/admin/upload", f); nodeAt(path).pages[pi].blocks[bi].url = r.url; renderTree(); renderPreview(); SUAR.ui.toast("Uploaded", "ok"); } catch (e) { SUAR.ui.toast(e.message, "err"); } };
        input.click();
      }


      function save(e) {
        const btn = e.target;
        const title = overlay.querySelector("#d-title").value.trim();
        if (!title) { SUAR.ui.toast("Title required", "err"); return; }
        const structure = { usePercent: state.usePercent, percentText: state.percentText, nodes: clean(state.nodes) };
        const level = overlay.querySelector("#d-cat").value;
        let payload;
        // structure is the raw object, NOT stringified — SUAR.api.post/patch
        // JSON.stringify()s the whole payload once already (api.js); doing it
        // here too double-encoded it, so the jsonb column ended up holding a
        // JSON *string* instead of a real object/array.
        if (NOTICE) {
          payload = {
            title,
            subtitle: overlay.querySelector("#d-sub").value.trim(),
            severity: level,
            isactive: overlay.querySelector("#d-pub").checked,
            structure,
            body: "",
          };
        } else {
          payload = {
            category: categories.length > 1 ? level : state.category,
            title, structure,
            ispublished: overlay.querySelector("#d-pub").checked,
          };
        }
        btn.disabled = true;
        (editing ? SUAR.api.patch(EP + "/" + encodeURIComponent(state.id), payload) : SUAR.api.post(EP, payload))
          .then(() => { SUAR.ui.toast(editing ? "Saved" : "Created", "ok"); close(); load(); SUAR.app.refreshCounts(); })
          .catch((err) => { SUAR.ui.toast(err.message, "err"); btn.disabled = false; });
      }

      renderTree();
      renderPreview();
    }

    return { render };
  }

  // Shared interactive phone preview. [struct] is the live structure object
  // ({usePercent, percentText, nodes}); [pv] holds nav state. Returns render().
  function mountPhone(previewEl, struct, getTitle, pv) {
    const nodeAt = (path) => { let arr = struct.nodes, n = null; for (const s of path.split(".")) { n = arr[+s]; if (!n) return null; arr = n.children || []; } return n; };
    const levelNodes = () => { let arr = struct.nodes; for (const i of pv.path) arr = (arr[i].children || []); return arr; };
    const levelSection = () => { if (!pv.path.length) return null; let n = null, arr = struct.nodes; for (const i of pv.path) { n = arr[i]; arr = n.children || []; } return n; };
    const absPath = (idx) => pv.path.concat(idx).join(".");
    const pvTitle = (n, big) => '<span class="pv-tt"><span class="pv-t' + (big ? " pv-t--big" : "") + '">' + SUAR.ui.esc(n.title || "Untitled") + "</span>" + (n.subtitle ? '<span class="pv-sub">' + SUAR.ui.esc(n.subtitle) + "</span>" : "") + "</span>";

    function pvTop(n, ap) {
      if (n.kind === "section") { const rows = (n.children || []).map((c, i) => pvRow(c, ap + "." + i)).join(""); const p = n.usePercent ? Math.round(jsNodePct(n, ap, pv.checks, pv.fields)) : null; return '<div class="pv-card"><div class="pv-cardhead">' + pvTitle(n, true) + (p !== null ? '<span class="pv-pctnum">' + p + "%</span>" : "") + '</div>' + (p !== null ? '<div class="pv-pbar"><i style="width:' + p + '%"></i></div>' : "") + '<div class="pv-panel">' + (rows || '<div class="pv-row pv-muted">empty</div>') + "</div></div>"; }
      if (n.kind === "guide") return '<div class="pv-guide" data-pvguide="' + ap + '">' + pvTitle(n, true) + '<span class="pv-chev">›</span></div>';
      return '<div class="pv-panel">' + pvRow(n, ap) + "</div>";
    }
    function pvRow(n, ap) {
      if (n.kind === "section") { const p = n.usePercent ? Math.round(jsNodePct(n, ap, pv.checks, pv.fields)) : null; return '<div class="pv-row pv-tap" data-pvsec="' + ap + '">' + pvTitle(n) + (p !== null ? '<span class="pv-pctnum">' + p + "%</span>" : "") + '<span class="pv-chev">›</span></div>'; }
      if (n.kind === "guide") return '<div class="pv-row pv-tap" data-pvguide="' + ap + '">' + pvTitle(n) + '<span class="pv-chev">›</span></div>';
      if (n.kind === "text" || n.kind === "number") {
        const val = pv.fields.get(ap) || "";
        return '<div class="pv-row pv-field">' + pvTitle(n) +
          '<input class="pv-fieldinput" type="' + (n.kind === "number" ? "number" : "text") + '" placeholder="Tap to fill in" data-pvfield="' + ap + '" value="' + SUAR.ui.esc(val) + '">' +
          "</div>";
      }
      const on = pv.checks.has(ap);
      return '<div class="pv-row pv-tap" data-pvcheck="' + ap + '"><span class="pv-check' + (on ? " on" : "") + '">' + (on ? "✓" : "") + "</span>" + pvTitle(n) + "</div>";
    }
    function pvBlock(b) {
      if (b.type === "heading") return '<div class="pv-h pv-h' + (b.level || 2) + '">' + runsToHtml(b.runs) + "</div>";
      if (b.type === "paragraph") return '<p class="pv-p">' + runsToHtml(b.runs) + "</p>";
      if (b.type === "bullets") { const t = b.ordered ? "ol" : "ul"; return "<" + t + ' class="pv-list">' + (b.items || []).map((it) => "<li>" + runsToHtml(it) + "</li>").join("") + "</" + t + ">"; }
      if (b.type === "image") return b.url ? '<img class="pv-img" src="' + SUAR.ui.esc(b.url) + '">' + (b.caption ? '<div class="pv-cap">' + SUAR.ui.esc(b.caption) + "</div>" : "") : '<div class="pv-img pv-img--empty">image</div>';
      if (b.type === "divider") return '<hr class="pv-hr">';
      return "";
    }
    function renderGuide() {
      const g = nodeAt(pv.guide); if (!g || !g.pages) { pv.guide = null; return render(); }
      const pages = g.pages; if (pv.gpage >= pages.length) pv.gpage = pages.length - 1; if (pv.gpage < 0) pv.gpage = 0;
      const renderPage = (p) => (p.title ? '<div class="pv-gtitle">' + SUAR.ui.esc(p.title) + "</div>" : "") + (p.subtitle ? '<div class="pv-gsub">' + SUAR.ui.esc(p.subtitle) + "</div>" : "") + (p.blocks || []).map(pvBlock).join("");
      let body;
      if (g.layout === "scroll") body = pages.map((p) => '<div class="pv-gpage">' + renderPage(p) + "</div>").join('<hr class="pv-sep">');
      else body = '<div class="pv-gpbar"><i style="width:' + Math.round((pv.gpage + 1) / pages.length * 100) + '%"></i></div><div class="pv-gpage">' + renderPage(pages[pv.gpage]) + "</div>" + '<div class="pv-nav"><button class="pv-navbtn" data-pvprev' + (pv.gpage === 0 ? " disabled" : "") + ">‹ Prev</button><span class=\"pv-dots\">" + pages.map((p, i) => '<span class="pv-dot' + (i === pv.gpage ? " on" : "") + '"></span>').join("") + '</span><button class="pv-navbtn" data-pvnext' + (pv.gpage >= pages.length - 1 ? " disabled" : "") + ">Next ›</button></div>";
      previewEl.innerHTML = '<div class="pv-status"><span>9:41</span><span class="pv-batt" aria-hidden="true"></span></div><div class="pv-appbar"><button class="pv-back" data-pvexit>‹</button><span>' + SUAR.ui.esc(g.title || "Guide") + '</span></div><div class="pv-body">' + body + "</div>";
      bind();
    }
    function render() {
      if (pv.guide) return renderGuide();
      let appbar = getTitle() || "Title", body = "", back = "";
      const sec = levelSection();
      if (sec) { appbar = sec.title || "Section"; back = '<button class="pv-back" data-pvback>‹</button>'; }
      if (!pv.path.length && struct.usePercent) {
        const pct = Math.round(jsOverall(struct.nodes, pv.checks, pv.fields));
        body += '<div class="pv-card"><div class="pv-ptext">' + SUAR.ui.esc((struct.percentText || "You are {p}%").replace("{p}", pct)) + '</div><div class="pv-pbar"><i style="width:' + pct + '%"></i></div></div>';
      }
      if (sec && sec.subtitle) body += '<div class="pv-secsub">' + SUAR.ui.esc(sec.subtitle) + "</div>";
      if (sec && sec.usePercent) { const p = Math.round(jsNodePct(sec, pv.path.join("."), pv.checks, pv.fields)); body += '<div class="pv-pbar pv-pbar--lg"><i style="width:' + p + '%"></i></div><div class="pv-pnote">' + p + "% complete</div>"; }
      const nodes = levelNodes();
      body += sec ? '<div class="pv-panel">' + (nodes.length ? nodes.map((n, i) => pvRow(n, absPath(i))).join("") : '<div class="pv-row pv-muted">empty</div>') + "</div>"
                  : (nodes.length ? nodes.map((n, i) => pvTop(n, absPath(i))).join("") : '<p class="pv-empty">Nothing to preview yet.</p>');
      previewEl.innerHTML = '<div class="pv-status"><span>9:41</span><span class="pv-batt" aria-hidden="true"></span></div><div class="pv-appbar">' + back + "<span>" + SUAR.ui.esc(appbar) + "</span></div><div class=\"pv-body\">" + body + "</div>";
      bind();
    }
    function bind() {
      const q = (s) => previewEl.querySelectorAll(s);
      q("[data-pvsec]").forEach((el) => el.addEventListener("click", () => { pv.path = el.dataset.pvsec.split(".").map(Number); pv.guide = null; render(); }));
      q("[data-pvguide]").forEach((el) => el.addEventListener("click", () => { pv.guide = el.dataset.pvguide; pv.gpage = 0; render(); }));
      q("[data-pvcheck]").forEach((el) => el.addEventListener("click", () => { const p = el.dataset.pvcheck; pv.checks.has(p) ? pv.checks.delete(p) : pv.checks.add(p); render(); }));
      // "change" (not "input") — a full render() rebuilds the DOM, which would
      // steal focus/cursor position on every keystroke; firing on blur/Enter
      // instead still updates the % roll-up once the admin is done typing.
      q("[data-pvfield]").forEach((el) => el.addEventListener("change", () => { pv.fields.set(el.dataset.pvfield, el.value); render(); }));
      const back = previewEl.querySelector("[data-pvback]"); if (back) back.addEventListener("click", () => { pv.path.pop(); render(); });
      const exit = previewEl.querySelector("[data-pvexit]"); if (exit) exit.addEventListener("click", () => { pv.guide = null; render(); });
      const pp = previewEl.querySelector("[data-pvprev]"); if (pp) pp.addEventListener("click", () => { pv.gpage--; render(); });
      const pn = previewEl.querySelector("[data-pvnext]"); if (pn) pn.addEventListener("click", () => { pv.gpage++; render(); });
    }
    return render;
  }

  // Read-only viewer (opened by clicking a list row).
  function openViewer(doc) {
    const struct = parseStruct(doc.structure);
    const pv = { path: [], guide: null, gpage: 0, checks: new Set() };
    const overlay = document.createElement("div");
    overlay.className = "editor-overlay";
    overlay.innerHTML =
      '<div class="viewer"><div class="viewer__bar"><span class="viewer__title">' + SUAR.ui.esc(doc.title) + '</span>' +
      '<span class="chip">' + SUAR.ui.esc(CAT_LABELS[doc.category] || doc.category) + '</span><span class="spacer"></span>' +
      '<button class="btn btn--ghost btn--sm" id="v-close">Close</button></div>' +
      '<div class="viewer__body"><div class="phone-wrap"><div class="phone" id="v-phone"></div></div>' +
      '<div class="phone-note">Read-only preview — what the app shows</div></div></div>';
    document.body.appendChild(overlay);
    requestAnimationFrame(() => overlay.classList.add("open"));
    let closed = false;
    const actuallyClose = () => { if (closed) return; closed = true; overlay.classList.remove("open"); setTimeout(() => overlay.remove(), 180); document.removeEventListener("keydown", onKey); window.removeEventListener("popstate", onPop); };
    const onPop = () => actuallyClose();
    const close = () => { if (closed) return; history.back(); };
    const onKey = (e) => { if (e.key === "Escape") close(); };
    document.addEventListener("keydown", onKey);
    history.pushState({ suarViewer: true }, "");
    window.addEventListener("popstate", onPop);
    overlay.querySelector("#v-close").addEventListener("click", close);
    overlay.addEventListener("click", (e) => { if (e.target === overlay) close(); });
    mountPhone(overlay.querySelector("#v-phone"), struct, () => doc.title, pv)();
  }

  // ===================================================================== helpers
  function parseStruct(structure) {
    let d = structure;
    if (typeof structure === "string") { try { d = JSON.parse(structure); } catch (e) { d = null; } }
    if (!d || typeof d !== "object") d = {};
    return { usePercent: d.usePercent === true, percentText: d.percentText || "You are {p}% prepared for an emergency:", nodes: Array.isArray(d.nodes) ? d.nodes.map(normNode).filter(Boolean) : [] };
  }
  function normNode(n) {
    if (!n) return null;
    const kind = ["section", "check", "text", "number", "guide"].includes(n.kind) ? n.kind : "section";
    const o = { title: n.title || "", subtitle: n.subtitle || "", kind, weight: Number(n.weight) || 1 };
    if (kind === "section") { o.usePercent = n.usePercent === true; o.children = Array.isArray(n.children) ? n.children.map(normNode).filter(Boolean) : []; }
    else if (kind === "guide") { o.layout = n.layout === "scroll" ? "scroll" : "steps"; o.pages = Array.isArray(n.pages) && n.pages.length ? n.pages.map((p) => ({ title: p.title || "", subtitle: p.subtitle || "", blocks: Array.isArray(p.blocks) ? p.blocks : [] })) : [{ title: "", subtitle: "", blocks: [] }]; }
    return o;
  }
  function newNode(kind) { const o = { title: "", subtitle: "", kind, weight: 2 }; if (kind === "section") { o.usePercent = false; o.children = []; } else if (kind === "guide") { o.layout = "steps"; o.pages = [{ title: "", subtitle: "", blocks: [{ type: "paragraph", runs: [] }] }]; } return o; }
  function clean(nodes) {
    return (nodes || []).map((n) => {
      const o = { title: n.title || "", kind: n.kind, weight: Number(n.weight) || 1 };
      if (n.subtitle) o.subtitle = n.subtitle;
      if (n.kind === "section") { if (n.usePercent) o.usePercent = true; o.children = clean(n.children); }
      else if (n.kind === "guide") { o.layout = n.layout === "scroll" ? "scroll" : "steps"; o.pages = (n.pages || []).map((p) => { const pp = { blocks: p.blocks || [] }; if (p.title) pp.title = p.title; if (p.subtitle) pp.subtitle = p.subtitle; return pp; }); }
      return o;
    });
  }

  // preview roll-up (mirrors app DocRollup). Text/number fields count as
  // "done" once they hold a non-empty value, same as the app's DocController
  // (checkboxes use the checks set; text/number use the fields map).
  function jsFrac(n, path, checks, fields) {
    if (n.kind === "guide") return null;
    if (n.kind === "text" || n.kind === "number") return (fields && (fields.get(path) || "").toString().trim()) ? 1 : 0;
    if (n.kind !== "section") return checks.has(path) ? 1 : 0;
    return jsChildFrac(n.children || [], path, checks, fields);
  }
  function jsChildFrac(kids, path, checks, fields) {
    let ws = 0, acc = 0;
    kids.forEach((c, i) => { const p = path ? path + "." + i : "" + i; const f = jsFrac(c, p, checks, fields); if (f === null) return; const w = (+c.weight > 0 ? +c.weight : 0); ws += w; acc += w * f; });
    return ws <= 0 ? null : acc / ws;
  }
  function jsOverall(nodes, checks, fields) { const f = jsChildFrac(nodes, "", checks, fields); return f === null ? 0 : f * 100; }
  function jsNodePct(n, path, checks, fields) { const f = jsFrac(n, path, checks, fields); return f === null ? 0 : f * 100; }

  function runsToHtml(runs) {
    return (runs || []).map((r) => { let t = SUAR.ui.esc(r.text || "").replace(/\n/g, "<br>"); if (r.color) t = '<span style="color:' + SUAR.ui.esc(r.color) + '">' + t + "</span>"; if (r.strike) t = "<s>" + t + "</s>"; if (r.underline) t = "<u>" + t + "</u>"; if (r.italic) t = "<i>" + t + "</i>"; if (r.bold) t = "<b>" + t + "</b>"; return t; }).join("");
  }
  function htmlToRuns(root) {
    const runs = [];
    (function walk(node, fmt) {
      node.childNodes.forEach((ch) => {
        if (ch.nodeType === 3) { if (ch.nodeValue) runs.push({ text: ch.nodeValue, bold: !!fmt.bold, italic: !!fmt.italic, underline: !!fmt.underline, strike: !!fmt.strike, color: fmt.color || null }); return; }
        if (ch.nodeType !== 1) return;
        const tag = ch.tagName.toLowerCase();
        if (tag === "br") { runs.push({ text: "\n" }); return; }
        const f = { ...fmt };
        if (tag === "b" || tag === "strong") f.bold = true; if (tag === "i" || tag === "em") f.italic = true; if (tag === "u") f.underline = true; if (tag === "s" || tag === "strike" || tag === "del") f.strike = true;
        const st = ch.style;
        if (st) { if (st.fontWeight === "bold" || parseInt(st.fontWeight, 10) >= 600) f.bold = true; if (st.fontStyle === "italic") f.italic = true; const dec = st.textDecorationLine || st.textDecoration || ""; if (dec.includes("underline")) f.underline = true; if (dec.includes("line-through")) f.strike = true; if (st.color) f.color = rgbToHex(st.color) || f.color; }
        if (ch.getAttribute && ch.getAttribute("color")) f.color = ch.getAttribute("color");
        if ((tag === "div" || tag === "p") && runs.length > 0) runs.push({ text: "\n" });
        walk(ch, f);
      });
    })(root, {});
    return mergeRuns(runs);
  }
  function mergeRuns(runs) {
    const out = [];
    for (const r of runs) { if (!r.text) continue; const p = out[out.length - 1]; if (p && !!p.bold === !!r.bold && !!p.italic === !!r.italic && !!p.underline === !!r.underline && !!p.strike === !!r.strike && (p.color || null) === (r.color || null)) p.text += r.text; else out.push({ ...r }); }
    return out.map((r) => { const o = { text: r.text }; if (r.bold) o.bold = true; if (r.italic) o.italic = true; if (r.underline) o.underline = true; if (r.strike) o.strike = true; if (r.color) o.color = r.color; return o; });
  }
  function rgbToHex(c) { if (!c) return null; if (c[0] === "#") return c.toUpperCase(); const m = c.match(/rgba?\((\d+),\s*(\d+),\s*(\d+)/i); if (!m) return null; const h = (n) => (+n).toString(16).padStart(2, "0"); return ("#" + h(m[1]) + h(m[2]) + h(m[3])).toUpperCase(); }

  return { makeView };
})();

// Guides & Tips = survival + first aid (NO preparation). Prep Plans = disaster prep.
SUAR.views.content = SUAR.views._docsEditor.makeView(["survival", "first_aid"]);
SUAR.views.prep = SUAR.views._docsEditor.makeView(["prep"]);
// Notices use the SAME editor + renderer; the category dropdown becomes the
// level (info/advisory/warning/critical), saved to /admin/notices.
SUAR.views.notices = SUAR.views._docsEditor.makeView(["info", "advisory", "warning", "critical"], { notice: true });
