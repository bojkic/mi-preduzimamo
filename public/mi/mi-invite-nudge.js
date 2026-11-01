/* MI! — "Pozovi komšije" nudge.

   The strip is rendered hidden by the server and revealed here, the same way
   the push offer behaves: a bar that appears and then hides itself is worse
   than one that never appeared, and unhiding after the snooze check avoids a
   layout shift on every page load.

   Dismissal snoozes for the number of days the markup asks for (7), per user,
   in localStorage. A browser with no localStorage (private mode, storage
   disabled) still sees the nudge and can still dismiss it for the page — it
   simply comes back next time, which is the safe direction to fail.

   It also stands aside for Decidim's cookie banner, for the same reason the
   install card does: consent comes first. */
(function () {
  "use strict";

  var DAY_MS = 24 * 60 * 60 * 1000;

  function consentBannerActive() {
    var banner = document.getElementById("dc-dialog-wrapper");
    return !!(banner && !banner.hidden && banner.getClientRects().length);
  }

  function whenConsentResolved(fn) {
    if (!consentBannerActive()) { fn(); return; }
    var done = false;
    var observer = null;
    function fire() {
      if (done || consentBannerActive()) return;
      done = true;
      document.removeEventListener("dataconsent", fire);
      if (observer) observer.disconnect();
      fn();
    }
    document.addEventListener("dataconsent", fire);
    var banner = document.getElementById("dc-dialog-wrapper");
    if (banner && "MutationObserver" in window) {
      observer = new MutationObserver(fire);
      observer.observe(banner, { attributes: true, attributeFilter: ["hidden", "class", "style"] });
    }
  }

  function readSnooze(key) {
    try {
      var raw = window.localStorage.getItem(key);
      if (!raw) return 0;
      var until = parseInt(raw, 10);
      return isNaN(until) ? 0 : until;
    } catch (e) {
      return 0;
    }
  }

  function writeSnooze(key, days) {
    try {
      window.localStorage.setItem(key, String(Date.now() + days * DAY_MS));
    } catch (e) { /* private mode: the nudge simply returns next visit */ }
  }

  function setUp(nudge) {
    var key = nudge.getAttribute("data-invite-nudge-key");
    var days = parseInt(nudge.getAttribute("data-invite-nudge-days"), 10);
    if (!days || days < 1) days = 7;

    if (key && Date.now() < readSnooze(key)) return;

    var dismiss = nudge.querySelector("[data-invite-nudge-dismiss]");
    if (dismiss) {
      dismiss.addEventListener("click", function () {
        if (key) writeSnooze(key, days);
        nudge.hidden = true;
      });
    }

    whenConsentResolved(function () { nudge.hidden = false; });
  }

  function start() {
    var nudges = document.querySelectorAll("[data-invite-nudge]");
    for (var i = 0; i < nudges.length; i++) setUp(nudges[i]);
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", start);
  } else {
    start();
  }
})();
