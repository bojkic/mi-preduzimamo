/* Explicit, versioned consent. Never collect account IDs, form data or private URLs. */
(function () {
  "use strict";
  if (window.miAnalyticsInitialized) return;
  var node = document.querySelector('meta[name="mi-analytics-config"]');
  if (!node) return;
  var config;
  try { config = JSON.parse(node.content); } catch (_) { return; }
  if (!Array.isArray(config.paths) || !config.paths.includes(window.location.pathname)) return;
  if (!/^G-[A-Z0-9]+$/.test(config.ga4_id) || config.cookie_name !== "mi-consent-v2") return;

  // Campaigns use controlled non-personal slugs. Unknown/unsafe query values stop
  // measurement entirely, as vendor libraries can also inspect the browser URL.
  var validators = {
    utm_source: /^(google|facebook|instagram|viber|newsletter|partner|qr|bing|youtube)$/,
    utm_medium: /^(cpc|ppc|paid_social|social|email|referral|qr|organic|display)$/,
    utm_campaign: /^mi-[a-z0-9-]{1,60}$/,
    utm_id: /^mi-[a-z0-9-]{1,60}$/,
    utm_content: /^mi-[a-z0-9-]{1,60}$/,
    gclid: /^[A-Za-z0-9_-]{20,200}$/,
    gbraid: /^[A-Za-z0-9_-]{20,200}$/,
    wbraid: /^[A-Za-z0-9_-]{20,200}$/,
    locale: /^(sr|sr-Cyrl|bs|hr)$/,
    page: /^[1-9][0-9]{0,5}$/,
    tab: /^(trka|bodovi|pravila|zajednistvo)$/,
    zona: /^(gradska|seoska|grad|selo|urban|rural)$/,
    izvor: /^(trka|vodic|pocetna|milica)$/
  };
  var incoming = new URLSearchParams(window.location.search);
  var safeQuery = true;
  incoming.forEach(function (value, key) {
    if (!validators[key] || !validators[key].test(value) || incoming.getAll(key).length !== 1) safeQuery = false;
  });
  if (!safeQuery || window.location.hash) return;
  window.miAnalyticsInitialized = true;
  var analytics = false, marketing = false, googleStarted = false;
  var gaStarted = false, adsStarted = false, cfStarted = false;
  var adsId = /^AW-[0-9]+$/.test(config.google_ads_id || "") ? config.google_ads_id : "";
  var baseLocation = window.location.origin + window.location.pathname;
  var pageTitle = "MI! | " + window.location.pathname;
  var pageReferrer = "", cfSafe = !window.location.search;
  try {
    if (document.referrer) {
      var ref = new URL(document.referrer);
      pageReferrer = ref.origin + "/";
      cfSafe = cfSafe && !ref.search && !ref.hash && (
        ref.pathname === "/" || (ref.origin === window.location.origin && config.paths.includes(ref.pathname))
      );
    }
  } catch (_) { cfSafe = false; }

  function gtag() { window.dataLayer.push(arguments); }
  function script(src) {
    var el = document.createElement("script");
    el.async = true; el.src = src; el.referrerPolicy = "no-referrer";
    return el;
  }
  function pageLocation() {
    var query = new URLSearchParams();
    incoming.forEach(function (value, key) {
      if (key.indexOf("utm_") === 0 || (marketing && ["gclid", "gbraid", "wbraid"].includes(key))) query.set(key, value);
    });
    return baseLocation + (query.toString() ? "?" + query.toString() : "");
  }
  function consentValues() {
    return { analytics_storage: analytics ? "granted" : "denied",
      ad_storage: marketing ? "granted" : "denied", ad_user_data: marketing ? "granted" : "denied",
      ad_personalization: "denied" };
  }
  var sharedCookieDomain = config.cookie_domain === "fondacijabijeljina.com" &&
    window.location.hostname === "mi.fondacijabijeljina.com" ? config.cookie_domain : window.location.hostname;

  function forgetCookies(removeAnalytics, removeMarketing) {
    document.cookie.split(";").forEach(function (entry) {
      var name = entry.trim().split("=")[0];
      var ownAnalytics = name === "_ga" || name === "_ga_" + config.ga4_id.slice(2);
      var ownAds = /^_gcl_(aw|au|dc|gb|gs)$/.test(name);
      if (!(removeAnalytics && ownAnalytics) && !(removeMarketing && ownAds)) return;
      ["", window.location.hostname, sharedCookieDomain].forEach(function (domain) {
        document.cookie = name + "=; Max-Age=0; Path=/; SameSite=Lax; Secure" + (domain ? "; Domain=" + domain : "");
      });
    });
  }
  function settings() {
    var options = {
      send_page_view: false, allow_google_signals: false, allow_ad_personalization_signals: false,
      allow_enhanced_conversions: false, cookie_domain: sharedCookieDomain,
      page_location: pageLocation(), page_referrer: pageReferrer, page_title: pageTitle
    };
    // Omit absent values: empty campaign overrides can suppress click-ID attribution.
    var campaigns = { utm_source: "campaign_source", utm_medium: "campaign_medium",
      utm_campaign: "campaign_name", utm_id: "campaign_id", utm_content: "campaign_content" };
    Object.keys(campaigns).forEach(function (key) {
      if (incoming.has(key)) options[campaigns[key]] = incoming.get(key);
    });
    return options;
  }
  function consent(state) {
    var nextAnalytics = !!state && state.analytics === true;
    var nextMarketing = !!state && state.marketing === true;
    var removedAnalytics = analytics && !nextAnalytics, removedMarketing = marketing && !nextMarketing;
    analytics = nextAnalytics; marketing = nextMarketing;
    window["ga-disable-" + config.ga4_id] = !analytics;
    if (googleStarted) {
      gtag("consent", "update", consentValues());
      gtag("set", "ads_data_redaction", !marketing);
    }
    if (removedAnalytics || removedMarketing) {
      forgetCookies(removedAnalytics, removedMarketing);
      // Remove already-loaded vendors; the new document reads the saved choice.
      window.location.reload();
      return;
    }
    var needsGoogle = (analytics && config.ga4_enabled === true) || (marketing && adsId);
    if (needsGoogle && !googleStarted) {
      googleStarted = true;
      window.dataLayer = window.dataLayer || [];
      gtag("consent", "default", { analytics_storage: "denied", ad_storage: "denied", ad_user_data: "denied", ad_personalization: "denied" });
      gtag("consent", "update", consentValues());
      gtag("set", "ads_data_redaction", !marketing);
      gtag("set", "url_passthrough", false);
      gtag("set", "allow_ad_personalization_signals", false);
      gtag("js", new Date());
      document.head.appendChild(script("https://www.googletagmanager.com/gtag/js?id=" + (analytics && config.ga4_enabled === true ? config.ga4_id : adsId)));
    }
    if (analytics && config.ga4_enabled === true && !gaStarted) {
      gaStarted = true;
      // Remove legacy MI-scoped identifiers before reading the shared parent cookie.
      // This leaves the foundation's parent-domain identifiers intact.
      if (sharedCookieDomain !== window.location.hostname) {
        ["_ga", "_ga_SEHNTQGXJ3", "_ga_" + config.ga4_id.slice(2)].forEach(function (name) {
          ["", window.location.hostname].forEach(function (domain) {
            document.cookie = name + "=; Max-Age=0; Path=/; SameSite=Lax; Secure" + (domain ? "; Domain=" + domain : "");
          });
        });
      }
      gtag("config", config.ga4_id, settings());
      gtag("event", "page_view", { send_to: config.ga4_id, page_location: pageLocation(), page_referrer: pageReferrer, page_title: pageTitle });
    }
    // Destination is only configured when the owner supplies a real AW ID.
    // No conversion event or invented success is emitted from CTA clicks.
    if (marketing && adsId && !adsStarted) {
      adsStarted = true;
      gtag("config", adsId, settings());
    }
    if (analytics && cfSafe && !cfStarted && /^[a-f0-9]{32}$/.test(config.cloudflare_token)) {
      cfStarted = true;
      var beacon = script("https://static.cloudflareinsights.com/beacon.min.js");
      beacon.setAttribute("data-cf-beacon", JSON.stringify({ token: config.cloudflare_token, spa: false }));
      document.head.appendChild(beacon);
    }
  }

  // Only fixed navigation actions; never text, user identifiers, query strings,
  // arbitrary hrefs, form events or claims that registration/donation succeeded.
  var actions = {
    "/registracija": "registration_cta", "/users/sign_up": "registration_cta",
    "/biceriseno/vodic": "guide_cta", "/biceriseno/volontiranje": "volunteer_cta",
    "/biceriseno/projekti": "projects_cta", "/processes": "participation_cta",
    "/biceriseno/prijave/new": "report_cta", "/biceriseno/mi-bot": "milica_cta"
  };
  document.addEventListener("click", function (event) {
    if (!analytics || !gaStarted) return;
    var link = event.target.closest && event.target.closest("a[href]");
    if (!link) return;
    var destination;
    try { destination = new URL(link.getAttribute("href"), window.location.href); } catch (_) { return; }
    if (destination.origin !== window.location.origin || !actions[destination.pathname]) return;
    gtag("event", "navigation_click", { send_to: config.ga4_id, action_name: actions[destination.pathname],
      page_location: pageLocation(), page_referrer: pageReferrer, page_title: pageTitle, transport_type: "beacon" });
  });
  ["pushState", "replaceState"].forEach(function (method) {
    var original = window.history[method];
    window.history[method] = function (state, title, url) {
      if ((googleStarted || cfStarted) && url != null && new URL(url, window.location.href).href !== window.location.href) {
        window.location.assign(new URL(url, window.location.href).href); return;
      }
      return original.apply(window.history, arguments);
    };
  });
  window.addEventListener("popstate", function () { if (googleStarted || cfStarted) window.location.reload(); });
  window.addEventListener("hashchange", function () { if (googleStarted || cfStarted) window.location.reload(); });
  document.addEventListener("dataconsent", function (event) { consent(event.detail); });
  try {
    var prefix = config.cookie_name + "=";
    var cookie = document.cookie.split(";").map(function (value) { return value.trim(); }).find(function (value) { return value.indexOf(prefix) === 0; });
    if (cookie) consent(JSON.parse(decodeURIComponent(cookie.slice(prefix.length))));
  } catch (_) { /* Invalid or legacy consent never grants permission. */ }
})();
