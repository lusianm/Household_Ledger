const scope = new URL(self.registration.scope);
const prefix = `chagok:${scope.pathname}:`;
const cacheName = `${prefix}__VERSION__`;
const files = __FILES__;
const urls = new Set(files.map(file => new URL(file, scope).href));
self.addEventListener('install', event => event.waitUntil((async () => {
  const cache = await caches.open(cacheName);
  // A failed install never replaces the previous working cache/worker.
  for (const file of files) await cache.add(new Request(new URL(file, scope), {cache: 'reload'}));
})()));
self.addEventListener('activate', event => event.waitUntil((async () => {
  for (const key of await caches.keys()) if (key.startsWith(prefix) && key !== cacheName) await caches.delete(key);
  await self.clients.claim();
})()));
self.addEventListener('message', event => { if (event.data === 'activate') self.skipWaiting(); });
self.addEventListener('fetch', event => {
  if (event.request.method !== 'GET') return;
  const url = new URL(event.request.url);
  if (url.origin !== scope.origin || !url.pathname.startsWith(scope.pathname)) return;
  const navigation = event.request.mode === 'navigate';
  if (!navigation && !urls.has(url.href)) return;
  event.respondWith((async () => {
    const cache = await caches.open(cacheName);
    const cached = await cache.match(navigation ? new URL('index.html', scope).href : event.request);
    return cached ?? fetch(event.request);
  })());
});
