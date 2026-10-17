// Houdt de app-bestanden lokaal bij, zodat de kassa direct opstart.
// Gegevens (Supabase) gaan altijd langs het netwerk.
const CACHE = 'kassa-v1';
self.addEventListener('install', (e) => { self.skipWaiting(); });
self.addEventListener('activate', (e) => {
  e.waitUntil(caches.keys().then((ks) => Promise.all(ks.filter((k) => k !== CACHE).map((k) => caches.delete(k)))).then(() => self.clients.claim()));
});
self.addEventListener('fetch', (e) => {
  const url = new URL(e.request.url);
  if (e.request.method !== 'GET' || url.origin !== location.origin) return;
  const pagina = e.request.mode === 'navigate' || url.pathname.endsWith('config.js');
  if (pagina) {
    // Netwerk eerst, zodat een nieuwe versie meteen zichtbaar is.
    e.respondWith(fetch(e.request).then((r) => { const k = r.clone(); caches.open(CACHE).then((c) => c.put(e.request, k)); return r; })
      .catch(() => caches.match(e.request)));
  } else {
    // Bestanden met een hash in de naam veranderen nooit: cache eerst.
    e.respondWith(caches.match(e.request).then((m) => m || fetch(e.request).then((r) => {
      if (r.ok) { const k = r.clone(); caches.open(CACHE).then((c) => c.put(e.request, k)); }
      return r;
    })));
  }
});
