// Dismissal is per signed-in account on this browser, never a server-wide opt-in.
const pushOfferChoices = new Map();
const pushOfferChoice = (key, value) => {
  if (!key) {
    return null;
  }
  try {
    if (typeof value === "undefined") {
      return window.localStorage.getItem(key) || pushOfferChoices.get(key);
    }
    if (value) {
      window.localStorage.setItem(key, value);
    }
    else {
      window.localStorage.removeItem(key);
    }
  } catch (_error) {
    // Browser storage may be unavailable. Keep this visit usable.
  }
  if (typeof value === "undefined") {
    return pushOfferChoices.get(key);
  }
  pushOfferChoices.set(key, value);
  return value;
};

const supportsPush = () => "serviceWorker" in navigator && "PushManager" in window && "Notification" in window;
const needsHomeScreen = () => {
  const ios = (/iPad|iPhone|iPod/).test(navigator.userAgent) ||
    (navigator.platform === "MacIntel" && navigator.maxTouchPoints > 1);
  return ios && !window.matchMedia("(display-mode: standalone)").matches;
};
const fingerprintFor = async (subscription) => {
  const bytes = new TextEncoder().encode(subscription.toJSON().keys.auth);
  const digest = await window.crypto.subtle.digest("SHA-256", bytes);
  return Array.from(new Uint8Array(digest)).map((byte) => byte.toString(16).padStart(2, "0")).join("");
};
// Prefer fingerprints wherever the page publishes them: the communication
// settings page never renders subscription auth secrets or endpoint URLs.
// The auth-key list stays as the fallback for Decidim's own settings page,
// which still renders data-push-sub-keys.
const registeredSubscription = async (container, subscription) => {
  if (!subscription) {
    return false;
  }
  const fingerprintField = container.querySelector("[data-push-sub-fingerprints]");
  if (fingerprintField) {
    const fingerprints = JSON.parse(fingerprintField.value || "[]");
    return fingerprints.includes(await fingerprintFor(subscription));
  }
  const keys = JSON.parse(document.querySelector("[data-push-sub-keys]")?.value || "[]");
  return keys.includes(subscription.toJSON().keys.auth);
};

// Host override of Decidim's permission UI. Permission is requested only from
// a citizen's click; installation and permission are separate choices.
document.addEventListener("turbo:before-cache", () => {
  // Turbo clones cached pages without their event listeners. Let the restored
  // controls bind again instead of leaving an apparently enabled dead switch.
  document.querySelectorAll("[data-push-notifications-toggle]").forEach((toggle) => {
    Reflect.deleteProperty(toggle.dataset, "initialized");
    const offer = toggle.closest?.("[data-push-offer]");
    if (offer) {
      offer.hidden = true;
    }
  });
});

document.addEventListener("turbo:load", async () => {
  const container = document.querySelector("[data-push-notifications-container]");
  const toggle = container?.querySelector("[data-push-notifications-toggle]");
  if (!toggle || toggle.dataset.initialized) {
    return;
  }
  toggle.dataset.initialized = "true";
  const offer = container.hasAttribute?.("data-push-offer");
  const offerKey = document.querySelector("[data-push-offer-key]")?.dataset?.pushOfferKey;
  // The enable button is not an offer-only control any more: the
  // communication settings page uses the same one-tap button, because a
  // browser permission is a per-device act either way.
  const enableButton = container.querySelector("[data-push-enable]");
  const dismissButton = offer
    ? container.querySelector("[data-push-dismiss]")
    : null;
  dismissButton?.addEventListener("click", () => {
    pushOfferChoice(offerKey, "dismissed");
    container.hidden = true;
  });
  if (offer && pushOfferChoice(offerKey)) {
    return;
  }
  const status = container.querySelector("[data-push-status]");
  const testButton = container.querySelector("[data-push-test]");
  const say = (key) => {
    status.textContent = container.dataset[key] || container.dataset.failed;
  };
  const supported = supportsPush();
  toggle.disabled = true;
  if (!supported || needsHomeScreen()) {
    const needsInstall = needsHomeScreen();
    say(needsInstall
      ? "install"
      : "unsupported");
    if (offer) {
      container.hidden = !needsInstall;
    }
    if (enableButton) {
      enableButton.hidden = true;
    }
    return;
  }

  let registration = null;
  const request = async (url, method, body) => {
    const response = await fetch(url, {
      method,
      credentials: "same-origin",
      headers: { "Content-Type": "application/json", "X-CSRF-Token": document.querySelector("meta[name=csrf-token]")?.content },
      ...(body
        ? { body: JSON.stringify(body) }
        : {})
    });
    if (!response.ok) {
      throw new Error("Subscription request failed");
    }
  };

  try {
    // A failed or missing worker must not leave the switch hanging forever.
    registration = await Promise.race([
      navigator.serviceWorker.ready,
      new Promise((resolve, reject) => setTimeout(() => reject(new Error("Worker unavailable")), 10000))
    ]);
    const existing = await registration.pushManager.getSubscription();
    const registered = await registeredSubscription(container, existing);
    toggle.checked = window.Notification.permission === "granted" && Boolean(registered);
    toggle.disabled = window.Notification.permission === "denied";
    if (testButton) {
      testButton.disabled = !toggle.checked;
    }
    if (offer) {
      // A granted browser with no subscription may have explicitly unsubscribed
      // before this invitation existed. Leave recovery to notification settings.
      container.hidden = toggle.checked || toggle.disabled ||
        (window.Notification.permission === "granted" && !existing);
    }
    if (enableButton) {
      enableButton.disabled = toggle.disabled;
    }
    if (toggle.disabled) {
      say("blocked");
    } else {
      say(toggle.checked
        ? "enabled"
        : "ready");
    }
  } catch (_error) {
    say("failed");
    return;
  }

  enableButton?.addEventListener("click", () => {
    toggle.checked = true;
    toggle.dispatchEvent(new Event("change"));
  });
  toggle.addEventListener("change", async () => {
    const enabling = toggle.checked;
    toggle.disabled = true;
    if (enableButton) {
      enableButton.disabled = true;
    }
    try {
      if (enabling) {
        // Keep this before any other await: Safari requires user activation.
        const permission = await window.Notification.requestPermission();
        if (permission !== "granted") {
          toggle.checked = false;
          say(permission === "denied"
            ? "blocked"
            : "ready");
          return;
        }
        const applicationServerKey = new Uint8Array(JSON.parse(document.querySelector("[data-push-vapid-public-key]").value));
        let subscription = await registration.pushManager.getSubscription();
        if (!subscription) {
          subscription = await registration.pushManager.subscribe({ userVisibleOnly: true, applicationServerKey });
        }
        await request("/notifications_subscriptions", "POST", subscription);
        pushOfferChoice(offerKey, null);
        say("enabled");
        if (offer) {
          container.hidden = true;
        }
      } else {
        const subscription = await registration.pushManager.getSubscription();
        if (subscription) {
          await request(container.dataset.unsubscribeUrl, "DELETE", { fingerprint: await fingerprintFor(subscription) });
          await subscription.unsubscribe();
        }
        pushOfferChoice(offerKey, "disabled");
        say("disabled");
      }
    } catch (_error) {
      // Never display raw provider/transport errors or claim a failed save worked.
      toggle.checked = !enabling;
      say("failed");
    } finally {
      toggle.disabled = window.Notification.permission === "denied";
      if (enableButton) {
        enableButton.disabled = toggle.disabled;
      }
      if (offer && toggle.disabled) {
        container.hidden = true;
      }
      if (testButton) {
        testButton.disabled = !toggle.checked;
      }
    }
  });

  testButton?.addEventListener("click", async () => {
    testButton.disabled = true;
    try {
      const subscription = await registration.pushManager.getSubscription();
      if (!subscription) {
        throw new Error("No subscription");
      }
      const fingerprint = await fingerprintFor(subscription);
      await request(container.dataset.testUrl, "POST", { fingerprint });
      say("test_queued");
    } catch (_error) {
      say("failed");
    } finally {
      testButton.disabled = !toggle.checked;
    }
  });
});
