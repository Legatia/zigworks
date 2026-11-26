// What waits for the owner, by kind and by what started it, and what was
// answered. Answers go through harness's bar above the app, never from
// here: an app that answered could approve itself.
(function () {
  "use strict";
  var state = document.getElementById("state");
  var open = document.getElementById("open");
  var closed = document.getElementById("closed");
  var view = new URLSearchParams(location.search).get("view") || "";
  var wanted = view.indexOf("item-") === 0 ? Number(view.slice(5)) : 0;

  function el(tag, cls, text) {
    var e = document.createElement(tag);
    if (cls) e.className = cls;
    if (text != null) e.textContent = text;
    return e;
  }

  function row(it) {
    var li = el("li", it.id === wanted ? "wanted" : null);
    li.append(el("div", "title", "[" + it.id + "] " + (it.title || it.kind)));
    var meta = [it.kind, "by " + it.by, it.conversation, it.created];
    if (it.count > 1) meta.push(it.count + " times");
    li.append(el("div", "meta", meta.filter(Boolean).join(" · ")));
    if (it.body && it.body !== it.title) {
      var more = el("details");
      if (it.id === wanted) more.open = true;
      more.append(el("summary", null, "All of it"), el("pre", null, it.body));
      li.append(more);
    }
    if (it.draft) li.append(el("pre", "draft", it.draft));
    if (it.status === "open") {
      var labels = (it.choices || []).map(function (c) {
        return c.label;
      });
      if (labels.length) li.append(el("div", "meta", "Answer it in the bar above: " + labels.join(", ")));
    } else {
      var a = it.answer;
      var how = it.status;
      if (a && a.key) how += ": " + a.key;
      if (a && a.text) how += ' ("' + a.text + '")';
      if (a) how += " · " + a.at + " via " + a.via;
      li.append(el("div", "meta", how));
    }
    return li;
  }

  function group(list, into, by) {
    into.textContent = "";
    var keys = [];
    var groups = {};
    list.forEach(function (it) {
      var k = by(it);
      if (!groups[k]) {
        groups[k] = [];
        keys.push(k);
      }
      groups[k].push(it);
    });
    keys.forEach(function (k) {
      into.append(el("h2", null, k + " (" + groups[k].length + ")"));
      var ul = el("ul", "list");
      groups[k].forEach(function (it) {
        ul.append(row(it));
      });
      into.append(ul);
    });
  }

  function load() {
    fetch("api/inbox?state=all")
      .then(function (r) {
        return r.json().then(function (d) {
          if (!r.ok) throw new Error(d.error || String(r.status));
          return d;
        });
      })
      .then(function (data) {
        var items = Array.isArray(data.items) ? data.items : [];
        var waiting = items.filter(function (it) {
          return it.status === "open";
        });
        var done = items
          .filter(function (it) {
            return it.status !== "open";
          })
          .reverse();
        state.textContent = waiting.length === 0 ? "No open items" : waiting.length + (waiting.length === 1 ? " open item" : " open items");
        group(waiting, open, function (it) {
          return it.kind + ", by " + it.by;
        });
        group(done, closed, function (it) {
          return it.status;
        });
      })
      .catch(function (e) {
        state.textContent = "The inbox could not be read: " + e.message;
      });
  }

  load();
  setInterval(load, 3000);
})();
