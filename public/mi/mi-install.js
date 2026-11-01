/* MI! — PWA install card. Offered ONLY to a signed-in citizen (the page says so
   through data-signed-in on the script tag) or on a ?app=1 landing, on every
   visit until the app is installed; "Ne sada" snoozes it for three days. On
   Chrome (Android + desktop) the button installs in one tap through the
   captured beforeinstallprompt event; iOS can only be told how (Share → Add to
   Home Screen); an embedded webview is asked to open a real browser. Localized
   copy arrives via data attributes, read synchronously at load time, with
   Serbian fallbacks. Styling lives in mi-theme.css (.mi-install-card). */
(function () {
  "use strict";
  // Page navigation can retain head scripts while replacing the body. Bind once and read
  // eligibility from the current page, including after sign-in and sign-out.
  if (window.miInstallInitialized) return;
  window.miInstallInitialized = true;
  var _script = document.currentScript;
  var _data = _script ? _script.dataset : {};
  var SIGNED_IN = _data.signedIn === "1";
  var INSTALL_TITLE = _data.installTitle || "MI! kao aplikacija";
  var INSTALL_TEXT = _data.installText || "Brži pristup prijavama, bodovima i Milici — direktno sa početnog ekrana.";
  var IOS_TEXT = _data.iosText ||
    "Dodaj MI! na početni ekran: dodirni ⎖ Share pa „Add to Home Screen“.";
  var MANUAL_TEXT = _data.manualText ||
    "Otvori meni preglednika i izaberi „Dodaj na početni ekran“ ili „Instaliraj aplikaciju“.";
  var WEBVIEW_TEXT = _data.webviewText ||
    "Otvori MI! u Chromeu ili Safariju da bi je dodao/dodala na početni ekran.";
  var INSTALL_LABEL = _data.installLabel || "Instaliraj";
  var DISMISS_LABEL = _data.dismissLabel || "Ne sada";
  var ICON_SRC = _data.iconSrc || "/icon.png";

  var KEY = "miInstall";
  var SNOOZE_MS = 3 * 24 * 60 * 60 * 1000;
  var deferred = null;
  var fallbackTimer = null;
  var bannerMode = null;
  var params = new URLSearchParams(window.location.search || "");
  var force = params.get("app") === "1";

  // app=1 is a one-time hand-off marker from the authenticated success page.
  // Remove only that value in-place so a refresh cannot force the offer again,
  // while preserving every other query parameter and the hash fragment.
  function consumeAppMarker() {
    if (!force || !window.history || typeof window.history.replaceState !== "function") return;
    try {
      var rawSearch = window.location.search || "";
      var kept = rawSearch.replace(/^\?/, "").split("&").filter(function (part) {
        if (!part) return true;
        var separator = part.indexOf("=");
        var rawKey = separator === -1 ? part : part.slice(0, separator);
        var rawValue = separator === -1 ? "" : part.slice(separator + 1);
        var key;
        var value;
        try {
          key = decodeURIComponent(rawKey.replace(/\+/g, " "));
          value = decodeURIComponent(rawValue.replace(/\+/g, " "));
        } catch (e) {
          return true;
        }
        return !(key === "app" && value === "1");
      }).join("&");
      var target = (window.location.pathname || "") + (kept ? "?" + kept : "") +
        (window.location.hash || "");
      window.history.replaceState(window.history.state || null, document.title, target);
    } catch (e) { /* an unusual history implementation must not block sign-in */ }
  }
  consumeAppMarker();

  var standalone = window.matchMedia("(display-mode: standalone)").matches ||
    window.navigator.standalone === true;
  // An installed PWA gets no install offer, but still consumes app=1 above.
  if (standalone) return;

  var state = {};
  try { state = JSON.parse(localStorage.getItem(KEY) || "{}"); } catch (e) { state = {}; }
  function saveState() {
    try { localStorage.setItem(KEY, JSON.stringify(state)); } catch (e) { /* private mode */ }
  }
  // Legacy flag from the first version of this script ("never again"). An
  // installed app is still never asked; an old dismissal becomes one snooze.
  if (state.dismissed && !state.installed) {
    delete state.dismissed;
    state.snoozedUntil = Date.now() + SNOOZE_MS;
    saveState();
  }

  var userAgent = navigator.userAgent || "";
  var isIos = /iphone|ipad|ipod/i.test(userAgent);
  var isMobile = isIos || /android|mobile/i.test(userAgent);
  // Embedded webviews cannot use the browser's install prompt. Their guidance
  // explicitly asks the user to open the page in a real browser.
  var isWebView = /;\s*wv\)|\bFBAN|\bFBAV|Instagram|\bLine\/|;\s*WebView|GSA\//i.test(userAgent) ||
    (/iphone|ipad|ipod/i.test(userAgent) && /AppleWebKit/i.test(userAgent) &&
      !/(Safari|CriOS|FxiOS|EdgiOS|OPiOS)/i.test(userAgent));

  // --- Cookie-consent gating ------------------------------------------------
  // Decidim shows its cookie banner (#dc-dialog-wrapper) until the visitor
  // resolves consent. We must not pop the install card over it, so defer
  // showing until the banner is gone or a dataconsent event fires.
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

  function snoozed() {
    return typeof state.snoozedUntil === "number" && Date.now() < state.snoozedUntil;
  }

  function eligible() {
    var context = document.getElementById("mi-install-context");
    if (context && context.dataset.allowed !== "1") return false;
    var signedIn = context ? context.dataset.signedIn === "1" : SIGNED_IN;
    if (state.installed) return false;
    if (force) return true;
    return signedIn && !snoozed();
  }

  function snooze() {
    state.snoozedUntil = Date.now() + SNOOZE_MS;
    force = false;
    saveState();
  }

  function clearFallbackTimer() {
    if (fallbackTimer !== null) {
      clearTimeout(fallbackTimer);
      fallbackTimer = null;
    }
  }

  window.addEventListener("beforeinstallprompt", function (e) {
    e.preventDefault();
    deferred = e;
    clearFallbackTimer();
    if (eligible()) whenConsentResolved(function () { show("prompt"); });
  });
  window.addEventListener("appinstalled", function () {
    state.installed = true;
    force = false;
    clearFallbackTimer();
    saveState();
    remove();
  });

  function scheduleOffer() {
    if (!eligible()) return;
    if (deferred) {
      whenConsentResolved(function () { show("prompt"); });
    } else if (isWebView) {
      whenConsentResolved(function () { show("webview"); });
    } else if (isIos) {
      whenConsentResolved(function () { show("ios"); });
    } else if (isMobile) {
      // beforeinstallprompt can arrive after this script. Keep listening and
      // use manual guidance only if the browser never supplies the event. A
      // desktop browser that never fires it (already installed there, or a
      // browser that cannot install) is left alone: instructions it cannot
      // follow would only nag.
      fallbackTimer = setTimeout(function () {
        fallbackTimer = null;
        if (eligible() && !deferred) {
          whenConsentResolved(function () { show("manual"); });
        }
      }, 1500);
    }
  }
  function offerForPage() {
    clearFallbackTimer();
    if (new URLSearchParams(window.location.search || "").get("app") === "1") {
      force = true;
      consumeAppMarker();
    }
    if (!eligible()) { remove(); return; }
    scheduleOffer();
  }
  document.addEventListener("turbo:load", offerForPage);
  document.addEventListener("turbo:before-cache", remove);
  // Decidim reveals its cookie dialog during its page-load event. The load
  // fallback runs afterwards, rather than racing it from a deferred script.
  window.addEventListener("load", offerForPage, { once: true });
  if (document.readyState === "complete") offerForPage();

  function escHtml(str) {
    return String(str).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;").replace(/'/g, "&#39;");
  }

  function copyFor(mode) {
    if (mode === "ios") return IOS_TEXT;
    if (mode === "webview") return WEBVIEW_TEXT;
    return MANUAL_TEXT;
  }

  function svgClose() {
    return '<svg viewBox="0 0 24 24" width="18" height="18" aria-hidden="true" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round"><path d="M6 6l12 12M18 6L6 18"/></svg>';
  }

  function show(mode) {
    if (!eligible()) return;
    var installable = mode === "prompt" && !!deferred;
    var existing = document.getElementById("mi-install-banner");
    // A late prompt event upgrades an already-visible manual card. Avoid
    // creating a competing card or replacing an equivalent one.
    if (existing && (bannerMode === "prompt" || !installable)) return;
    if (existing) remove();
    if (consentBannerActive()) { whenConsentResolved(function () { show(mode); }); return; }
    bannerMode = installable ? "prompt" : mode;
    document.documentElement.classList.add("mi-install-open");

    var text = installable ? INSTALL_TEXT : copyFor(mode);
    var el = document.createElement("div");
    el.id = "mi-install-banner";
    el.className = "mi-install-card" + (installable ? " mi-install-card--prompt" : " mi-install-card--" + mode);
    el.setAttribute("role", "dialog");
    el.setAttribute("aria-labelledby", "mi-install-title");
    el.setAttribute("aria-describedby", "mi-install-text");
    el.innerHTML =
      '<button type="button" class="mi-install-card__close" id="mi-install-close" aria-label="' + escHtml(DISMISS_LABEL) + '">' + svgClose() + "</button>" +
      '<div class="mi-install-card__row">' +
        '<img class="mi-install-card__icon" src="' + escHtml(ICON_SRC) + '" alt="" width="56" height="56">' +
        '<div class="mi-install-card__body">' +
          '<strong id="mi-install-title" class="mi-install-card__title">' + escHtml(INSTALL_TITLE) + "</strong>" +
          '<p id="mi-install-text" class="mi-install-card__text">' + escHtml(text) + "</p>" +
        "</div>" +
      "</div>" +
      '<div class="mi-install-card__actions">' +
        (installable ? '<button type="button" class="mi-install-card__go" id="mi-install-go">' + escHtml(INSTALL_LABEL) + "</button>" : "") +
        '<button type="button" class="mi-install-card__later" id="mi-install-later">' + escHtml(DISMISS_LABEL) + "</button>" +
      "</div>";
    document.body.appendChild(el);

    var go = document.getElementById("mi-install-go");
    if (go) go.addEventListener("click", function () {
      if (!deferred) return remove();
      var event = deferred;
      deferred = null;
      force = false;
      try { event.prompt(); } catch (e) { remove(); return; }
      if (event.userChoice && typeof event.userChoice.then === "function") {
        event.userChoice.then(function (choice) {
          if (choice && choice.outcome === "accepted") {
            state.installed = true;
            saveState();
          } else {
            snooze();
          }
          remove();
        }, remove);
      } else {
        remove();
      }
    });
    function later() {
      deferred = null;
      clearFallbackTimer();
      snooze();
      remove();
    }
    document.getElementById("mi-install-later").addEventListener("click", later);
    document.getElementById("mi-install-close").addEventListener("click", later);
  }

  function remove() {
    bannerMode = null;
    document.documentElement.classList.remove("mi-install-open");
    var el = document.getElementById("mi-install-banner");
    if (el) el.remove();
  }
})();
