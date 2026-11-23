// What waits for the owner: approvals, questions, drafts, failed sends.
// Answers go through harness's bar above the app, never from here.
(function () {
  const state = document.getElementById("state");
  const items = document.getElementById("items");

  function show(list) {
    items.textContent = "";
    if (list.length === 0) {
      state.textContent = "Nothing waits for you.";
      return;
    }
    state.textContent = list.length + (list.length === 1 ? " item waits." : " items wait.");
    for (const it of list) {
      const li = document.createElement("li");
      const title = document.createElement("div");
      title.textContent = it.title || it.kind || "item";
      const meta = document.createElement("div");
      meta.className = "meta";
      meta.textContent = [it.kind, it.by, it.created].filter(Boolean).join(" · ");
      li.append(title, meta);
      items.append(li);
    }
  }

  fetch("api/inbox?state=open")
    .then(function (r) {
      if (!r.ok) throw new Error(String(r.status));
      return r.json();
    })
    .then(function (data) {
      show(Array.isArray(data.items) ? data.items : []);
    })
    .catch(function () {
      state.textContent = "This harness doesn't give apps the inbox yet: the apps' API comes in a later version.";
    });
})();
