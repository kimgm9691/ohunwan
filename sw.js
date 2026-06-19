/* 오운완 서비스워커
   - 앱 셸(HTML/아이콘/매니페스트)을 캐싱해 오프라인에서도 열리게 함
   - Supabase API·이미지 요청은 캐싱하지 않고 항상 네트워크로 (실시간 데이터 보장)
   - 배포 후 파일을 수정하면 CACHE 버전 숫자를 올려주세요 (v1 → v2 …) */
const CACHE = 'owanwan-v5';
const APP_SHELL = [
  './',
  './index.html',
  './manifest.json',
  './icon-192.png',
  './icon-512.png',
  './icon-512-maskable.png'
];

self.addEventListener('install', e => {
  e.waitUntil(caches.open(CACHE).then(c => c.addAll(APP_SHELL)).then(() => self.skipWaiting()));
});

self.addEventListener('activate', e => {
  e.waitUntil(
    caches.keys().then(keys =>
      Promise.all(keys.filter(k => k !== CACHE).map(k => caches.delete(k)))
    ).then(() => self.clients.claim())
  );
});

self.addEventListener('fetch', e => {
  const req = e.request;
  if (req.method !== 'GET') return;
  const url = new URL(req.url);

  // 같은 출처(앱 셸)만 캐시 우선. 외부(API/이미지/CDN)는 그대로 네트워크.
  if (url.origin !== self.location.origin) return;

  e.respondWith(
    caches.match(req).then(cached =>
      cached || fetch(req).then(res => {
        const copy = res.clone();
        caches.open(CACHE).then(c => c.put(req, copy));
        return res;
      }).catch(() => cached)
    )
  );
});
