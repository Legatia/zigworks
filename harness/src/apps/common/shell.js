// The bar of harness's own page: every open inbox item, oldest first, each
// with its choices (and a text box where the item takes text). An answer
// goes through the same call as Telegram's buttons and the terminal's keys;
// the first answer wins. Apps are in a frame below and cannot reach this.
(function () {
  "use strict";
  var bar = document.getElementById("bar");
  var api = document.body.getAttribute("data-api");
  if (!bar || !api) return;
  var shown = "";
  var note = "";

  function el(tag, cls, text) {
    var e = document.createElement(tag);
    if (cls) e.className = cls;
    if (text != null) e.textContent = text;
    return e;
  }

  function answer(id, key, text) {
    fetch(api + "answer", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ id: id, key: key, text: text }),
    })
      .then(function (r) {
        return r.json();
      })
      .then(function (d) {
        note = d.said || "";
        shown = "";
        load();
      })
      .catch(function () {
        note = "The answer did not reach harness.";
        shown = "";
        load();
      });
  }

  function draw(items) {
    bar.textContent = "";
    if (note) bar.append(el("p", "note", note));
    // a click in the first half second after the items changed is ignored:
    // nothing can put a button under a click already on its way
    var drawn = Date.now();
    function fresh() {
      return Date.now() - drawn < 500;
    }
    items.forEach(function (it) {
      var box = el("div", "item");
      var head = el("div", "head");
      head.append(el("span", "id", "[" + it.id + "]"), el("span", "kind", it.kind), el("span", "by", it.by));
      box.append(head);
      box.append(el("div", "title", it.title || ""));
      if (it.body && it.body !== it.title) {
        var more = el("details");
        more.append(el("summary", null, "All of it"), el("pre", null, it.body));
        box.append(more);
      }
      if (it.draft) box.append(el("pre", "draft", it.draft));
      var row = el("div", "choices");
      (it.choices || []).forEach(function (c) {
        var b = el("button", null, c.label);
        b.type = "button";
        b.addEventListener("click", function () {
          if (fresh()) return;
          answer(it.id, c.key, null);
        });
        row.append(b);
      });
      if (it.text && it.text !== "none") {
        var input = el("input");
        input.type = "text";
        input.placeholder = it.text === "reason" ? "Deny, and say why" : it.text === "draft" ? "Your own version" : "Your answer";
        var send = el("button", null, "Send");
        send.type = "button";
        send.addEventListener("click", function () {
          if (fresh() || !input.value.trim()) return;
          answer(it.id, "", input.value);
        });
        row.append(input, send);
      }
      box.append(row);
      bar.append(box);
    });
  }

  function load() {
    fetch(api + "inbox")
      .then(function (r) {
        return r.json();
      })
      .then(function (d) {
        var items = Array.isArray(d.items) ? d.items : [];
        var now = JSON.stringify(items) + note;
        if (now !== shown) {
          shown = now;
          draw(items);
        }
      })
      .catch(function () {});
  }

  load();
  setInterval(load, 2000);
})();
