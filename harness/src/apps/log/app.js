// The runs in the action log, newest first, as `harness log runs` lists
// them; each one's steps as `harness log session RID`.
(function () {
  const state = document.getElementById("state");
  const runs = document.getElementById("runs");

  function show(list) {
    runs.textContent = "";
    state.textContent = list.length === 0 ? "No runs yet." : "";
    for (const run of list) {
      const li = document.createElement("li");
      const head = document.createElement("div");
      head.textContent = run.label || ("run " + run.rid);
      const meta = document.createElement("div");
      meta.className = "meta";
      meta.textContent = [run.time, run.by, run.steps != null ? run.steps + " steps" : ""].filter(Boolean).join(" · ");
      li.append(head, meta);
      runs.append(li);
    }
  }

  fetch("api/log/runs")
    .then(function (r) {
      if (!r.ok) throw new Error(String(r.status));
      return r.json();
    })
    .then(function (data) {
      show(Array.isArray(data.runs) ? data.runs : []);
    })
    .catch(function () {
      state.textContent = "This harness doesn't give apps the log yet: the apps' API comes in a later version. harness log runs shows it in a terminal.";
    });
})();
