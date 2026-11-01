import {
  imageCache,
  staticResourceCache,
  offlineFallback
} from "workbox-recipes";
import { registerRoute } from "workbox-routing";
import { NetworkOnly } from "workbox-strategies";
import { clientsClaim } from "workbox-core";

self.__WB_DISABLE_DEV_LOGS = true;

// Take control of existing clients ASAP so this worker REPLACES the previous
// (buggy NetworkFirst) worker on the next navigation instead of waiting for
// every tab to close — otherwise returning visitors keep being served stale or
// wrong pages by the old service worker (the audited navigation hijack).
self.skipWaiting();
clientsClaim();

// InjectManifest requires this reference even though this worker relies on
// runtime caching recipes rather than precacheAndRoute.
// eslint-disable-next-line no-unused-vars
const manifestEntries = self.__WB_MANIFEST;

const PRIVATE_NAVIGATION_PATHS = [
  "/admin/",
  "/system/",
  "/users/",
  "/account",
  "/profiles/",
  "/notifications",
  "/conversations",
  "/biceriseno/moj-nalog",
  "/biceriseno/moj-doprinos",
  "/biceriseno/projekti/novi",
  "/biceriseno/projekti/prijave/",
  "/biceriseno/komsiluk",
  "/biceriseno/komsiluk-board",
  "/biceriseno/chat",
  "/biceriseno/v/",
  "/biceriseno/viber"
];

const PUBLIC_NAVIGATION_PATTERNS = [
  /^\/$/,
  /^\/offline\/?$/,
  /^\/biceriseno\/?$/,
  /^\/biceriseno\/prijave\/?$/,
  /^\/biceriseno\/prijave\/(?!new\/?$)[^/]+\/?$/,
  /^\/biceriseno\/mapa\/?$/,
  /^\/biceriseno\/mapa-problema\/?$/,
  /^\/biceriseno\/donacije\/?$/,
  /^\/biceriseno\/projekti\/?$/,
  /^\/biceriseno\/projekti\/\d+\/?$/,
  /^\/biceriseno\/podrzi\/?$/,
  /^\/biceriseno\/uticaj\/?$/,
  /^\/biceriseno\/mi-bot\/?$/,
  /^\/biceriseno\/zajednistvo\/?$/,
  /^\/biceriseno\/volontiranje\/?$/,
  /^\/biceriseno\/mjesne-zajednice(?:\/[^/]+)?\/?$/
];

const isPrivateNavigationPath = (pathname) =>
  PRIVATE_NAVIGATION_PATHS.some((path) => pathname === path || pathname.startsWith(path));

const isPublicNavigationPath = (pathname) =>
  PUBLIC_NAVIGATION_PATTERNS.some((pattern) => pattern.test(pathname));

self.addEventListener("push", (event) => {
  const payload = event.data
    ? event.data.json()
    : {};
  const { title, ...opts } = payload;
  if (!title) {
    return;
  }

  event.waitUntil(self.registration.showNotification(title, { ...opts }).then(async () => {
    const data = opts.data || {};
    if (!data.receipt_url || !data.receipt_token) return;
    const receiptUrl = new URL(data.receipt_url, self.location.origin);
    if (receiptUrl.origin !== self.location.origin) return;
    // Display completion is observable; a person reading it is not. The
    // expiring signed token acknowledges only this recipient/revision.
    try {
      await fetch(receiptUrl.href, {
        method: "POST", credentials: "omit", cache: "no-store",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ token: data.receipt_token })
      });
    } catch (_error) {
      // Offline ACK remains unknown and can lead to the bounded fallback.
    }
  }));
});

self.addEventListener("notificationclick", (event) => {
  event.notification.close();
  let targetUrl = null;
  try {
    const target = new URL(event.notification.data?.url || "/notifications", self.location.origin);
    if (target.origin !== self.location.origin) {
      return;
    }
    targetUrl = target.href;
  } catch (_error) {
    return;
  }

  event.waitUntil(
    self.clients.matchAll({ type: "window", includeUncontrolled: true }).then((clientsArr) => {
      const windowToFocus = clientsArr.find(
        (windowClient) => windowClient.url === targetUrl
      );
      if (windowToFocus) {
        return windowToFocus.focus();
      }
      return self.clients.
        openWindow(targetUrl).
        then((windowClient) => windowClient && windowClient.focus());

    })
  );
});

// Navigations are NEVER served from a navigation cache. The previous build used
// NetworkFirst with networkTimeoutSeconds: 3 on a shared "mi-public-pages" cache,
// which (a) swapped in a STALE cached page after a 3s timeout even while online
// and (b) let cross-page/redirect/opaque (status 0) responses contaminate the
// cache so one URL could resolve to a DIFFERENT page (the audited hijack:
// /podrzi rendered Home, chat on /uticaj bounced to /mjesne-zajednice, and a
// false "offline" banner showed online). Both private and public navigations now
// use NetworkOnly: the browser always fetches the live page for the requested
// URL, so a navigation can never resolve to a different or stale cached page.
//
// The /offline fallback is preserved for GENUINE offline only: when a navigation
// fetch rejects (navigator offline / network failure), NetworkOnly throws and the
// offlineFallback catch handler (setCatchHandler) returns /offline. A slow-but-
// online response no longer triggers the fallback because there is no timeout.
registerRoute(
  ({ request, url }) =>
    request.mode === "navigate" &&
    (isPrivateNavigationPath(url.pathname) || isPublicNavigationPath(url.pathname)),
  new NetworkOnly()
);

staticResourceCache();
imageCache();

offlineFallback({ pageFallback: "/offline" });
