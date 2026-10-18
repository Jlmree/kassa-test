// Houdt de app-bestanden lokaal bij, zodat de kassa direct opstart.
// Gegevens (database en inloggen) gaan altijd langs het netwerk.
const CACHE = 'kassa-v2';
self.addEventListener('install', () => { self.skipWaiting(); });
self.addEventListener('activate', (e) => {
  e.waitUntil(caches.keys().then((ks) => Promise.all(ks.filter((k) => k !== CACHE).map((k) => caches.delete(k)))).then(() => self.clients.claim()));
});
self.addEventListener('fetch', (e) => {
  const url = new URL(e.request.url);
  if (e.request.method !== 'GET' || url.origin !== location.origin) return;
  const bewaar = (r) => { if (r.ok) { const k = r.clone(); caches.open(CACHE).then((c) => c.put(e.request, k)); } return r; };
  if (e.request.mode === 'navigate' || url.pathname.endsWith('/config.js')) {
    // Pagina en instellingen: netwerk eerst, zodat een nieuwe versie meteen zichtbaar is.
    e.respondWith(fetch(e.request).then(bewaar).catch(() => caches.match(e.request)));
  } else if (url.pathname.includes('/assets/')) {
    // Bestanden met een hash in de naam veranderen nooit: cache eerst.
    e.respondWith(caches.match(e.request).then((m) => m || fetch(e.request).then(bewaar)));
  }
  // Al het andere (o.a. /rest/v1 en /auth/v1) gaat ongemoeid naar de server.
});
