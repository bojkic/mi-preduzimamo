/* ============================================================
   Komšinica Milica — floating web-chat widget (vanilla JS, no deps)
   Builds a bubble + chat panel into <body> when loaded and
   talks to the host-provided chat endpoint (same-origin JSON fetch,
   CSRF + X-Requested-With). All config and localized strings come
   from window.MI_CHAT, set by /mi/mi-chat-loader.js after user intent.

   Accessibility: bubble has aria-label; panel is role=dialog, focus
   is trapped while open, Esc closes and returns focus to the bubble.
   Respects prefers-reduced-motion via CSS (no JS animation here).
   ============================================================ */
(function () {
  "use strict";

  var CFG = window.MI_CHAT || {};
  // Bail quietly if config is missing (e.g. asset cached but head not updated)
  // or if the widget is suppressed on this page (the bot showcase).
  if (!CFG || CFG.disabled) return;

  var T = CFG.i18n || {};
  var ENDPOINT = CFG.endpoint;
  var LOCATION_STATUS_ENDPOINT = CFG.locationStatusEndpoint;
  if (!ENDPOINT) return;
  var QUICK = Array.isArray(CFG.quick) ? CFG.quick : [];
  var FEEDBACK = T.feedback || {};
  var PANEL_STATE_KEY = "miChatPanel";
  var GREETING_STATE_KEY = "miChatLastGreetingAt";
  var RETURN_GREETING_AFTER_MS = 30 * 60 * 1000;
  // The server remembers a conversation for 30 minutes; the visible bubbles
  // live in THIS tab for the same window (sessionStorage), so a reload is not
  // amnesia on one side only.
  var TRANSCRIPT_KEY = "miChatTranscript";
  var TRANSCRIPT_TTL_MS = 30 * 60 * 1000;
  var TRANSCRIPT_MAX_TURNS = 12;
  var TRANSCRIPT_MAX_TEXT = 2000;
  var LOC_TTL_MS = 5 * 60 * 1000;
  var LOCATION_ACQUISITION_SKEW_MS = 60 * 1000;
  var LOCATION_MEMORY_ENABLED = CFG.locationMemoryEnabled === true;
  // Ordinary turns have a ten-second server budget. A turn that explicitly
  // asks for current location gets up to eight seconds for GPS, then a fresh
  // ten seconds for the server; the UI never pretends those budgets overlap.
  var LOCATION_TIMEOUT_MS = 8000;
  var SERVER_TIMEOUT_MS = 10000;
  var FEEDBACK_TIMEOUT_MS = 10000;
  var MAX_LOCATION_ACCURACY_METERS = 1000000;

  // ---- small DOM helpers --------------------------------------------------
  function el(tag, cls, attrs) {
    var node = document.createElement(tag);
    if (cls) node.className = cls;
    if (attrs) {
      Object.keys(attrs).forEach(function (k) { node.setAttribute(k, attrs[k]); });
    }
    return node;
  }
  function svg(markup) {
    var span = el("span", "mi-chat__ico");
    span.setAttribute("aria-hidden", "true");
    span.innerHTML = markup;
    return span.firstChild;
  }

  // ---- inline icons (same-origin, no external requests) -------------------
  var ICON_HEART =
    '<svg viewBox="0 0 24 24" fill="currentColor"><path d="M12 21s-7.5-4.6-10-9.3C.3 8 1.9 4.4 5.4 4c2-.2 3.7.8 4.6 2.3.9-1.5 2.6-2.5 4.6-2.3 3.5.4 5.1 4 3.4 7.7C19.5 16.4 12 21 12 21z"/></svg>';
  var ICON_CLOSE =
    '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round"><path d="M6 6l12 12M18 6L6 18"/></svg>';
  var ICON_SEND =
    '<svg viewBox="0 0 24 24" fill="currentColor"><path d="M3.4 3.3 21 12 3.4 20.7l2.1-7.2 8.5-1.5-8.5-1.5z"/></svg>';
  var ICON_LOCATION =
    '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.1" stroke-linecap="round" stroke-linejoin="round"><path d="M12 21s7-6.1 7-12a7 7 0 1 0-14 0c0 5.9 7 12 7 12z"/><circle cx="12" cy="9" r="2.3"/></svg>';
  var ICON_THUMBS_UP =
    '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M7 10v11"/><path d="M15 5.9 14 10h5.8a2 2 0 0 1 2 2.3l-.9 6a3 3 0 0 1-3 2.7H7"/><path d="M7 10H4a2 2 0 0 0-2 2v7a2 2 0 0 0 2 2h3"/><path d="M15 5.9V4a2 2 0 0 0-2-2l-5 8"/></svg>';
  var ICON_THUMBS_DOWN =
    '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M17 14V3"/><path d="M9 18.1 10 14H4.2a2 2 0 0 1-2-2.3l.9-6A3 3 0 0 1 6 3h11"/><path d="M17 14h3a2 2 0 0 0 2-2V5a2 2 0 0 0-2-2h-3"/><path d="M9 18.1V20a2 2 0 0 0 2 2l5-8"/></svg>';

  // ---- state --------------------------------------------------------------
  var root, panel, body, field, sendBtn, locateBtn, forgetLocationBtn, locationStatusNode, bubble, lastFocused;
  var consentWatchers = [];
  var greeted = false;
  var sending = false;
  var turnGeneration = 0;
  var lastLocation = null;
  var serverLocationActive = false;
  var serverLocationExpiresAt = 0;
  var locationStateCheckedAt = 0;
  var locationStatePromise = null;
  var lastQuickWrap = null;

  function storedPanelState() {
    try { return window.localStorage.getItem(PANEL_STATE_KEY); } catch (_err) { return null; }
  }

  function storePanelState(value) {
    try { window.localStorage.setItem(PANEL_STATE_KEY, value); } catch (_err) { /* private mode */ }
  }

  // ---- transcript persistence --------------------------------------------
  // Text bubbles only ({role: "user"|"bot", text}); feedback tokens, sticker
  // URLs, chips and error rows are never stored. Expires 30 minutes after the
  // last write, capped at twelve entries.
  function readTranscript() {
    try {
      var raw = window.sessionStorage.getItem(TRANSCRIPT_KEY);
      if (!raw) return null;
      var parsed = JSON.parse(raw);
      if (!parsed || typeof parsed.at !== "number" || !Array.isArray(parsed.turns)) return null;
      if (Date.now() - parsed.at > TRANSCRIPT_TTL_MS) { clearTranscript(); return null; }
      var turns = parsed.turns.filter(function (turn) {
        return turn && (turn.role === "user" || turn.role === "bot") && typeof turn.text === "string" && turn.text;
      });
      return turns.length ? turns.slice(-TRANSCRIPT_MAX_TURNS) : null;
    } catch (_err) {
      return null;
    }
  }

  function rememberTurn(role, text) {
    var value = text == null ? "" : String(text);
    if (!value) return;
    try {
      var turns = readTranscript() || [];
      turns.push({ role: role, text: value.slice(0, TRANSCRIPT_MAX_TEXT) });
      window.sessionStorage.setItem(TRANSCRIPT_KEY, JSON.stringify({ at: Date.now(), turns: turns.slice(-TRANSCRIPT_MAX_TURNS) }));
    } catch (_err) { /* private mode or quota */ }
  }

  function clearTranscript() {
    try { window.sessionStorage.removeItem(TRANSCRIPT_KEY); } catch (_err) { /* private mode */ }
  }

  // Re-renders the stored bubbles (no feedback, no chips) and says so.
  // Returns true when something was restored, so the greeting can be skipped.
  function restoreTranscript() {
    var turns = readTranscript();
    if (!turns) return false;
    turns.forEach(function (turn) { addBubble(turn.text, turn.role === "user"); });
    addSystemBubble(T.resumed || "Nastavljamo gdje smo stali.");
    return true;
  }

  // ---- markdown-lite link rendering (safe) --------------------------------
  // Replies are untrusted data. Build text and anchors as DOM nodes so a
  // hostile reply can never provide markup or an executable attribute.
  function linkPunctuation(url) {
    var value = url;
    while (/[.,;:!?]$/.test(value)) value = value.slice(0, -1);
    while (/[\)\]\}]$/.test(value)) {
      var closing = value.charAt(value.length - 1);
      var opening = closing === ")" ? "(" : closing === "]" ? "[" : "{";
      var opens = (value.match(new RegExp("\\" + opening, "g")) || []).length;
      var closes = (value.match(new RegExp("\\" + closing, "g")) || []).length;
      if (closes <= opens) break;
      value = value.slice(0, -1);
    }
    return value;
  }

  function validatedLink(url) {
    if (!url || /[\\\u0000-\u001f]/.test(url)) return null;
    var external = /^https?:\/\//i.test(url);
    var rootRelative = /^\/(?!\/)/.test(url);
    if (!external && !rootRelative) return null;
    try {
      var parsed = new URL(url, window.location.origin);
      if (parsed.protocol !== "http:" && parsed.protocol !== "https:") return null;
      if (rootRelative && parsed.origin !== window.location.origin) return null;
      return url;
    } catch (_err) {
      return null;
    }
  }

  // Authentication rotates the shared browser session and its CSRF token.
  // Continue such a handoff in the current tab, so returning to Milica uses
  // the freshly loaded page instead of an abandoned pre-login chat tab.
  //
  // Registration belongs here for exactly the same reason — it calls
  // reset_session — and it used to arrive as /milica/prijava, which is why one
  // literal was enough. It no longer does: a register answer now keeps the
  // configured registration path, because the ticket that rewrote it degraded
  // to the LOGIN form once its ten minutes were up. So the path is read from
  // config rather than typed, or this file would reintroduce the hardcoded
  // path the server side was just cleaned of.
  function sameTabPaths() {
    var configured = typeof CFG.registrationPath === "string" ? CFG.registrationPath : "";
    return configured ? ["/milica/prijava", configured] : ["/milica/prijava"];
  }

  function replyLinkTarget(href) {
    var parsed = new URL(href, window.location.origin);
    if (parsed.origin !== window.location.origin) return "_blank";

    return sameTabPaths().indexOf(parsed.pathname) === -1 ? "_blank" : "_self";
  }

  function appendSafeText(container, text) {
    var source = text == null ? "" : String(text);
    var matcher = /(?:https?:\/\/|\/(?!\/))[^\s<>"']+/gi;
    var cursor = 0;
    var match;
    while ((match = matcher.exec(source))) {
      var raw = match[0];
      var candidate = linkPunctuation(raw);
      // The negative lookahead prevents a match at the first slash of a
      // protocol-relative URL; also reject a second-slash match on the next
      // regex position so `//host` stays plain text in its entirety.
      var protocolRelative = raw.charAt(0) === "/" && match.index > 0 && source.charAt(match.index - 1) === "/";
      var escapedSlash = raw.charAt(0) === "/" && match.index > 0 && source.charAt(match.index - 1) === "\\";
      var prefixedScheme = raw.charAt(0) === "/" && /[A-Za-z][A-Za-z0-9+.-]*:$/.test(source.slice(0, match.index));
      var rootInMarkup = raw.charAt(0) === "/" && match.index > 0 && /[<>"'=]/.test(source.charAt(match.index - 1));
      // Units, zone names and ratios (KM/h, crvena/I, 3/4) are not paths.
      // Test the prefix by Unicode code point, including combining marks.
      var rootInWord = raw.charAt(0) === "/" && /[\p{L}\p{M}\p{N}_]$/u.test(source.slice(0, match.index));
      var href = protocolRelative || escapedSlash || prefixedScheme || rootInMarkup || rootInWord ? null : validatedLink(candidate);
      var end = match.index + (href ? candidate.length : raw.length);
      if (match.index > cursor) container.appendChild(document.createTextNode(source.slice(cursor, match.index)));
      if (href) {
        var anchor = el("a", null, { href: href, target: replyLinkTarget(href), rel: "noopener noreferrer" });
        anchor.textContent = candidate;
        container.appendChild(anchor);
      } else {
        container.appendChild(document.createTextNode(raw));
      }
      cursor = end;
      matcher.lastIndex = end;
    }
    if (cursor < source.length) container.appendChild(document.createTextNode(source.slice(cursor)));
  }

  // ---- transcript rendering ----------------------------------------------
  function scrollToEnd() { body.scrollTop = body.scrollHeight; }

  function addBubble(text, outgoing) {
    var row = el("div", "mi-chat__row " + (outgoing ? "is-out" : "is-in"));
    var msg = el("div", "mi-chat__bubble-msg");
    appendSafeText(msg, text);
    row.appendChild(msg);
    body.appendChild(row);
    scrollToEnd();
    return row;
  }

  // A centred one-liner that is not part of the conversation (never stored).
  function addSystemBubble(text) {
    var row = el("div", "mi-chat__row is-system");
    var msg = el("div", "mi-chat__system-msg", { role: "status" });
    msg.textContent = text;
    row.appendChild(msg);
    body.appendChild(row);
    scrollToEnd();
    return row;
  }

  // The error row carries a retry that resubmits the same text (the input is
  // refilled as well, so both recovery paths are on screen).
  function addErrorBubble(text) {
    var row = addBubble(T.error || "Sorry, something went wrong.", false);
    row.classList.add("is-error");
    var retry = el("button", "mi-chat__retry", { type: "button" });
    retry.textContent = T.retry || "Pokušaj ponovo";
    retry.addEventListener("click", function () {
      row.remove();
      submit(text, { resend: true });
    });
    row.appendChild(retry);
    scrollToEnd();
    return row;
  }

  function validFeedback(feedback) {
    return feedback && feedback.id && feedback.url && feedback.token;
  }

  // One compact invitation and the two rating choices on every answer.
  function addFeedback(row, feedback) {
    if (!validFeedback(feedback)) return;

    var wrap = el("div", "mi-chat__feedback", { "aria-label": FEEDBACK.label || "Rate this answer" });
    var prompt = el("span", "mi-chat__feedback-prompt");
    prompt.textContent = FEEDBACK.prompt || "Help Milica learn:";
    var status = el("span", "mi-chat__feedback-status", { role: "status", "aria-live": "polite" });
    var up = feedbackButton("helpful", FEEDBACK.helpful || "Helpful", ICON_THUMBS_UP);
    var down = feedbackButton("not_helpful", FEEDBACK.not_helpful || "Not helpful", ICON_THUMBS_DOWN);

    up.addEventListener("click", function () { submitFeedback(feedback, "helpful", wrap, status); });
    down.addEventListener("click", function () { submitFeedback(feedback, "not_helpful", wrap, status); });

    var actions = el("span", "mi-chat__feedback-actions");
    actions.appendChild(up);
    actions.appendChild(down);
    wrap.appendChild(prompt);
    wrap.appendChild(actions);
    wrap.appendChild(status);
    row.appendChild(wrap);
    scrollToEnd();
  }

  function feedbackButton(value, label, icon) {
    var button = el("button", "mi-chat__feedback-button", {
      type: "button",
      "aria-label": label,
      "aria-pressed": "false",
      "data-value": value
    });
    button.appendChild(svg(icon));
    button.appendChild(document.createTextNode(label));
    return button;
  }

  function submitFeedback(feedback, value, wrap, status) {
    var buttons = Array.prototype.slice.call(wrap.querySelectorAll(".mi-chat__feedback-button"));
    var selected = buttons.find(function (button) { return button.getAttribute("data-value") === value; });
    if (!selected || selected.disabled) return;
    buttons.forEach(function (button) { button.disabled = true; });
    status.textContent = "";

    timedFetch(feedback.url, {
      method: "POST",
      credentials: "same-origin",
      headers: {
        "Content-Type": "application/json",
        Accept: "application/json",
        "X-Requested-With": "XMLHttpRequest",
        "X-CSRF-Token": csrfToken()
      },
      body: JSON.stringify({ reply_id: feedback.id, token: feedback.token, value: value })
    }, FEEDBACK_TIMEOUT_MS, function (res) {
        if (res.status === 422) {
          var unavailable = new Error("feedback unavailable");
          unavailable.feedbackUnavailable = true;
          throw unavailable;
        }
        if (!res.ok) throw new Error("HTTP " + res.status);
        return res.json().then(function (body) {
          if (!body || body.status !== "ok") throw new Error("feedback save failed");
          return body;
        });
      })
      .then(function () {
        var shared = value === "share_question";
        buttons.forEach(function (button) {
          var own = button.getAttribute("data-value") === value;
          button.setAttribute("aria-pressed", String(own));
          // The other thumb updates this reply's existing session rating.
          // Saving the question is redundant once either thumb has saved it.
          button.disabled = own || button.getAttribute("data-value") === "share_question";
        });
        status.textContent = shared
          ? (FEEDBACK.shared || "Sačuvano. Hvala!")
          : (FEEDBACK.thanks || "Thanks for the feedback.");
      })
      .catch(function (error) {
        var unavailable = !!(error && error.feedbackUnavailable);
        buttons.forEach(function (button) { button.disabled = unavailable; });
        status.textContent = unavailable
          ? (FEEDBACK.unavailable || "This rating has expired or is unavailable. You can rate a new answer.")
          : (FEEDBACK.error || "Feedback was not saved. Please try again.");
      });
  }

  // A timeout only bounds this browser's wait. It is deliberately not treated
  // as proof that the server did not save an effect; retries remain explicit.
  function timedFetch(url, options, timeoutMs, transform) {
    var controller = null;
    if (window.AbortController) controller = new AbortController();
    var requestOptions = Object.assign({}, options);
    if (controller) requestOptions.signal = controller.signal;
    var timer;
    var request = Promise.resolve().then(function () { return fetch(url, requestOptions); })
      .then(function (response) { return transform ? transform(response) : response; });
    var timeout = new Promise(function (_resolve, reject) {
      timer = window.setTimeout(function () {
        if (controller) controller.abort();
        reject(new Error("request timeout"));
      }, timeoutMs);
    });
    return Promise.race([request, timeout]).then(function (result) {
      window.clearTimeout(timer);
      return result;
    }, function (error) {
      window.clearTimeout(timer);
      throw error;
    });
  }

  function addSticker(url, alt, staticUrl) {
    if (!url) return;
    var wrap = el("div", "mi-chat__sticker");
    var reducedMotion = window.matchMedia && window.matchMedia("(prefers-reduced-motion: reduce)").matches;
    var source = reducedMotion && staticUrl ? staticUrl : url;
    var img = el("img", null, { src: source, alt: alt || "", loading: "lazy", decoding: "async" });
    wrap.appendChild(img);
    body.appendChild(wrap);
    scrollToEnd();
  }

  // Quick-reply chips. Each chip either navigates to a page (when it carries a
  // target — `url` from the server contract, or `href` from the client-built
  // default menu) or sends a canned message. Server-sent civic-shortcut chips
  // are { label, url } or { label, send }; the client default menu uses
  // { label, href|send }. A tapped row stays on screen (the citizen may want
  // a second chip); the next reply that brings chips replaces it.
  function addQuickReplies(items) {
    if (!items || !items.length) return;
    var wrap = el("div", "mi-chat__quick");
    items.forEach(function (item) {
      var label = typeof item === "string" ? item : item.label;
      var target = item && (item.url || item.href);
      var payload = (item && item.send) || label;
      var chip = el("button", "mi-chat__chip", { type: "button" });
      chip.textContent = label;
      // Expose the configured action for accessibility/browser diagnostics.
      // The handler uses these same captured values, not mutable attributes.
      chip.setAttribute("data-mi-chat-action", target ? "navigate" : "send");
      chip.setAttribute("data-mi-chat-value", target || payload);
      chip.addEventListener("click", function () {
        if (target) {
          close();
          window.location.assign(target);
          return;
        }
        submit(payload);
      });
      wrap.appendChild(chip);
    });
    body.appendChild(wrap);
    lastQuickWrap = wrap;
    scrollToEnd();
  }

  function replaceQuickReplies(items) {
    if (!items || !items.length) return;
    if (lastQuickWrap) { lastQuickWrap.remove(); lastQuickWrap = null; }
    addQuickReplies(items);
  }

  var typingNode = null;
  var typingTimer = null;
  function showTyping() {
    if (typingNode) return;
    typingNode = el("div", "mi-chat__typing", { role: "status", "aria-live": "polite" });
    var dots = el("span", "mi-chat__typing-dots", { "aria-hidden": "true" });
    dots.appendChild(el("i"));
    dots.appendChild(el("i"));
    dots.appendChild(el("i"));
    typingNode.appendChild(dots);
    var label = el("span", "mi-chat__typing-label");
    label.textContent = T.loading || "Da vidimo šta piše, a ne šta se priča…";
    typingNode.appendChild(label);
    body.appendChild(typingNode);
    typingTimer = window.setTimeout(function () {
      if (!typingNode) return;
      label.textContent = T.long_loading || "Ovo se malo zavuklo među papire. Tražim dalje…";
    }, 4000);
    scrollToEnd();
  }
  function hideTyping() {
    if (typingTimer) { window.clearTimeout(typingTimer); typingTimer = null; }
    if (typingNode) { typingNode.remove(); typingNode = null; }
  }

  // ---- network ------------------------------------------------------------
  function csrfToken() {
    var m = document.querySelector('meta[name="csrf-token"]');
    return m ? m.getAttribute("content") : "";
  }

  function foldedText(text) {
    return String(text || "")
      .toLowerCase()
      .normalize("NFD")
      .replace(/[\u0300-\u036f]/g, "");
  }

  function markLocationShare(active, expiresAt) {
    serverLocationActive = LOCATION_MEMORY_ENABLED && active;
    serverLocationExpiresAt = serverLocationActive ?
      ((Number(expiresAt) > Date.now() / 1000) ? Number(expiresAt) * 1000 : Date.now() + TRANSCRIPT_TTL_MS) : 0;
    locationStateCheckedAt = Date.now();
    syncLocationButton();
  }

  function applyLocationMemoryState(state, expiresAt) {
    if (!LOCATION_MEMORY_ENABLED) return;
    if (state === "active") markLocationShare(true, expiresAt);
    else if (state === "inactive") markLocationShare(false);
    // "unknown" includes HTTP 200 fallbacks. Keep the last confirmed state.
  }

  function ensureLocationMemoryState() {
    if (!LOCATION_MEMORY_ENABLED || !LOCATION_STATUS_ENDPOINT) return Promise.resolve();
    if (serverLocationActive && serverLocationExpiresAt <= Date.now()) markLocationShare(false);
    if (Date.now() - locationStateCheckedAt < 60000) return Promise.resolve();
    if (locationStatePromise) return locationStatePromise;

    locationStatePromise = fetch(LOCATION_STATUS_ENDPOINT, {
      method: "GET", credentials: "same-origin", cache: "no-store",
      headers: { Accept: "application/json", "X-Requested-With": "XMLHttpRequest" }
    }).then(function (response) {
      if (!response.ok) throw new Error("location status unavailable");
      return response.json();
    }).then(function (data) {
      applyLocationMemoryState(data.location_memory_state, data.expires_at);
    }).catch(function () {
      // A status fetch cannot decide whether a retained point exists.
    }).then(function () { locationStatePromise = null; });
    return locationStatePromise;
  }

  function locationRequested(text) {
    var folded = foldedText(text);
    // Mentioning location while refusing it must not request or reuse GPS.
    if (/(?:^|[\s,])(?:bez|without|без|nemoj(?:te)?|немој(?:те)?|ne|не|do not|don't|dont)\s+[^.!?;\n]{0,60}(?:lokacij[a-z]*|локациј[\u0400-\u04FF]*|location)(?:$|[^A-Za-z\u0400-\u04FF])/.test(folded)) return false;
    var words = " " + folded.replace(/[^A-Za-z0-9\u0400-\u04FF]+/g, " ") + " ";
    return [
      "odavde", "ovdje", "ovde", "ova lokacija", "ovoj lokaciji", "ovu lokaciju",
      "trenutna lokacija", "trenutne lokacije", "trenutnoj lokaciji", "moja lokacija", "moje lokacije", "mojoj lokaciji", "moju lokaciju", "tu", "from here", "here", "my location",
      "одавде", "овдје", "овде", "ова локација", "овој локацији", "ову локацију",
      "моја локација", "моје локације", "мојој локацији", "моју локацију", "тренутна локација", "тренутне локације", "тренутној локацији"
    ].some(function (term) { return words.indexOf(" " + term + " ") !== -1; });
  }

  function freshLocation() {
    if (!lastLocation || !lastLocation.at) return null;
    if (Date.now() - lastLocation.at > LOC_TTL_MS) return null;
    return validLocation(lastLocation) ? lastLocation : null;
  }

  function finiteBounded(value, min, max) {
    if (value === null || value === undefined || String(value).trim() === "") return null;
    var number = Number(value);
    return isFinite(number) && number >= min && number <= max ? number : null;
  }

  function validLocation(location) {
    if (!location) return false;
    var age = Date.now() - Number(location.at);
    return finiteBounded(location.latitude, -90, 90) !== null &&
      finiteBounded(location.longitude, -180, 180) !== null &&
      finiteBounded(location.accuracy, 0, MAX_LOCATION_ACCURACY_METERS) !== null &&
      isFinite(age) && age >= -LOCATION_ACQUISITION_SKEW_MS && age <= LOC_TTL_MS + LOCATION_ACQUISITION_SKEW_MS &&
      location.consent === true && location.provenance === "browser_geolocation";
  }

  function syncLocationButton() {
    if (!locateBtn) return;
    if (serverLocationActive && serverLocationExpiresAt <= Date.now()) {
      serverLocationActive = false;
      serverLocationExpiresAt = 0;
      locationStateCheckedAt = 0;
    }
    locateBtn.classList.toggle("is-active", !!freshLocation() || serverLocationActive);
    if (forgetLocationBtn) forgetLocationBtn.hidden = !serverLocationActive;
    if (locationStatusNode) locationStatusNode.textContent = serverLocationActive ? (T.location_active || "Shared location active") : (T.header_status || "online");
  }

  function requestBrowserLocation() {
    return new Promise(function (resolve, reject) {
      if (!navigator.geolocation) {
        reject(new Error("geolocation unavailable"));
        return;
      }
      navigator.geolocation.getCurrentPosition(function (pos) {
        var location = {
          latitude: finiteBounded(pos.coords.latitude, -90, 90),
          longitude: finiteBounded(pos.coords.longitude, -180, 180),
          accuracy: finiteBounded(pos.coords.accuracy, 0, MAX_LOCATION_ACCURACY_METERS),
          purpose: "current_location",
          consent: true,
          provenance: "browser_geolocation",
          at: pos.timestamp
        };
        if (!validLocation(location)) {
          reject(new Error("invalid geolocation"));
          return;
        }
        lastLocation = location;
        syncLocationButton();
        resolve(lastLocation);
      }, reject, {
        enableHighAccuracy: true,
        timeout: LOCATION_TIMEOUT_MS,
        maximumAge: LOC_TTL_MS
      });
    });
  }

  function locationForMessage(text) {
    if (!locationRequested(text)) {
      lastLocation = null;
      syncLocationButton();
      return Promise.resolve(null);
    }
    return ensureLocationMemoryState().then(function () {
      var cached = freshLocation();
      lastLocation = null;
      syncLocationButton();
      if (cached) return cached;
      if (LOCATION_MEMORY_ENABLED && serverLocationActive) return null;
      if (LOCATION_MEMORY_ENABLED) addBubble(T.location_consent_copy || "Location can be used during this conversation for public questions.", false);
      return requestBrowserLocation().catch(function () { return null; });
    });
  }

  function submitPayload(text, location) {
    var payload = { message: text };
    if (location) {
      payload.location = {
        latitude: location.latitude,
        longitude: location.longitude,
        accuracy: location.accuracy,
        purpose: location.purpose,
        consent: location.consent,
        provenance: location.provenance,
        acquired_at: location.at,
        retain_for_conversation: LOCATION_MEMORY_ENABLED
      };
    }
    return payload;
  }

  // options.resend: a retry of a turn whose outgoing bubble is already on
  // screen (and already in the transcript). options.remember === false: show
  // the turn but keep it out of the stored transcript (the reset command).
  function submit(text, options) {
    options = options || {};
    text = (text || "").trim();
    if (!text || sending) return;

    if (!options.resend) {
      addBubble(text, true);
      if (options.remember !== false) rememberTurn("user", text);
    }
    field.value = "";
    autoGrow();
    sending = true;
    sendBtn.disabled = true;
    showTyping();

    var requestController = window.AbortController ? new AbortController() : null;
    var requestExpired = false;
    var requestGeneration = ++turnGeneration;
    var turnTimeout = locationRequested(text) ? LOCATION_TIMEOUT_MS + SERVER_TIMEOUT_MS : SERVER_TIMEOUT_MS;
    var rejectDeadline;
    var deadline = new Promise(function (_resolve, reject) { rejectDeadline = reject; });
    var requestTimer = window.setTimeout(function () {
      requestExpired = true;
      if (requestController) requestController.abort();
      rejectDeadline(new Error("request timeout"));
    }, turnTimeout);

    var chatRequest = locationForMessage(text)
      .then(function (location) {
        if (requestExpired) throw new Error("request timeout");
        var options = {
          method: "POST",
          credentials: "same-origin",
          headers: {
            "Content-Type": "application/json",
            Accept: "application/json",
            "X-Requested-With": "XMLHttpRequest",
            "X-CSRF-Token": csrfToken()
          },
          body: JSON.stringify(submitPayload(text, location))
        };
        if (requestController) options.signal = requestController.signal;
        return fetch(ENDPOINT, options);
      })
      .then(function (res) {
        if (!res.ok) throw new Error("HTTP " + res.status);
        return res.json();
      });
    Promise.race([chatRequest, deadline])
      .then(function (data) {
        if (requestExpired || requestGeneration !== turnGeneration) return;
        hideTyping();
        applyLocationMemoryState(data.location_memory_state, data.location_memory_expires_at);
        var replyText = data.reply || T.error || "";
        var replyRow = addBubble(replyText, false);
        if (options.remember !== false) rememberTurn("bot", data.reply || "");
        addFeedback(replyRow, data.feedback);
        if (data.sticker_url) addSticker(data.sticker_url, data.sticker_alt, data.sticker_static_url);
        replaceQuickReplies(data.quick_replies);
      })
      .catch(function () {
        if (requestGeneration !== turnGeneration) return;
        hideTyping();
        if (!field.value) {
          field.value = text;
          autoGrow();
        }
        addErrorBubble(text);
      })
      .then(function () {
        if (requestGeneration !== turnGeneration) return;
        window.clearTimeout(requestTimer);
        sending = false;
        sendBtn.disabled = false;
        syncLocationButton();
        field.focus();
      });
  }

  function prepareLocation() {
    if (sending) return;
    locateBtn.disabled = true;
    if (LOCATION_MEMORY_ENABLED) addBubble(T.location_consent_copy || "Location can be used during this conversation for public questions.", false);
    requestBrowserLocation()
      .then(function () {
        addBubble(T.location_ready || "Lokacija je spremna za sljedeće pitanje.", false);
      })
      .catch(function () {
        addBubble(T.location_error || "Ne mogu dohvatiti lokaciju. Možeš napisati adresu ili najbliže stajalište.", false);
      })
      .then(function () {
        locateBtn.disabled = false;
        syncLocationButton();
        field.focus();
      });
  }

  // ---- greeting + quick-action menu --------------------------------------
  function greet() {
    if (greeted) return;
    greeted = true;
    var previousGreeting = 0;
    try { previousGreeting = Number(window.localStorage.getItem(GREETING_STATE_KEY) || 0); } catch (_err) { /* private mode */ }
    var returning = previousGreeting > 0 && Date.now() - previousGreeting >= RETURN_GREETING_AFTER_MS;
    var greeting = returning ? T.return_greeting : T.greeting;
    if (greeting) addBubble(greeting, false);
    if (CFG.greetingMediaUrl) {
      addSticker(CFG.greetingMediaUrl, T.greeting_media_alt, CFG.greetingMediaStaticUrl);
    }
    try { window.localStorage.setItem(GREETING_STATE_KEY, String(Date.now())); } catch (_err) { /* private mode */ }
    var quick = QUICK.length ? QUICK : defaultQuick();
    addQuickReplies(quick);
  }

  // "Novi razgovor": forget this tab's transcript, start over with a fresh
  // greeting, and send the server its clear command so its 30-minute memory
  // is dropped too. The command turn itself is shown but not stored, so a
  // reload after a reset greets normally instead of replaying the reset.
  function resetConversation() {
    if (sending) return;
    clearTranscript();
    // Wait for the server's inactive result; a fallback may leave the old
    // conversation and its retained point intact.
    lastLocation = null;
    hideTyping();
    body.textContent = "";
    lastQuickWrap = null;
    greeted = false;
    greet();
    submit(T.new_conversation_send || "novi razgovor", { remember: false });
  }

  // Default quick-action menu when the host did not supply one. Use real page
  // targets for structured flows; keep budget as an inline bot question.
  function defaultQuick() {
    var q = (T.quick) || {};
    var out = [];
    var reportUrl = CFG.reportUrl || publicPath("prijave/new");
    var donateUrl = CFG.donateUrl || publicPath("donacije");
    var goodwillUrl = CFG.goodwillUrl || publicPath("moj-doprinos");
    var setupUrl = CFG.setupUrl || publicPath("verifikacija");
    var komsilukUrl = CFG.komsilukUrl || publicPath("komsiluk-board");
    if (q.report_describe && q.report_describe_send) out.push({ label: q.report_describe, send: q.report_describe_send });
    if ((q.report_form || q.report) && reportUrl) out.push({ label: q.report_form || q.report, href: reportUrl });
    if (q.idea && CFG.ideaUrl) out.push({ label: q.idea, href: CFG.ideaUrl });
    if (q.budget) out.push({ label: q.budget, send: q.budget });
    if (q.donate && donateUrl) out.push({ label: q.donate, href: donateUrl });
    if (q.goodwill && goodwillUrl) out.push({ label: q.goodwill, href: goodwillUrl });
    if (q.setup && setupUrl) out.push({ label: q.setup, href: setupUrl });
    if (q.komsiluk && komsilukUrl) out.push({ label: q.komsiluk, href: komsilukUrl });
    return out;
  }

  function publicPath(path) {
    var base = String(CFG.publicBasePath || CFG.publicMountPath || "").replace(/\/+$/, "");
    if (!base) return null;
    return base + "/" + String(path || "").replace(/^\/+/, "");
  }

  // ---- open / close + focus management -----------------------------------
  function focusables() {
    return Array.prototype.slice.call(
      panel.querySelectorAll('button, [href], textarea, input, [tabindex]:not([tabindex="-1"])')
    ).filter(function (n) { return !n.disabled && n.offsetParent !== null; });
  }

  // The panel is a near-fullscreen modal on mobile (CSS @media max-width:480px).
  // In that state the background is fully covered, so mark it aria-modal="true"
  // (it is already focus-trapped via onKeydown). On larger viewports the panel
  // is a non-blocking docked widget, so it stays aria-modal="false".
  function isFullScreenPanel() {
    return window.matchMedia("(max-width: 480px)").matches;
  }

  function syncModalState() {
    if (!panel) return;
    var modal = root.classList.contains("is-open") && isFullScreenPanel();
    panel.setAttribute("aria-modal", modal ? "true" : "false");
  }

  function open(options) {
    options = options || {};
    if (root.classList.contains("is-open")) return;
    lastFocused = document.activeElement;
    root.classList.add("is-open");
    bubble.setAttribute("aria-expanded", "true");
    storePanelState("open");
    syncModalState();
    greet();
    ensureLocationMemoryState();
    // Focus the input after the panel paints — on a keyboard device only. On
    // a phone the focus would raise the on-screen keyboard at once and slide
    // the header (and its close button) out of view; the citizen taps the
    // field when they are ready to type.
    var touchDevice = window.matchMedia && window.matchMedia("(pointer: coarse)").matches;
    if (!options.restore && !touchDevice) window.requestAnimationFrame(function () { field.focus(); });
  }

  function close() {
    if (!root.classList.contains("is-open")) return;
    root.classList.remove("is-open");
    bubble.setAttribute("aria-expanded", "false");
    storePanelState("minimized");
    syncModalState();
    if (lastFocused && lastFocused.focus) lastFocused.focus();
    else bubble.focus();
  }

  function onKeydown(e) {
    if (!root.classList.contains("is-open")) return;
    if (e.key === "Escape") { e.preventDefault(); close(); return; }
    if (e.key !== "Tab") return;
    // Focus trap.
    var items = focusables();
    if (!items.length) return;
    var first = items[0];
    var last = items[items.length - 1];
    if (e.shiftKey && document.activeElement === first) {
      e.preventDefault(); last.focus();
    } else if (!e.shiftKey && document.activeElement === last) {
      e.preventDefault(); first.focus();
    }
  }

  // ---- textarea auto-grow + Enter-to-send --------------------------------
  function autoGrow() {
    field.style.height = "auto";
    field.style.height = Math.min(field.scrollHeight, 96) + "px";
  }

  // ---- Decidim cookie banner spacing -------------------------------------
  function consentBannerVisible(banner) {
    return !!(banner && !banner.hidden && banner.getClientRects().length);
  }

  function updateConsentOffset() {
    if (!root) return;

    var banner = document.getElementById("dc-dialog-wrapper");
    var visible = consentBannerVisible(banner);
    root.classList.toggle("mi-chat--consent-open", visible);

    if (visible) {
      root.style.setProperty("--mi-consent-offset", Math.ceil(banner.getBoundingClientRect().height) + "px");
    } else {
      root.style.removeProperty("--mi-consent-offset");
    }
  }

  function watchConsentBanner() {
    var banner = document.getElementById("dc-dialog-wrapper");
    if (!banner) return;

    if ("MutationObserver" in window) {
      var observer = new MutationObserver(updateConsentOffset);
      observer.observe(banner, { attributes: true, attributeFilter: ["hidden", "class", "style"] });
      consentWatchers.push(observer);
    }

    if ("ResizeObserver" in window) {
      var resizeObserver = new ResizeObserver(updateConsentOffset);
      resizeObserver.observe(banner);
      consentWatchers.push(resizeObserver);
    }

    window.addEventListener("resize", updateConsentOffset);
    document.addEventListener("dataconsent", updateConsentOffset);
    updateConsentOffset();
    window.setTimeout(updateConsentOffset, 0);
  }

  // ---- build --------------------------------------------------------------
  function build() {
    root = el("div", "mi-chat");
    root.id = "mi-chat";

    // Bubble launcher
    bubble = el("button", "mi-chat__bubble", {
      type: "button",
      "aria-label": T.aria_open || T.bubble_label || "Chat",
      "aria-haspopup": "dialog",
      "aria-expanded": "false",
      "aria-controls": "mi-chat-panel"
    });
    var bIcon = el("span", "mi-chat__bubble-icon");
    bIcon.appendChild(svg(ICON_HEART));
    bubble.appendChild(bIcon);
    if (T.bubble_label) {
      var bLabel = el("span", "mi-chat__bubble-label");
      bLabel.textContent = T.bubble_label;
      bubble.appendChild(bLabel);
    }
    bubble.addEventListener("click", open);

    // Panel
    panel = el("div", "mi-chat__panel", {
      id: "mi-chat-panel",
      role: "dialog",
      "aria-modal": "false",
      "aria-label": T.header_title || "Milica"
    });

    // Header
    var header = el("div", "mi-chat__header");
    var avatar = el("div", "mi-chat__avatar");
    if (CFG.avatarUrl) {
      var aImg = el("img", null, { src: CFG.avatarUrl, alt: "" });
      avatar.appendChild(aImg);
    } else {
      avatar.appendChild(svg(ICON_HEART));
    }
    var id = el("div", "mi-chat__id");
    var name = el("div", "mi-chat__name");
    name.textContent = T.header_title || "Milica";
    var status = el("div", "mi-chat__status");
    status.textContent = T.header_status || "online";
    locationStatusNode = status;
    id.appendChild(name);
    id.appendChild(status);
    var closeBtn = el("button", "mi-chat__close", {
      type: "button",
      "aria-label": T.aria_close || "Close"
    });
    closeBtn.appendChild(svg(ICON_CLOSE));
    closeBtn.addEventListener("click", close);
    header.appendChild(avatar);
    header.appendChild(id);
    header.appendChild(closeBtn);

    // Header tools: always-visible "what can you do" and "new conversation",
    // so neither depends on a chip that may have scrolled away.
    var tools = el("div", "mi-chat__tools");
    var helpBtn = el("button", "mi-chat__tool", { type: "button", "data-mi-chat-tool": "capabilities" });
    helpBtn.textContent = T.capabilities || "Šta možeš?";
    helpBtn.addEventListener("click", function () { submit(T.capabilities_send || "šta možeš"); });
    var resetBtn = el("button", "mi-chat__tool", { type: "button", "data-mi-chat-tool": "reset" });
    resetBtn.textContent = T.new_conversation || "Novi razgovor";
    resetBtn.addEventListener("click", resetConversation);
    tools.appendChild(helpBtn);
    tools.appendChild(resetBtn);
    if (LOCATION_MEMORY_ENABLED) {
      forgetLocationBtn = el("button", "mi-chat__tool", { type: "button", "data-mi-chat-tool": "forget-location" });
      forgetLocationBtn.textContent = T.forget_location || "Forget location";
      forgetLocationBtn.addEventListener("click", function () { submit(T.forget_location_send || "forget my location", { remember: false }); });
      tools.appendChild(forgetLocationBtn);
      syncLocationButton();
    }

    // Body
    body = el("div", "mi-chat__body", { role: "log", "aria-live": "polite", "aria-atomic": "false" });

    // Input bar
    var inputbar = el("div", "mi-chat__inputbar");
    field = el("textarea", "mi-chat__field", {
      rows: "1",
      placeholder: T.input_placeholder || "",
      "aria-label": T.input_placeholder || "Message",
      autocomplete: "off"
    });
    field.addEventListener("input", autoGrow);
    field.addEventListener("keydown", function (e) {
      if (e.key === "Enter" && !e.shiftKey) {
        e.preventDefault();
        submit(field.value);
      }
    });
    sendBtn = el("button", "mi-chat__send", {
      type: "button",
      "aria-label": T.aria_send || "Send"
    });
    sendBtn.appendChild(svg(ICON_SEND));
    sendBtn.addEventListener("click", function () { submit(field.value); });
    locateBtn = el("button", "mi-chat__locate", {
      type: "button",
      "aria-label": T.aria_location || "Use current location"
    });
    locateBtn.appendChild(svg(ICON_LOCATION));
    locateBtn.addEventListener("click", prepareLocation);
    syncLocationButton();
    inputbar.appendChild(field);
    inputbar.appendChild(locateBtn);
    inputbar.appendChild(sendBtn);

    panel.appendChild(header);
    panel.appendChild(tools);
    panel.appendChild(body);
    panel.appendChild(inputbar);

    root.appendChild(bubble);
    root.appendChild(panel);
    document.body.appendChild(root);

    // A transcript from this tab (≤ 30 min old) comes back before any
    // greeting; when it does, the greeting is skipped.
    if (restoreTranscript()) greeted = true;

    watchConsentBanner();
    document.addEventListener("keydown", onKeydown);
    // Re-evaluate aria-modal when the viewport crosses the mobile breakpoint
    // while the panel is open (e.g. orientation change).
    window.addEventListener("resize", syncModalState);
    function prefill(draft) {
      field.value = String(draft || "").slice(0, 1000);
      window.MI_CHAT_PENDING_DRAFT = null;
      autoGrow();
      field.focus();
    }
    window.MI_CHAT_WIDGET = { open: open, close: close, prefill: prefill };
    if (window.MI_CHAT_PENDING_DRAFT) prefill(window.MI_CHAT_PENDING_DRAFT);
  }

  function init() {
    // Never mount twice (e.g. Turbo-style re-inits).
    if (document.getElementById("mi-chat")) return;
    build();
    if (CFG.autoOpen || storedPanelState() === "open") {
      window.requestAnimationFrame(function () { open({ restore: !!CFG.restoreOpen }); });
    }
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", init);
  } else {
    init();
  }
})();
