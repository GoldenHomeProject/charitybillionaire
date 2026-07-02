// Funnel Cloudflare's automatic *.pages.dev hostname to the canonical, WAF-geofenced
// domain (charitybillionaire.com). Loaded same-origin in <head> so it runs before the
// page renders (no flash) and complies with the strict CSP (script-src 'self').
// The .pages.dev URL can't be deleted, so this makes charitybillionaire.com the single
// front door — all traffic flows through the country geofence.
(function () {
  if (location.hostname.endsWith(".pages.dev")) {
    location.replace("https://charitybillionaire.com" + location.pathname + location.search + location.hash);
  }
})();
