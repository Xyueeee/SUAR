/* Prep Plans: admin authors a nested "emergency preparedness" template — groups
 * (sections / kits) containing items, arbitrarily nested. Each node has a
 * weight; completion of an item grants its share of the whole, rolled up
 * through parent groups. The per-user fill-state + live counter lives in the
 * app (later increment); here we author the structure and preview the weight
 * distribution.
 *
 * Tree node: { id, title, type:"group"|"item", weight, fieldType?, children:[] }
 */
window.SUAR = window.SUAR || {};
SUAR.views = SUAR.views || {};

SUAR.views.prep = (function () {
  let plans = [];
  let state = [];        // working copy of the structure being edited
  let treeEl = null;

  function genId() { return "n" + Math.random().toString(36).slice(2, 9); }

  async function render(container) {
    container.innerHTML =
      '<div class="view__head"><span class="eyebrow">Interactive preparedness templates</span><span class="spacer"></span>' +
      '<button class="btn btn--primary btn--sm" id="p-new">+ New plan</button></div>' +
      '<div class="card"><div class="table-wrap" id="p-table">' + SUAR.ui.spinner() + "</div></div>";
    document.getElementById("p-new").addEventListener("click", () => openEditor(null));
    await load();
  }

  async function load() {
    const wrap = document.getElementById("p-table");
    wrap.innerHTML = SUAR.ui.spinner();
    plans = await SUAR.api.get("/admin/prep-plans");
    if (!plans.length) { wrap.innerHTML = SUAR.ui.empty("No prep plans", "Create one — e.g. an emergency supply pack checklist."); return; }
    wrap.innerHTML =
      '<table class="data"><thead><tr><th>Title</th><th>Sections</th><th>Items</th><th>Status</th><th>Ver.</th><th>Updated</th><th></th></tr></thead><tbody>' +
      plans.map((p) => {
        const counts = countNodes(p.structure || []);
        return "<tr>" +
          "<td><b>" + SUAR.ui.esc(p.title) + "</b></td>" +
          '<td class="mono-cell">' + counts.groups + "</td>" +
          '<td class="mono-cell">' + counts.items + "</td>" +
          "<td>" + (p.ispublished ? '<span class="chip chip--on">published</span>' : '<span class="chip chip--off">draft</span>') + "</td>" +
          '<td class="mono-cell">v' + (p.version ?? 1) + "</td>" +
          '<td class="muted">' + SUAR.ui.fmtRelative(p.updatedat) + "</td>" +
          '<td class="cell-actions"><button class="btn btn--ghost btn--sm" data-edit>Edit</button><button class="btn btn--danger btn--sm" data-del>Delete</button></td>' +
          "</tr>";
      }).join("") + "</tbody></table>";
    plans.forEach((p, i) => {
      const tr = wrap.querySelectorAll("tbody tr")[i];
      tr.querySelector("[data-edit]").addEventListener("click", () => openEditor(p));
      tr.querySelector("[data-del]").addEventListener("click", () => del(p));
    });
  }

  function countNodes(nodes, acc) {
    acc = acc || { groups: 0, items: 0 };
    nodes.forEach((n) => {
      if (n.type === "group") { acc.groups++; countNodes(n.children || [], acc); }
      else acc.items++;
    });
    return acc;
  }

  // --- Percent roll-up ---
  function computePercents(nodes, share, out) {
    const sum = nodes.reduce((a, n) => a + (Number(n.weight) || 0), 0) || 1;
    nodes.forEach((n) => {
      const s = share * ((Number(n.weight) || 0) / sum);
      out[n.id] = s;
      if (n.type === "group" && n.children && n.children.length) computePercents(n.children, s, out);
    });
    return out;
  }

  // --- Tree rendering ---
  function renderTree() {
    const pct = computePercents(state, 100, {});
    treeEl.innerHTML = state.length ? state.map((n) => nodeHtml(n, pct)).join("") : emptyTreeHtml();
    bindTree();
  }

  function emptyTreeHtml() {
    return '<div class="empty" style="padding:30px"><h3>Empty plan</h3><p>Add a section to begin (e.g. "Emergency Supply Pack").</p></div>';
  }

  function nodeHtml(n, pct) {
    const isGroup = n.type === "group";
    const share = (pct[n.id] || 0).toFixed(1);
    const fieldSel = isGroup ? "" :
      '<select class="select fieldtype" data-id="' + n.id + '" style="width:auto;padding:5px 8px">' +
        ["checkbox", "text", "number"].map((f) => '<option value="' + f + '"' + (n.fieldType === f ? " selected" : "") + ">" + f + "</option>").join("") +
      "</select>";
    const adders = isGroup
      ? '<button class="btn btn--ghost btn--sm" data-act="add-group" data-id="' + n.id + '">+ Sub-section</button>' +
        '<button class="btn btn--ghost btn--sm" data-act="add-item" data-id="' + n.id + '">+ Item</button>'
      : "";
    const children = isGroup
      ? '<div class="tree-node__children" data-children="' + n.id + '">' + (n.children || []).map((c) => nodeHtml(c, pct)).join("") + "</div>"
      : "";

    return (
      '<div class="tree-node ' + (isGroup ? "tree-node--group" : "") + '" data-node="' + n.id + '">' +
        '<div class="tree-node__row">' +
          '<span class="tree-node__handle">' + (isGroup ? folderIcon() : dotIcon()) + "</span>" +
          '<input class="input tree-title" data-id="' + n.id + '" value="' + SUAR.ui.esc(n.title || "") + '" placeholder="' + (isGroup ? "Section name" : "Item name") + '" style="flex:1">' +
          fieldSel +
          '<label class="tree-node__meta">weight<input class="input weight-input" type="number" min="0" step="1" data-id="' + n.id + '" value="' + (n.weight ?? 1) + '"></label>' +
          '<span class="tree-node__pct" title="share of the whole plan">' + share + "%</span>" +
          '<div class="tree-node__actions">' + adders +
            '<button class="icon-btn" data-act="up" data-id="' + n.id + '" title="Move up">↑</button>' +
            '<button class="icon-btn" data-act="down" data-id="' + n.id + '" title="Move down">↓</button>' +
            '<button class="icon-btn" data-act="del" data-id="' + n.id + '" title="Delete" style="color:var(--danger)">✕</button>' +
          "</div>" +
        "</div>" +
        children +
      "</div>"
    );
  }

  function folderIcon() { return '<svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><path d="M22 19a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h5l2 3h9a2 2 0 0 1 2 2z"/></svg>'; }
  function dotIcon() { return '<svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><circle cx="12" cy="12" r="3"/></svg>'; }

  // --- Tree mutation helpers ---
  function find(id, nodes, parent) {
    nodes = nodes || state;
    for (let i = 0; i < nodes.length; i++) {
      if (nodes[i].id === id) return { node: nodes[i], arr: nodes, idx: i, parent };
      if (nodes[i].children) {
        const r = find(id, nodes[i].children, nodes[i]);
        if (r) return r;
      }
    }
    return null;
  }

  function bindTree() {
    treeEl.querySelectorAll(".tree-title").forEach((inp) =>
      inp.addEventListener("input", (e) => { const r = find(e.target.dataset.id); if (r) r.node.title = e.target.value; })
    );
    treeEl.querySelectorAll(".weight-input").forEach((inp) =>
      inp.addEventListener("change", (e) => { const r = find(e.target.dataset.id); if (r) { r.node.weight = Number(e.target.value) || 0; renderTree(); } })
    );
    treeEl.querySelectorAll(".fieldtype").forEach((sel) =>
      sel.addEventListener("change", (e) => { const r = find(e.target.dataset.id); if (r) r.node.fieldType = e.target.value; })
    );
    treeEl.querySelectorAll("[data-act]").forEach((btn) =>
      btn.addEventListener("click", (e) => act(btn.dataset.act, btn.dataset.id))
    );
  }

  function act(action, id) {
    const r = find(id);
    if (!r) return;
    if (action === "del") { r.arr.splice(r.idx, 1); }
    else if (action === "up" && r.idx > 0) { r.arr.splice(r.idx - 1, 0, r.arr.splice(r.idx, 1)[0]); }
    else if (action === "down" && r.idx < r.arr.length - 1) { r.arr.splice(r.idx + 1, 0, r.arr.splice(r.idx, 1)[0]); }
    else if (action === "add-group") { r.node.children = r.node.children || []; r.node.children.push(newNode("group")); }
    else if (action === "add-item") { r.node.children = r.node.children || []; r.node.children.push(newNode("item")); }
    renderTree();
  }

  function newNode(type) {
    const n = { id: genId(), title: "", type, weight: 1 };
    if (type === "group") n.children = [];
    else n.fieldType = "checkbox";
    return n;
  }

  // ensure every node has an id (older saved plans / hand-edited JSON)
  function ensureIds(nodes) {
    nodes.forEach((n) => { if (!n.id) n.id = genId(); if (n.children) ensureIds(n.children); });
    return nodes;
  }

  function openEditor(p) {
    const editing = !!p;
    p = p || {};
    state = ensureIds(JSON.parse(JSON.stringify(p.structure || [])));

    const m = SUAR.ui.modal({
      wide: true,
      title: editing ? "Edit prep plan" : "New prep plan",
      body:
        '<div class="field"><label>Plan title</label><input class="input" id="p-title" placeholder="e.g. Household Emergency Readiness" value="' + SUAR.ui.esc(p.title || "") + '"></div>' +
        '<div style="display:flex;gap:10px;margin:6px 0 14px"><button class="btn btn--ghost btn--sm" id="p-add-sec">+ Section</button><button class="btn btn--ghost btn--sm" id="p-add-item">+ Loose item</button>' +
          '<span class="spacer" style="flex:1"></span><span class="muted" style="font-size:12px;align-self:center">Completing an item grants its % of the whole plan.</span></div>' +
        '<div class="tree" id="p-tree"></div>' +
        '<label class="switch" style="margin-top:16px"><input type="checkbox" id="p-pub"' + (p.ispublished ? " checked" : "") + '><span class="switch__track"></span> Published (visible in app)</label>',
      actions: [
        { label: "Cancel", className: "btn--ghost", onClick: (close) => close() },
        { label: editing ? "Save" : "Create", className: "btn--primary", onClick: async (close, btn) => {
            const title = document.getElementById("p-title").value.trim();
            if (!title) { SUAR.ui.toast("Title required", "err"); return; }
            const body = { title, structure: stripIds(state), ispublished: document.getElementById("p-pub").checked };
            btn.disabled = true;
            try {
              if (editing) await SUAR.api.patch("/admin/prep-plans/" + encodeURIComponent(p.prepplanid), body);
              else await SUAR.api.post("/admin/prep-plans", body);
              SUAR.ui.toast(editing ? "Plan saved (v bumped)" : "Plan created", "ok"); close(); load(); SUAR.app.refreshCounts();
            } catch (e) { SUAR.ui.toast(e.message, "err"); btn.disabled = false; }
          } },
      ],
    });

    treeEl = m.body.querySelector("#p-tree");
    renderTree();
    m.body.querySelector("#p-add-sec").addEventListener("click", () => { state.push(newNode("group")); renderTree(); });
    m.body.querySelector("#p-add-item").addEventListener("click", () => { state.push(newNode("item")); renderTree(); });
  }

  // Keep ids out of the persisted JSON; they're regenerated on load.
  function stripIds(nodes) {
    return nodes.map((n) => {
      const o = { title: n.title, type: n.type, weight: Number(n.weight) || 0 };
      if (n.type === "item") o.fieldType = n.fieldType || "checkbox";
      else o.children = stripIds(n.children || []);
      return o;
    });
  }

  async function del(p) {
    const ok = await SUAR.ui.confirm({ title: "Delete plan?", message: 'Remove "' + p.title + '"?', confirmLabel: "Delete", danger: true });
    if (!ok) return;
    try {
      await SUAR.api.del("/admin/prep-plans/" + encodeURIComponent(p.prepplanid));
      SUAR.ui.toast("Plan deleted", "ok"); load(); SUAR.app.refreshCounts();
    } catch (e) { SUAR.ui.toast(e.message, "err"); }
  }

  return { render };
})();
