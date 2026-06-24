/* Guides & Tips: survival / first-aid / preparation articles sharing one table,
 * split by category tab. Body is rich text authored with Quill and stored as
 * HTML so the app can render it directly later. Editing bumps the version. */
window.SUAR = window.SUAR || {};
SUAR.views = SUAR.views || {};

SUAR.views.content = (function () {
  const CATS = [
    { key: "survival", label: "Survival" },
    { key: "first_aid", label: "First Aid" },
    { key: "preparation", label: "Preparation" },
  ];
  let active = "survival";
  let all = [];
  let quill = null;

  // Register a horizontal-rule blot once so the editor can insert separators.
  (function registerDivider() {
    if (SUAR._dividerReg) return;
    const BlockEmbed = Quill.import("blots/block/embed");
    class DividerBlot extends BlockEmbed {}
    DividerBlot.blotName = "divider";
    DividerBlot.tagName = "hr";
    Quill.register(DividerBlot);
    SUAR._dividerReg = true;
  })();

  async function render(container) {
    container.innerHTML =
      '<div class="view__head"><span class="eyebrow">Offline content shown in the app</span><span class="spacer"></span>' +
      '<button class="btn btn--primary btn--sm" id="c-new">+ New entry</button></div>' +
      '<div class="tabs" id="c-tabs">' +
        CATS.map((c) => '<div class="tab' + (c.key === active ? " active" : "") + '" data-cat="' + c.key + '">' + c.label + "</div>").join("") +
      "</div>" +
      '<div class="card"><div class="table-wrap" id="c-table">' + SUAR.ui.spinner() + "</div></div>";

    document.getElementById("c-new").addEventListener("click", () => openForm(null));
    container.querySelectorAll(".tab").forEach((t) =>
      t.addEventListener("click", () => { active = t.dataset.cat; render(container); })
    );
    await load();
  }

  async function load() {
    const wrap = document.getElementById("c-table");
    wrap.innerHTML = SUAR.ui.spinner();
    all = await SUAR.api.get("/admin/content");
    const rows = all.filter((c) => c.category === active);
    if (!rows.length) { wrap.innerHTML = SUAR.ui.empty("No entries here", "Add a " + active.replace("_", " ") + " guide."); return; }
    wrap.innerHTML =
      '<table class="data"><thead><tr><th>Title</th><th>Status</th><th>Ver.</th><th>Updated</th><th></th></tr></thead><tbody>' +
      rows.map((c) =>
        "<tr>" +
        "<td><b>" + SUAR.ui.esc(c.title) + "</b></td>" +
        "<td>" + (c.ispublished ? '<span class="chip chip--on">published</span>' : '<span class="chip chip--off">draft</span>') + "</td>" +
        '<td class="mono-cell">v' + (c.version ?? 1) + "</td>" +
        '<td class="muted">' + SUAR.ui.fmtRelative(c.updatedat) + "</td>" +
        '<td class="cell-actions"><button class="btn btn--ghost btn--sm" data-edit>Edit</button><button class="btn btn--danger btn--sm" data-del>Delete</button></td>' +
        "</tr>"
      ).join("") + "</tbody></table>";
    rows.forEach((c, i) => {
      const tr = wrap.querySelectorAll("tbody tr")[i];
      tr.querySelector("[data-edit]").addEventListener("click", () => openForm(c));
      tr.querySelector("[data-del]").addEventListener("click", () => del(c));
    });
  }

  const TOOLBAR =
    '<div id="qtoolbar">' +
      '<span class="ql-formats"><select class="ql-header"><option value="1"></option><option value="2"></option><option value="3"></option><option selected></option></select></span>' +
      '<span class="ql-formats"><button class="ql-bold"></button><button class="ql-italic"></button><button class="ql-underline"></button><button class="ql-strike"></button></span>' +
      '<span class="ql-formats"><button class="ql-list" value="ordered"></button><button class="ql-list" value="bullet"></button><button class="ql-blockquote"></button></span>' +
      '<span class="ql-formats"><button class="ql-link"></button><button class="ql-divider" title="Divider">―</button><button class="ql-clean"></button></span>' +
    "</div>";

  function openForm(c) {
    const editing = !!c;
    c = c || {};
    quill = null;
    const m = SUAR.ui.modal({
      wide: true,
      title: editing ? "Edit entry" : "New entry",
      body:
        '<div class="form-row">' +
          '<div class="field"><label>Title</label><input class="input" id="c-title" value="' + SUAR.ui.esc(c.title || "") + '"></div>' +
          '<div class="field"><label>Category</label><select class="select" id="c-cat">' +
            CATS.map((x) => '<option value="' + x.key + '"' + ((c.category || active) === x.key ? " selected" : "") + ">" + x.label + "</option>").join("") + "</select></div>" +
        "</div>" +
        '<div class="field"><label>Body</label>' + TOOLBAR + '<div id="qeditor"></div></div>' +
        '<label class="switch"><input type="checkbox" id="c-pub"' + (c.ispublished ? " checked" : "") + '><span class="switch__track"></span> Published (visible in app)</label>',
      actions: [
        { label: "Cancel", className: "btn--ghost", onClick: (close) => close() },
        { label: editing ? "Save" : "Create", className: "btn--primary", onClick: async (close, btn) => {
            const title = document.getElementById("c-title").value.trim();
            if (!title) { SUAR.ui.toast("Title required", "err"); return; }
            const html = quill.getText().trim() ? quill.root.innerHTML : "";
            const body = {
              title,
              category: document.getElementById("c-cat").value,
              body: html,
              ispublished: document.getElementById("c-pub").checked,
            };
            btn.disabled = true;
            try {
              if (editing) await SUAR.api.patch("/admin/content/" + encodeURIComponent(c.contentid), body);
              else await SUAR.api.post("/admin/content", body);
              SUAR.ui.toast(editing ? "Saved (v bumped)" : "Entry created", "ok"); close(); load(); SUAR.app.refreshCounts();
            } catch (e) { SUAR.ui.toast(e.message, "err"); btn.disabled = false; }
          } },
      ],
    });

    // Quill must mount after its container is in the DOM.
    quill = new Quill(m.body.querySelector("#qeditor"), {
      theme: "snow",
      placeholder: "Write the guide…",
      modules: {
        toolbar: {
          container: m.body.querySelector("#qtoolbar"),
          handlers: {
            divider: function () {
              const range = this.quill.getSelection(true);
              this.quill.insertEmbed(range.index, "divider", true, Quill.sources.USER);
              this.quill.setSelection(range.index + 1, Quill.sources.SILENT);
            },
          },
        },
      },
    });
    if (c.body) quill.root.innerHTML = c.body;
  }

  async function del(c) {
    const ok = await SUAR.ui.confirm({ title: "Delete entry?", message: 'Remove "' + c.title + '"?', confirmLabel: "Delete", danger: true });
    if (!ok) return;
    try {
      await SUAR.api.del("/admin/content/" + encodeURIComponent(c.contentid));
      SUAR.ui.toast("Entry deleted", "ok"); load(); SUAR.app.refreshCounts();
    } catch (e) { SUAR.ui.toast(e.message, "err"); }
  }

  return { render };
})();
