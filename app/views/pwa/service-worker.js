// Compatibility endpoint for Rails PWA helpers. Decidim registers /sw.js from
// its JavaScript bundle; keep this path equivalent if a browser or integration
// registers /service-worker.js directly.
importScripts("/sw.js");
