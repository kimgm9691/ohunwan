// ===== 오운완 Service Worker =====
// 전략: "네트워크 우선(Network First)"
//  - 온라인이면 항상 서버에서 최신 파일을 받아옴  → 업데이트가 즉시 반영됨 (캐시 삭제 불필요)
//  - 오프라인이면 마지막으로 받았던 캐시를 보여줌 → 앱이 안 깨짐
//
// ※ 업데이트할 때 이 파일은 보통 건드릴 필요 없습니다.
//    혹시 캐시를 완전히 비우고 싶을 때만 아래 CACHE 버전(v2 → v3 ...)을 올리세요.

const CACHE = 'oun-cache-v2';

// 설치되자마자 바로 활성화 (이전 워커가 끝날 때까지 기다리지 않음)
self.addEventListener('install', (e) => {
  self.skipWaiting();
});

// 활성화 시: 옛날 캐시 전부 삭제 + 열린 탭들 즉시 제어
self.addEventListener('activate', (e) => {
  e.waitUntil((async () => {
    const keys = await caches.keys();
    await Promise.all(keys.filter(k => k !== CACHE).map(k => caches.delete(k)));
    await self.clients.claim();
  })());
});

self.addEventListener('fetch', (e) => {
  const req = e.request;

  // GET 요청만 캐싱 대상 (POST 등은 그대로 통과)
  if (req.method !== 'GET') return;

  // Supabase API / 외부 동적 요청은 캐싱하지 않고 항상 네트워크로
  const url = new URL(req.url);
  if (url.hostname.endsWith('supabase.co')) return;

  e.respondWith((async () => {
    try {
      // 1) 네트워크에서 먼저 받아오기 (최신 보장)
      const fresh = await fetch(req);
      // 받아온 건 캐시에 백업 (오프라인 대비)
      const cache = await caches.open(CACHE);
      cache.put(req, fresh.clone());
      return fresh;
    } catch (err) {
      // 2) 네트워크 실패(오프라인 등) → 캐시에서 꺼내기
      const cached = await caches.match(req);
      if (cached) return cached;
      throw err;
    }
  })());
});
