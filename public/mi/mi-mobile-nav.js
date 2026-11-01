(function () {
  "use strict";

  function setOpen(nav, sheet, open) {
    var trigger = nav.querySelector("[data-mi-mobile-more-open]");
    if (!trigger) return;

    sheet.hidden = !open;
    trigger.setAttribute("aria-expanded", open ? "true" : "false");
    document.documentElement.classList.toggle("mi-mobile-nav-open", open);
    document.body.classList.toggle("mi-mobile-nav-open", open);

    if (open) {
      var closeButton = sheet.querySelector("[data-mi-mobile-more-close]");
      if (closeButton) closeButton.focus();
    } else {
      trigger.focus();
    }
  }

  function initMobileNav(nav) {
    if (nav.dataset.miMobileNavReady === "true") return;

    var sheetId = nav.getAttribute("data-sheet");
    var sheet = document.getElementById(sheetId);
    var trigger = nav.querySelector("[data-mi-mobile-more-open]");
    if (!sheet || !trigger) return;

    nav.dataset.miMobileNavReady = "true";

    trigger.addEventListener("click", function () {
      setOpen(nav, sheet, sheet.hidden);
    });

    sheet.addEventListener("click", function (event) {
      if (event.target === sheet || event.target.closest("[data-mi-mobile-more-close]")) {
        setOpen(nav, sheet, false);
      }
    });

    document.addEventListener("keydown", function (event) {
      if (event.key === "Escape" && !sheet.hidden) {
        setOpen(nav, sheet, false);
      }
    });
  }

  function openBotFromEvent(event) {
    var botTrigger = event.target.closest("[data-mi-bot-open]");
    if (!botTrigger) return;

    if (!window.MI_CHAT_LOADER || typeof window.MI_CHAT_LOADER.open !== "function") return;

    event.preventDefault();
    window.MI_CHAT_LOADER.open();
  }

  function initBotLaunchers() {
    if (document.documentElement.dataset.miBotLaunchersReady === "true") return;

    document.documentElement.dataset.miBotLaunchersReady = "true";
    document.addEventListener("click", openBotFromEvent);
  }

  /* With the toolbar fixed at the top and the Milica panel filling the screen
   * on a phone, the on-screen keyboard must SHRINK the layout viewport rather
   * than slide the visual viewport under it — otherwise the top of any fixed
   * panel (the chat header with its close button first of all) scrolls out of
   * reach while typing. Chrome/Android honours this viewport hint; browsers
   * that do not know it ignore the token. */
  function preferResizingViewport() {
    var meta = document.querySelector('meta[name="viewport"]');
    if (!meta) return;
    var content = meta.getAttribute("content") || "";
    if (/interactive-widget/.test(content)) return;
    meta.setAttribute("content", content + (content ? ", " : "") + "interactive-widget=resizes-content");
  }

  function init() {
    preferResizingViewport();
    initBotLaunchers();
    document.querySelectorAll("[data-mi-mobile-nav]").forEach(initMobileNav);
  }

  document.addEventListener("DOMContentLoaded", init);
  document.addEventListener("turbo:load", init);
}());
