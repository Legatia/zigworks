// What the billing audit found, largest first, and what you decided about
// each. Everything comes from paymcp through harness's gate (the app's
// acts): the app holds no key and reaches nothing but harness. A decision
// is written into paymcp's own record; nothing here changes the billing
// account, and a drafted message is sent by nobody but you.
(function () {
  "use strict";
  var PAGE = 20;
  var state = document.getElementById("state");
  var sums = document.getElementById("sums");
  var notes = document.getElementById("notes");
  var list = document.getElementById("list");
  var more = document.getElementById("more");
  var again = document.getElementById("again");
  var all = document.getElementById("all");
  var recordState = document.getElementById("record-state");
  var record = document.getElementById("record");
  var shown = 0;
  var total = 0;

  function el(tag, cls, text) {
    var e = document.createElement(tag);
    if (cls) e.className = cls;
    if (text != null) e.textContent = text;
    return e;
  }

  function answer(r) {
    return r.json().then(function (d) {
      if (!r.ok) throw new Error(d.error || String(r.status));
      return d;
    });
  }

  // One act at a time: harness runs two of an app's at once, and the
  // answers here are read in the order they were asked.
  var line = Promise.resolve();

  function act(tool, input, waiting) {
    function start() {
      return fetch("api/act", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ tool: "billing/" + tool, input: input || {} }),
      })
        .then(answer)
        .then(function (job) {
          return poll(job.id, waiting);
        });
    }
    var p = line.then(start, start);
    line = p.catch(function () {});
    return p;
  }

  function poll(id, waiting) {
    return fetch("api/act/" + id + "?wait=20")
      .then(answer)
      .then(function (job) {
        if (job.state === "done") return job.output || "";
        if (job.state === "refused") throw new Error(job.output || "harness refused it");
        if (job.state === "asked" && waiting) waiting();
        return poll(id, waiting);
      });
  }

  // A tool's answer as data. What isn't data is the tool's own sentence
  // about what went wrong (or an answer harness cut short).
  function data(tool, input, waiting) {
    input = input || {};
    input.format = "json";
    return act(tool, input, waiting).then(function (text) {
      try {
        return JSON.parse(text);
      } catch (e) {
        throw new Error(text.length > 400 ? text.slice(0, 400) + "…" : text || "no answer");
      }
    });
  }

  function badge(text, cls) {
    return el("span", "badge" + (cls ? " " + cls : ""), text);
  }

  var stateWords = { new: "new", back: "found again", asked: "asked", intended: "dismissed as intended" };

  function item(f) {
    var li = el("li");
    var head = el("button", "head");
    head.type = "button";
    var title = el("span", "title", f.title);
    if (f.state && stateWords[f.state]) title.append(badge(stateWords[f.state], f.state));
    if (f.due) title.append(badge("answer by " + f.due, "due"));
    head.append(title, el("span", "amount", f.amount_text));
    li.append(head, el("div", "what", f.what));
    if (f.reason) li.append(el("div", "meta", (f.state === "asked" ? "Asked: " : "Dismissed: ") + f.reason));
    var detail = null;
    head.addEventListener("click", function () {
      if (detail) {
        detail.remove();
        detail = null;
        return;
      }
      detail = el("div", "detail");
      detail.append(el("p", "meta", "Reading…"));
      li.append(detail);
      var into = detail;
      data("billing_finding", { key: f.key })
        .then(function (one) {
          if (into === detail) fill(into, one);
        })
        .catch(function (e) {
          into.textContent = "";
          into.append(el("p", "bad", e.message));
        });
    });
    return li;
  }

  function fill(into, one) {
    into.textContent = "";
    var rows = el("ul");
    (one.rows || []).forEach(function (r) {
      var li = el("li");
      li.append(el("span", "source", r.source + ": "), document.createTextNode(r.value));
      rows.append(li);
    });
    if (one.rows_more > 0) rows.append(el("li", "source", "…and " + one.rows_more + " more rows."));
    into.append(rows);
    into.append(el("p", null, "Proposed: " + one.proposal));
    var facts = [];
    if (one.first_found) facts.push("first found " + one.first_found);
    if (one.due) facts.push("to be answered by " + one.due);
    facts.push(one.key);
    into.append(el("p", "meta", facts.join(" · ")));
    if (one.letter) {
      into.append(el("h2", null, "A draft to the customer"));
      into.append(el("p", "meta", "For you to read, change and send from your own mail. Nothing here sends it."));
      into.append(el("p", "meta", "To: " + (one.letter.to || "(billing has no address for this customer)") + " · Subject: " + one.letter.subject));
      var text = el("textarea");
      text.readOnly = true;
      text.value = one.letter.body;
      into.append(text);
      var pick = el("button", null, "Select the text");
      pick.type = "button";
      pick.addEventListener("click", function () {
        text.focus();
        text.select();
      });
      var pickRow = el("div", "row");
      pickRow.append(pick);
      into.append(pickRow);
    }
    if (one.evidence) {
      into.append(el("h2", null, "The evidence draft"));
      into.append(el("p", "meta", "What the account already shows, and what only you have. Nothing here sends it: sending is final, and yours to do at the provider."));
      var ev = el("textarea");
      ev.readOnly = true;
      ev.value = one.evidence;
      into.append(ev);
    }
    if (one.state == null) {
      into.append(el("p", "meta", "No record is kept (the pay file says record = none), so a decision has nowhere to be written."));
      return;
    }
    into.append(el("h2", null, "Your decision"));
    if (one.state === "asked" || one.state === "intended") {
      into.append(el("p", null, (one.state === "asked" ? "Asked on " : "Dismissed as intended on ") + one.decided + (one.reason ? ": " + one.reason : ".")));
    }
    var said = el("p", "meta");
    var row = el("div", "row");
    var why = el("input");
    why.type = "text";
    why.maxLength = 300;
    why.placeholder = "Why it is meant to be so, or who was asked";
    function decide(decision, needs) {
      return function () {
        var reason = why.value.trim();
        if (needs && !reason) {
          said.textContent = needs;
          why.focus();
          return;
        }
        said.textContent = "Writing it down…";
        act("billing_decide", { key: one.key, decision: decision, reason: reason }, function () {
          said.textContent = "harness is asking you: answer in the bar above this page.";
        })
          .then(function (text) {
            said.textContent = text;
            load(true);
          })
          .catch(function (e) {
            said.textContent = "Not written: " + e.message;
          });
      };
    }
    function button(label, decision, needs) {
      var b = el("button", null, label);
      b.type = "button";
      b.addEventListener("click", decide(decision, needs));
      return b;
    }
    if (one.state !== "intended") row.append(why, button("It is meant to be so", "intended", "Say why it is meant to be so: the reason is kept with the decision."));
    if (one.state !== "asked" && one.state !== "intended") row.append(button("I asked someone", "asked", "Say who was asked."));
    if (one.state === "asked" || one.state === "intended") row.append(button("Open again", "open", null));
    into.append(row, said);
  }

  function show(page, keep) {
    total = page.total;
    state.textContent = "Reading of " + page.day + ". " + page.read + " Nothing was changed: the audit only reads.";
    var head = total === 0 ? (page.hidden > 0 ? "Nothing is open: all that was found was dismissed as intended." : "Nothing was found by these rules.") : total + (total === 1 ? " finding" : " findings");
    if (total > 0 && page.sums) head += ": " + page.sums;
    if (total > 0 && page.unknown > 0) head += (page.sums ? "; " : ": ") + page.unknown + " with an amount the audit can't know";
    sums.textContent = head + (total > 0 ? "." : "");
    notes.textContent = "";
    (page.not_read || []).forEach(function (gap) {
      notes.append(el("p", "note", "Not read: " + gap + "."));
    });
    if (page.record_problem) notes.append(el("p", "note", page.record_problem + ": what is new since the last reading isn't said."));
    if (page.first_reading) notes.append(el("p", "meta", "This is the first reading in the record: the next one says what is new and what is no longer found."));
    if (page.since_last) notes.append(el("p", "meta", page.since_last));
    if (page.hidden > 0) notes.append(el("p", "meta", page.hidden + " dismissed as intended " + (page.hidden === 1 ? "is" : "are") + " not listed" + (page.hidden_sums ? " (" + page.hidden_sums + ")" : "") + "."));
    if (total > 0) notes.append(el("p", "meta", "Each is a question for you, not a mistake found: a discount may be meant to last, an old price may be a promise."));
    if (!keep) {
      list.textContent = "";
      shown = 0;
    }
    page.findings.forEach(function (f) {
      list.append(item(f));
    });
    shown += page.findings.length;
    more.hidden = shown >= total;
  }

  function part(title, p, withReason, reopen) {
    record.append(el("h2", null, title + ": " + p.n + (p.n === 1 ? " finding" : " findings") + (p.sums ? ", " + p.sums : "") + (p.unknown > 0 ? (p.sums ? "; " : ", ") + p.unknown + " with an amount not known" : "") + "."));
    if (!p.items || p.items.length === 0) return;
    var ul = el("ul", "list");
    p.items.forEach(function (it) {
      var li = el("li");
      li.append(el("div", null, it.title + ": " + it.amount_text + " · " + it.name));
      li.append(el("div", "meta", it.day + (withReason && it.reason ? ' · "' + it.reason + '"' : "") + " · " + it.key));
      if (reopen) {
        var b = el("button", null, "Open again");
        b.type = "button";
        b.addEventListener("click", function () {
          b.disabled = true;
          act("billing_decide", { key: it.key, decision: "open" })
            .then(function () {
              load(true);
            })
            .catch(function (e) {
              li.append(el("div", "bad", "Not written: " + e.message));
            });
        });
        var bRow = el("div", "row");
        bRow.append(b);
        li.append(bRow);
      }
      ul.append(li);
    });
    record.append(ul);
    if (p.more > 0) record.append(el("p", "meta", "…and " + p.more + " more."));
  }

  function loadRecord() {
    data("billing_record")
      .then(function (r) {
        record.textContent = "";
        if (!r.first) {
          recordState.textContent = "The record is empty: the first reading starts it.";
          return;
        }
        recordState.textContent = r.readings + (r.readings === 1 ? " reading" : " readings") + " since " + r.first + ", the last on " + r.last + ". Kept on this computer, in " + r.path + ".";
        part("Asked, waiting for an answer", r.asked, true, true);
        part("Dismissed as intended", r.intended, true, true);
        part("No longer found", r.gone, false, false);
        if (r.gone.n > 0) record.append(el("p", "meta", "Whether each was put right is yours to say: the record only knows that a reading stopped finding it."));
      })
      .catch(function (e) {
        record.textContent = "";
        recordState.textContent = e.message;
      });
  }

  function page(offset, fresh) {
    var input = { offset: offset, limit: PAGE };
    if (fresh) input.fresh = true;
    if (all.checked) input.all = true;
    return data("billing_audit", input, function () {
      state.textContent = "harness is asking you whether the audit may run: answer in the bar above this page.";
    });
  }

  // `quiet`: after a decision, from the reading paymcp keeps.
  function load(quiet, fresh) {
    if (!quiet) state.textContent = fresh ? "Reading the account again…" : "Reading…";
    again.disabled = true;
    page(0, fresh)
      .then(function (p) {
        show(p, false);
        loadRecord();
      })
      .catch(function (e) {
        state.textContent = "The audit wasn't read: " + e.message;
        sums.textContent = "";
      })
      .then(function () {
        again.disabled = false;
      });
  }

  more.addEventListener("click", function () {
    more.disabled = true;
    page(shown, false)
      .then(function (p) {
        show(p, true);
      })
      .catch(function (e) {
        notes.append(el("p", "bad", e.message));
      })
      .then(function () {
        more.disabled = false;
      });
  });
  again.addEventListener("click", function () {
    load(false, true);
  });
  all.addEventListener("change", function () {
    load(true, false);
  });
  load(false, false);
})();
