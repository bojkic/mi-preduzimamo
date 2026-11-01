(function () {
  "use strict";
  var root = document.querySelector("[data-event-poll]");
  if (!root) return;
  var form = root.querySelector("[data-event-vote]");
  var status = root.querySelector("[data-vote-status]");
  function changed() {
    status.textContent = root.dataset.changedMessage;
    if (form) form.hidden = true;
  }
  function apply(data) {
    if ((data.event_key || "") !== (root.dataset.eventKey || "")) {
      changed();
      return false;
    }
    root.querySelector("[data-vote-total]").textContent = data.total;
    data.choices.forEach(function (choice) {
      var row = root.querySelector('[data-result="' + choice.key + '"]');
      if (!row) return;
      row.querySelector("[data-count]").textContent = choice.count + " · " + choice.percent + "%";
      row.querySelector("progress").value = choice.percent;
    });
    return true;
  }
  if (form) form.addEventListener("submit", function (event) {
    event.preventDefault();
    var submit = form.querySelector('[type="submit"]');
    submit.disabled = true;
    var headers = { Accept: "application/json" };
    var csrf = document.querySelector('meta[name="csrf-token"]');
    if (csrf) headers["X-CSRF-Token"] = csrf.content;
    fetch(form.action, { method: "POST", body: new FormData(form), credentials: "same-origin", headers: headers
    }).then(function (response) {
      if (response.redirected) throw new Error("Prijavi se pa pokušaj ponovo.");
      return response.json().then(function (data) {
        if (!response.ok) throw new Error(data.error || "Glas nije zabilježen. Pokušaj ponovo.");
        return data;
      });
    }).then(function (data) {
      if (!apply(data)) return;
      form.hidden = true;
      status.textContent = "Hvala! Tvoj glas je zabilježen.";
      root.querySelector(".mi-event-poll__results").scrollIntoView({ behavior: "smooth", block: "start" });
    }).catch(function (error) {
      status.textContent = error.message || "Veza je prekinuta. Pokušaj ponovo.";
      submit.disabled = false;
    });
  });
  var refreshing = false;
  window.setInterval(function () {
    if (document.hidden || refreshing) return;
    refreshing = true;
    fetch(root.dataset.resultsUrl + "?event_key=" + encodeURIComponent(root.dataset.eventKey || ""), { credentials: "same-origin", headers: { Accept: "application/json" }, cache: "no-store" })
      .then(function (response) {
        if (response.status === 409) { changed(); return null; }
        if (!response.ok) throw new Error();
        return response.json();
      })
      .then(function (data) { if (data) apply(data); }).catch(function () { /* Keep the last good results. */ })
      .finally(function () { refreshing = false; });
  }, 3000);
}());
