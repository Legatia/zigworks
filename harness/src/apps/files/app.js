// The workspace, where the agent's work lands: folders, and text files
// with their lines.
(function () {
  const state = document.getElementById("state");
  const entries = document.getElementById("entries");
  const text = document.getElementById("text");

  function open(path) {
    fetch("api/files?path=" + encodeURIComponent(path))
      .then(function (r) {
        if (!r.ok) throw new Error(String(r.status));
        return r.json();
      })
      .then(function (data) {
        entries.textContent = "";
        text.hidden = true;
        state.textContent = path || "/";
        if (typeof data.text === "string") {
          text.textContent = data.text;
          text.hidden = false;
          return;
        }
        for (const e of data.entries || []) {
          const li = document.createElement("li");
          const a = document.createElement("a");
          a.href = "#";
          a.textContent = e.name + (e.kind === "folder" ? "/" : "");
          a.addEventListener("click", function (ev) {
            ev.preventDefault();
            open((path ? path + "/" : "") + e.name);
          });
          li.append(a);
          entries.append(li);
        }
      })
      .catch(function () {
        state.textContent = "This harness doesn't give apps the workspace yet: the apps' API comes in a later version.";
      });
  }

  open("");
})();
