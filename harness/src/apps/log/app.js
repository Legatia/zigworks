// The action log: its runs, newest first, as `harness log runs` lists them;
// a run's lines as `harness log session RID`; the lines as they are
// written, with filters by run, starter, kind, tool and decision; and
// `harness log verify`.
(function () {
  "use strict";
  var state = document.getElementById("state");
  var runs = document.getElementById("runs");
  var lines = document.getElementById("lines");
  var filter = document.getElementById("filter");
  var title = document.getElementById("title");
  var verify = document.getElementById("verify");
  var back = document.getElementById("back");
  var all = [];
  var last = 0;
  var session = 0;

  function el(tag, cls, text) {
    var e = document.createElement(tag);
    if (cls) e.className = cls;
    if (text != null) e.textContent = text;
    return e;
  }

  function get(path) {
    return fetch(path).then(function (r) {
      return r.json().then(function (d) {
        if (!r.ok) throw new Error(d.error || String(r.status));
        return d;
      });
    });
  }

  function text(v) {
    if (v == null) return "";
    if (typeof v === "string") return v;
    if (typeof v === "object" && v.bytes != null) return "(private, " + v.bytes + " bytes)";
    return String(v);
  }

  // one log line as a row: time, kind, what it says
  function row(l) {
    var li = el("li", l.decision === "deny" || l.is_error ? "bad" : null);
    var what = [];
    ["event", "tool", "decision", "why", "name", "arg", "output", "text"].forEach(function (k) {
      if (l[k] != null && l[k] !== "") what.push(k === "event" || k === "tool" ? text(l[k]) : k + ": " + text(l[k]));
    });
    li.append(el("div", null, what.join(" · ").slice(0, 600)));
    var meta = [l.time, l.kind, l.rid ? "run " + l.rid : "", l.run, l.by ? "by " + l.by : ""];
    li.append(el("div", "meta", meta.filter(Boolean).join(" · ")));
    return li;
  }

  function matches(l, words) {
    if (!words.length) return true;
    var hay = JSON.stringify(l).toLowerCase();
    return words.every(function (w) {
      return hay.indexOf(w) !== -1;
    });
  }

  function draw() {
    var words = filter.value.toLowerCase().split(/\s+/).filter(Boolean);
    lines.textContent = "";
    var shown = all.filter(function (l) {
      return matches(l, words);
    });
    shown
      .slice(-500)
      .reverse()
      .forEach(function (l) {
        lines.append(row(l));
      });
    state.textContent = shown.length + (shown.length === 1 ? " line" : " lines") + (words.length ? " match" : "");
  }

  function showRuns() {
    get("api/log/runs?limit=100")
      .then(function (d) {
        runs.textContent = "";
        (d.runs || []).forEach(function (r) {
          var li = el("li");
          var a = el("a", null, r.label || "run " + r.rid);
          a.href = "#";
          a.addEventListener("click", function (ev) {
            ev.preventDefault();
            openRun(r.rid, r.label);
          });
          li.append(a);
          var meta = ["run " + r.rid, r.time, r.by ? "by " + r.by : "", r.conversation, r.steps != null ? r.steps + " steps" : "", r.end];
          li.append(el("div", "meta", meta.filter(Boolean).join(" · ")));
          runs.append(li);
        });
        if (!(d.runs || []).length) runs.append(el("li", "meta", "No runs yet."));
      })
      .catch(function (e) {
        runs.textContent = "The runs could not be read: " + e.message;
      });
  }

  function openRun(rid, label) {
    session = rid;
    title.textContent = "Run " + rid + (label ? ": " + label : "");
    back.hidden = false;
    get("api/log/session/" + rid)
      .then(function (d) {
        all = d.lines || [];
        draw();
      })
      .catch(function (e) {
        state.textContent = "That run could not be read: " + e.message;
      });
  }

  // the lines as they are written: each call waits for a new one
  function follow() {
    get("api/log?after=" + last + "&limit=500&wait=20")
      .then(function (d) {
        var fresh = d.lines || [];
        last = d.last || last;
        if (session === 0 && fresh.length) {
          all = all.concat(fresh).slice(-2000);
          draw();
          showRuns();
        }
        setTimeout(follow, 200);
      })
      .catch(function () {
        setTimeout(follow, 3000);
      });
  }

  back.addEventListener("click", function () {
    session = 0;
    back.hidden = true;
    title.textContent = "Lines, newest first";
    all = [];
    last = 0;
    draw();
  });
  filter.addEventListener("input", draw);
  verify.addEventListener("click", function () {
    verify.textContent = "Checking…";
    get("api/log/verify")
      .then(function (d) {
        verify.textContent = d.ok ? "The chain holds: " + d.lines + " lines" : "Broken at line " + d.broken_at;
      })
      .catch(function (e) {
        verify.textContent = "Not checked: " + e.message;
      });
  });

  showRuns();
  follow();
})();
