// The workspace, where the agent's work lands: folders, text with line
// numbers, images.
(function () {
  "use strict";
  var state = document.getElementById("state");
  var crumbs = document.getElementById("crumbs");
  var entries = document.getElementById("entries");
  var text = document.getElementById("text");
  var image = document.getElementById("image");

  function el(tag, cls, t) {
    var e = document.createElement(tag);
    if (cls) e.className = cls;
    if (t != null) e.textContent = t;
    return e;
  }

  function link(label, path) {
    var a = el("a", null, label);
    a.href = "#";
    a.addEventListener("click", function (ev) {
      ev.preventDefault();
      open(path);
    });
    return a;
  }

  function size(n) {
    if (n < 1024) return n + " B";
    if (n < 1024 * 1024) return (n / 1024).toFixed(1) + " KB";
    return (n / 1024 / 1024).toFixed(1) + " MB";
  }

  function trail(path) {
    crumbs.textContent = "";
    crumbs.append(link("workspace", ""));
    var at = "";
    path
      .split("/")
      .filter(Boolean)
      .forEach(function (part) {
        at = at ? at + "/" + part : part;
        crumbs.append(document.createTextNode(" / "), link(part, at));
      });
  }

  function open(path) {
    fetch("api/files?path=" + encodeURIComponent(path))
      .then(function (r) {
        return r.json().then(function (d) {
          if (!r.ok) throw new Error(d.error || String(r.status));
          return d;
        });
      })
      .then(function (data) {
        trail(data.path || "");
        entries.textContent = "";
        text.hidden = true;
        image.hidden = true;
        state.textContent = "";
        if (data.kind === "folder") {
          (data.entries || []).forEach(function (e) {
            var li = el("li");
            li.append(link(e.name + (e.kind === "folder" ? "/" : ""), (data.path ? data.path + "/" : "") + e.name));
            if (e.kind === "file") li.append(el("span", "meta", "  " + size(e.size)));
            entries.append(li);
          });
          if (!(data.entries || []).length) state.textContent = "Nothing here.";
        } else if (data.kind === "file") {
          text.textContent = "";
          data.text.split("\n").forEach(function (line, i) {
            var row = el("div", "line");
            row.append(el("span", "no", String(i + 1)), el("span", null, line));
            text.append(row);
          });
          text.hidden = false;
          state.textContent = size(data.size);
        } else if (data.kind === "image") {
          image.src = "data:" + data.mime + ";base64," + data.data;
          image.alt = data.path;
          image.hidden = false;
          state.textContent = size(data.size);
        } else {
          state.textContent = data.kind === "big" ? "Over 1 MB (" + size(data.size) + "): not shown." : "Not text (" + size(data.size) + "): not shown.";
        }
      })
      .catch(function (e) {
        state.textContent = "Not shown: " + e.message;
      });
  }

  open("");
})();
