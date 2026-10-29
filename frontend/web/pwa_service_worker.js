/* Service worker do VMac Ponto.
 *
 * Objetivo: o app abrir e funcionar sem internet depois de UMA abertura
 * online. O Flutter 3.35+ nao gera mais o flutter_service_worker.js, entao
 * sem este arquivo o navegador nao tem nada guardado e a tela fica em
 * branco quando o sinal cai.
 *
 * Estrategia (sem passo de build, sem lista de versao):
 *
 *  - Arquivos do proprio site (index.html, main.dart.js, canvaskit, assets):
 *    REDE PRIMEIRO, cache como reserva. Online o usuario sempre recebe a
 *    versao publicada (o nginx manda Cache-Control: no-cache, entao a
 *    revalidacao custa um 304). Offline, ou se a rede travar, vem do cache.
 *    Toda resposta boa da rede atualiza o cache.
 *
 *  - SDK JS do Firebase (www.gstatic.com/firebasejs/<versao>/...) e fontes
 *    do Google (fonts.gstatic.com, usadas pelo Flutter para simbolos e
 *    caracteres que a Roboto embutida nao tem):
 *    CACHE PRIMEIRO. A URL carrega a versao, entao o conteudo nunca muda.
 *    Sem isso o Firebase.initializeApp falha offline e o app mostra
 *    "Nao foi possivel iniciar o aplicativo".
 *
 *  - /api/, /access/, qualquer POST e os outros dominios (Firestore, Auth,
 *    Storage): nao sao tocados. O Firestore tem a propria persistencia
 *    (ligada em main.dart) e a fila de pontos offline e do app.
 */

const CACHE_VERSION = 'v1';
const SHELL_CACHE = `vmac-ponto-shell-${CACHE_VERSION}`;
const VENDOR_CACHE = `vmac-ponto-vendor-${CACHE_VERSION}`;

// Quanto esperar a rede antes de servir o cache. Arquivos grandes (main.dart.js,
// canvaskit.wasm) continuam baixando em segundo plano e atualizam o cache
// quando terminam. Com 8 s, no sinal fraco da obra cada arquivo que ja estava
// guardado esperava ate 8 s antes de abrir. Sem copia guardada (primeira
// visita) a espera pela rede continua sem limite, como antes.
const NETWORK_TIMEOUT_MS = 3000;

// Arquivos minimos para o app abrir. Sao buscados na instalacao para o
// offline funcionar mesmo que a primeira visita tenha sido interrompida.
// O canvaskit (varia por navegador), as fontes, imagens e o SDK do Firebase
// entram pelo "aquecimento": o index.html manda para ca a lista do que a
// pagina realmente carregou (mensagem CACHE_URLS) e tudo e guardado.
const SHELL_URLS = [
  '/index.html',
  '/flutter_bootstrap.js',
  '/main.dart.js',
  '/manifest.json',
  '/favicon.png',
  '/icons/Icon-192.png',
  '/icons/Icon-512.png',
  '/assets/AssetManifest.bin.json',
  '/assets/AssetManifest.bin',
  '/assets/FontManifest.json',
  '/assets/fonts/MaterialIcons-Regular.otf',
  '/assets/assets/fonts/Roboto-Regular.ttf',
  '/assets/assets/fonts/Roboto-Medium.ttf',
  '/assets/assets/fonts/Roboto-Bold.ttf',
];

// URLs versionadas (o conteudo de um endereco nunca muda): cache primeiro.
const VENDOR_PREFIXES = [
  'https://www.gstatic.com/firebasejs/',
  'https://fonts.gstatic.com/',
];

function isVendorUrl(href) {
  return VENDOR_PREFIXES.some((prefix) => href.startsWith(prefix));
}

// Caminhos do proprio dominio que nunca passam pelo cache.
const BYPASS_PREFIXES = ['/api/', '/access/', '/access-check', '/openapi.json'];

// Sem estes tres o app nao abre. Numa atualizacao, se algum nao vier, a
// instalacao falha e o navegador tenta de novo na proxima checagem; a
// versao atual segue funcionando ate la.
const CRITICAL_URLS = ['/index.html', '/flutter_bootstrap.js', '/main.dart.js'];

// ATUALIZACAO AUTOMATICA. O deploy (deploy/atualizar.sh) carimba a ultima
// linha deste arquivo com a versao do build. Arquivo diferente = service
// worker novo: o navegador o instala em segundo plano (index.html chama
// registration.update() ao voltar para o app e a cada 10 min). A instalacao
// baixa a versao nova inteira para o cache; ao ativar, ele assume a pagina
// aberta (clients.claim), a pagina recebe 'controllerchange' e marca
// window.vmacUpdateReady. O app (lib/services/update_service.dart) recarrega
// no primeiro momento em que ninguem estiver usando a tela.
self.addEventListener('install', (event) => {
  // Ja existe um service worker ativo: e uma atualizacao.
  const isUpdate = !!self.registration.active;
  event.waitUntil(refreshShell(isUpdate).then(() => self.skipWaiting()));
});

// Baixa de novo os arquivos do app: os essenciais (SHELL_URLS) e tudo que ja
// estava guardado (canvaskit, fontes, imagens). So grava depois de baixar
// tudo, para a copia guardada nunca misturar a versao velha com a nova (um
// main.dart.js novo com um canvaskit velho nao abre).
// [strict]: numa atualizacao, falha se um essencial nao vier. Na primeira
// visita tolera: um arquivo que nao veio entra na proxima visita.
async function refreshShell(strict) {
  const cache = await caches.open(SHELL_CACHE);
  const cached = (await cache.keys()).map((request) => new URL(request.url).pathname);
  const urls = Array.from(new Set([...SHELL_URLS, ...cached]));
  const results = await Promise.all(
    urls.map(async (url) => {
      try {
        const response = await fetch(
          new Request(url, { cache: 'no-cache', credentials: 'same-origin' }),
        );
        return isCacheableSameOrigin(response) ? { url, response } : { url };
      } catch (_) {
        return { url };
      }
    }),
  );
  const missing = results.filter((item) => !item.response).map((item) => item.url);
  if (strict && missing.some((url) => CRITICAL_URLS.includes(url))) {
    throw new Error(`Versao nova incompleta: ${missing.join(', ')}`);
  }
  await Promise.all(
    results
      .filter((item) => item.response)
      .map((item) => cache.put(item.url, item.response)),
  );
}

self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches
      .keys()
      .then((keys) =>
        Promise.all(
          keys
            .filter((key) => key !== SHELL_CACHE && key !== VENDOR_CACHE)
            .map((key) => caches.delete(key)),
        ),
      )
      .then(() => self.clients.claim())
      .then(() => reloadOutdatedPages()),
  );
});

// Paginas abertas com o app de antes da atualizacao automatica nao sabem se
// recarregar sozinhas (e no celular o app instalado fica dias aberto). Ao
// ativar, perguntamos a cada pagina; a que responde (index.html desta
// versao em diante) cuida da propria recarga no momento seguro. A que nao
// responde em 2 s e recarregada aqui, uma unica vez, ja com a versao nova
// guardada no cache.
async function reloadOutdatedPages() {
  const pages = await self.clients.matchAll({ type: 'window' });
  await Promise.all(pages.map(async (page) => {
    if (await answersPing(page)) return;
    if (!('navigate' in page)) return;
    // Sem await: a recarga passa por este service worker, que so atende
    // depois de terminar de ativar. Esperar a recarga aqui dentro travava
    // as duas coisas (uma esperando a outra).
    page.navigate(page.url).catch(() => {
      // Navegador sem suporte: a pagina pega a versao nova ao recarregar.
    });
  }));
}

function answersPing(page) {
  return new Promise((resolve) => {
    const channel = new MessageChannel();
    const timer = setTimeout(() => resolve(false), 2000);
    channel.port1.onmessage = (event) => {
      clearTimeout(timer);
      resolve(!!(event.data && event.data.type === 'VMAC_PONG'));
    };
    try {
      page.postMessage({ type: 'VMAC_PING' }, [channel.port2]);
    } catch (_) {
      clearTimeout(timer);
      resolve(false);
    }
  });
}

self.addEventListener('fetch', (event) => {
  const request = event.request;
  if (request.method !== 'GET') return;

  const url = new URL(request.url);

  if (isVendorUrl(url.href)) {
    event.respondWith(cacheFirst(request, VENDOR_CACHE));
    return;
  }

  if (url.origin !== self.location.origin) return;
  if (isBypassed(url.pathname)) return;

  if (request.mode === 'navigate') {
    event.respondWith(networkFirst(request, SHELL_CACHE, '/index.html'));
    return;
  }

  event.respondWith(networkFirst(request, SHELL_CACHE));
});

self.addEventListener('message', (event) => {
  const data = event.data || {};
  if (data.type === 'SKIP_WAITING') self.skipWaiting();
  if (data.type === 'CACHE_URLS' && Array.isArray(data.urls)) {
    const done = warmCache(data.urls);
    if (event.waitUntil) event.waitUntil(done);
  }
});

function isBypassed(pathname) {
  return BYPASS_PREFIXES.some((prefix) => pathname.startsWith(prefix));
}

// Aquecimento: guarda o que a pagina ja carregou e ainda nao esta no cache.
// Na primeira visita o service worker ainda nao controla a pagina, entao o
// canvaskit, as fontes e o SDK do Firebase passam direto por ele; sem isto
// a proxima abertura offline falharia justamente nesses arquivos.
async function warmCache(urls) {
  const shell = await caches.open(SHELL_CACHE);
  const vendor = await caches.open(VENDOR_CACHE);
  for (const raw of urls) {
    try {
      const url = new URL(String(raw), self.location.origin);
      if (isVendorUrl(url.href)) {
        if (await vendor.match(url.href, { ignoreVary: true })) continue;
        const response = await fetch(url.href, { mode: 'cors' });
        if (isCacheableVendor(response)) await vendor.put(url.href, response);
        continue;
      }
      if (url.origin !== self.location.origin) continue;
      if (isBypassed(url.pathname)) continue;
      if (url.pathname === '/pwa_service_worker.js') continue;
      const key = url.pathname;
      if (await shell.match(key, { ignoreVary: true })) continue;
      const response = await fetch(
        new Request(url.href, { cache: 'no-cache', credentials: 'same-origin' }),
      );
      if (isCacheableSameOrigin(response)) await shell.put(key, response);
    } catch (_) {
      // Arquivo que nao veio agora entra numa proxima visita.
    }
  }
}

function isCacheableSameOrigin(response) {
  // "redirected" cobre o gate de acesso: sem o cookie, o nginx responde um
  // 302 para /access/unlock e o fetch segue o redirect. Guardar esse HTML
  // como se fosse main.dart.js quebraria o app offline.
  return (
    response &&
    response.ok &&
    !response.redirected &&
    (response.type === 'basic' || response.type === 'default')
  );
}

function isCacheableVendor(response) {
  return response && response.ok && response.type !== 'opaque';
}

async function cacheFirst(request, cacheName) {
  const cache = await caches.open(cacheName);
  const cached = await cache.match(request, { ignoreVary: true });
  if (cached) return cached;
  const response = await fetch(request);
  if (isCacheableVendor(response)) await cache.put(request, response.clone());
  return response;
}

async function networkFirst(request, cacheName, fallbackUrl) {
  const cache = await caches.open(cacheName);
  const cacheKey = cacheKeyFor(request);

  let timer;
  const timeout = new Promise((resolve) => {
    timer = setTimeout(() => resolve(undefined), NETWORK_TIMEOUT_MS);
  });

  const network = fetch(request)
    .then((response) => {
      if (isCacheableSameOrigin(response)) {
        // Nao aguardamos o put: a resposta vai para a tela ja.
        cache.put(cacheKey, response.clone()).catch(() => undefined);
      }
      return response;
    })
    .catch(() => undefined)
    .finally(() => clearTimeout(timer));

  const fromNetwork = await Promise.race([network, timeout]);
  if (fromNetwork) return fromNetwork;

  const cached =
    (await cache.match(cacheKey, { ignoreVary: true })) ||
    (fallbackUrl ? await cache.match(fallbackUrl, { ignoreVary: true }) : undefined);
  if (cached) return cached;

  // Nada no cache: devolve o que a rede der (erro, provavelmente), para o
  // navegador mostrar a falha normal em vez de uma pagina vazia.
  const late = await network;
  if (late) return late;
  return new Response('Sem conexao e sem copia local do app.', {
    status: 503,
    headers: { 'Content-Type': 'text/plain; charset=utf-8' },
  });
}

function cacheKeyFor(request) {
  // Navegacoes para qualquer rota do app (ex.: /?utm=...) sao sempre o
  // index.html: o Flutter roteia no cliente.
  if (request.mode === 'navigate') return '/index.html';
  const url = new URL(request.url);
  return url.pathname;
}
