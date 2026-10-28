// Bateria ampla do app web real (build USE_FIREBASE_EMULATOR) no Chrome.
// Cada cenario roda num navegador limpo; falha tira foto e segue para o proximo.
const { chromium } = require('playwright');
const path = require('path');
const fs = require('fs');

const APP = process.env.APP_URL || 'http://127.0.0.1:5005/';
const API = process.env.API_URL || 'http://127.0.0.1:8766';
const AUTH = 'http://127.0.0.1:9099/identitytoolkit.googleapis.com/v1';
const FS = 'http://127.0.0.1:8085/v1/projects/demo-ponto/databases/(default)/documents';
const SHOTS = path.join(__dirname, 'resultados');
require('fs').mkdirSync(SHOTS, { recursive: true });
const results = [];
const only = process.argv[2];

const check = (name, ok, extra = '') => {
  results.push([name, !!ok]);
  console.log(`  [${ok ? 'OK ' : 'FALHOU'}] ${name} ${extra}`);
};

async function j(method, url, body, headers = {}) {
  const r = await fetch(url, { method, headers: { 'Content-Type': 'application/json', ...headers }, body: body ? JSON.stringify(body) : undefined });
  let data = null; try { data = await r.json(); } catch (_) {}
  return { status: r.status, data };
}

// ---------- dados ----------
let adminToken;
const OWNER = { Authorization: 'Bearer owner' };
async function reset() {
  await fetch('http://127.0.0.1:8085/emulator/v1/projects/demo-ponto/databases/(default)/documents', { method: 'DELETE' });
  await fetch('http://127.0.0.1:9099/emulator/v1/projects/demo-ponto/accounts', { method: 'DELETE' });
  const up = await j('POST', `${AUTH}/accounts:signUp?key=k`, { email: 'admin@vmac.test', password: 'admin-forte-1', returnSecureToken: true });
  await j('PATCH', `${FS}/users/${up.data.localId}`, { fields: { name: { stringValue: 'Admin Teste' }, role: { stringValue: 'admin' },
    email: { stringValue: 'admin@vmac.test' }, cpf: { stringValue: '' } } }, OWNER);
  adminToken = (await j('POST', `${AUTH}/accounts:signInWithPassword?key=k`, { email: 'admin@vmac.test', password: 'admin-forte-1', returnSecureToken: true })).data.idToken;
}
// CPF valido: os dois digitos verificadores calculados.
function makeCpf(n) {
  const base = String(100000000 + n * 7919).slice(-9).split('').map(Number);
  for (const size of [9, 10]) {
    const total = base.slice(0, size).reduce((acc, d, i) => acc + d * (size + 1 - i), 0);
    base.push((total * 10) % 11 % 10);
  }
  return base.join('');
}
const CPFS = Array.from({ length: 40 }, (_, i) => makeCpf(i + 1));
let cpfIndex = 0;
async function newUser(extra = {}) {
  const cpf = CPFS[cpfIndex++];
  const r = await j('POST', `${API}/admin/users`, { name: extra.name || `Pessoa ${cpfIndex}`, cpf, role: 'employee', ...extra }, { Authorization: `Bearer ${adminToken}` });
  if (r.status !== 200) throw new Error(`cadastro falhou: ${JSON.stringify(r.data)}`);
  return { id: r.data.id, cpf, password: r.data.temporary_password };
}
async function docs(collection) {
  const r = await j('GET', `${FS}/${collection}?pageSize=300`, null, OWNER);
  return (r.data.documents || []).map((d) => ({ id: d.name.split('/').pop(), f: d.fields }));
}
const recordsOf = async (uid) => (await docs('time_records')).filter((d) => d.f.user_id?.stringValue === uid).map((d) => d.f.record_type.stringValue);

// ---------- navegador ----------
let browser;
async function openApp(opts = {}) {
  const context = await browser.newContext({
    viewport: opts.viewport || { width: 400, height: 860 },
    permissions: ['geolocation', 'notifications', 'clipboard-read', 'clipboard-write'],
    geolocation: { latitude: -15.79, longitude: -47.88 },
    acceptDownloads: true,
  });
  // O SDK valida a sessao guardada no Google ANTES de o app ligar o emulador
  // (useAuthEmulator vem depois): desvia o Auth do Google para o emulador.
  // Nenhuma chamada sai para o Google de verdade nos testes.
  await context.route(/^https:\/\/(identitytoolkit|securetoken)\.googleapis\.com\//, async (route) => {
    const u = new URL(route.request().url());
    const response = await route.fetch({ url: `http://127.0.0.1:9099/${u.host}${u.pathname}${u.search}` });
    await route.fulfill({ response });
  });
  const page = await context.newPage();
  page.errors = [];
  page.on('pageerror', (e) => page.errors.push(String(e)));
  await page.goto(APP);
  await prepare(page);
  return { context, page };
}
async function prepare(page) {
  await page.addStyleTag({ content: '.firebase-emulator-warning, #vmac-install { display: none !important; }' });
  await page.locator('flt-semantics-placeholder').waitFor({ state: 'attached', timeout: 60000 });
  await page.evaluate(() => document.querySelector('flt-semantics-placeholder')?.click());
}
async function type(page, name, value) {
  const f = page.getByRole('textbox', { name }).first();
  await f.click(); await f.fill(value);
}
const button = (page, name) => page.getByRole('button', { name }).first();
async function loginCpf(page, cpf, password) {
  await button(page, 'Entrar').waitFor({ timeout: 60000 });
  await type(page, 'CPF', cpf);
  await type(page, 'Senha', password);
  await button(page, 'Entrar').click();
}
async function firstAccess(page, newPassword = 'nova-senha-9') {
  await button(page, /Salvar senha/).waitFor({ timeout: 30000 });
  const boxes = page.getByRole('textbox');
  for (let i = 0; i < await boxes.count(); i++) { await boxes.nth(i).click(); await boxes.nth(i).fill(newPassword); }
  await button(page, /Salvar senha/).click();
}
async function loginNew(page, user) {
  await loginCpf(page, user.cpf, user.password);
  await firstAccess(page);
  user.password = 'nova-senha-9';
}
async function tab(page, name) {
  await page.getByRole('tab', { name: new RegExp(name) }).or(page.getByRole('button', { name: new RegExp(`^${name}`) })).first().click();
}

async function scenario(name, fn) {
  if (only && !name.toLowerCase().includes(only.toLowerCase())) return;
  console.log(`\n== ${name}`);
  const opened = [];
  try {
    await fn(opened);
  } catch (e) {
    check(`${name}: terminou sem erro`, false, e.message.split('\n')[0]);
    for (const [i, p] of opened.entries()) {
      try { await p.screenshot({ path: path.join(SHOTS, `erro-${name.replace(/\W+/g, '_')}-${i}.png`) }); } catch (_) {}
    }
  } finally {
    for (const p of opened) { try { await p.context().close(); } catch (_) {} }
  }
}

(async () => {
  browser = await chromium.launch({ channel: 'chrome', headless: true });
  await reset();

  await scenario('1 Telas de celular e computador', async (opened) => {
    for (const [nome, viewport] of [['celular pequeno', { width: 360, height: 740 }], ['computador', { width: 1366, height: 768 }]]) {
      const { page } = await openApp({ viewport }); opened.push(page);
      await button(page, 'Entrar').waitFor({ timeout: 60000 });
      const overflow = await page.evaluate(() => document.documentElement.scrollWidth > window.innerWidth + 1);
      await page.screenshot({ path: path.join(SHOTS, `1-login-${nome.replace(' ', '-')}.png`) });
      check(`login cabe na tela (${nome}, ${viewport.width}px)`, !overflow);
    }
  });

  await scenario('2 Sessao continua ao recarregar', async (opened) => {
    const user = await newUser();
    const { page } = await openApp(); opened.push(page);
    await loginNew(page, user);
    await button(page, /REGISTRAR ENTRADA/).waitFor({ timeout: 30000 });
    const t = Date.now();
    await page.reload();
    await prepare(page);
    await button(page, /REGISTRAR ENTRADA/).waitFor({ timeout: 30000 });
    const loginVisivel = await button(page, 'Entrar').isVisible().catch(() => false);
    check('recarregar a pagina continua logado (sem pedir senha)', !loginVisivel, `(${Date.now() - t} ms ate a tela de ponto)`);
  });

  await scenario('3 Sair e entrar de novo', async (opened) => {
    const user = await newUser();
    const { page } = await openApp(); opened.push(page);
    await loginNew(page, user);
    await tab(page, 'Perfil');
    await button(page, /SAIR DA CONTA/).click();
    await button(page, /^Sair$/).click();
    await button(page, 'Entrar').waitFor({ timeout: 20000 });
    check('sair da conta volta para o login', true);
    // O CPF ja vem preenchido (ultimo login): basta a senha.
    await type(page, 'Senha', user.password);
    await button(page, 'Entrar').click();
    await button(page, /REGISTRAR ENTRADA/).waitFor({ timeout: 30000 });
    check('entra de novo digitando so a senha (CPF lembrado)', true);
  });

  await scenario('4 Exportar folha em Excel', async (opened) => {
    // Exportar e do gestor (o funcionario nao tem o botao).
    const user = await newUser({ name: 'Exporta Folha' });
    const { page } = await openApp({ viewport: { width: 1280, height: 900 } }); opened.push(page);
    await button(page, 'Entrar com e-mail').click();
    await type(page, 'E-mail', 'admin@vmac.test');
    await type(page, 'Senha', 'admin-forte-1');
    await button(page, 'Entrar').click();
    await tab(page, 'Perfil');
    await button(page, /Exportar Folha de Ponto/).click();
    await page.getByText('Configurar Exportação').waitFor({ timeout: 20000 });
    await page.screenshot({ path: path.join(SHOTS, '4-exportar.png') });
    const downloadPromise = page.waitForEvent('download', { timeout: 60000 });
    await button(page, /Confirmar Exportação/).click();
    // Perguntas no caminho (feriados no mes...): responde "Nao".
    let download;
    downloadPromise.then((d) => { download = d; }, () => {});
    for (let i = 0; i < 40 && !download; i++) {
      const nao = page.getByRole('button', { name: /^Não$/ });
      if (await nao.count()) { await nao.first().click(); }
      await page.waitForTimeout(500);
    }
    download = download || await downloadPromise;
    const file = path.join(SHOTS, 'folha-baixada.xlsx');
    await download.saveAs(file);
    const size = fs.statSync(file).size;
    const zipHeader = fs.readFileSync(file).subarray(0, 2).toString() === 'PK';
    check('baixa a folha .xlsx valida', download.suggestedFilename().endsWith('.xlsx') && size > 5000 && zipHeader,
      `(${download.suggestedFilename()}, ${Math.round(size / 1024)} KB)`);
  });

  await scenario('5 Estagiario fora do horario e liberacao pelo gestor', async (opened) => {
    // Janela de entrada que nunca inclui agora: toda entrada pede liberacao.
    const h = new Date().getHours();
    const start = String((h + 3) % 24).padStart(2, '0');
    const end = String((h + 3) % 24).padStart(2, '0');
    const setRes = await j('PUT', `${API}/admin/work-schedule/settings`, {
      shift_start: `${start}:00`, shift_end: `${end}:50`, start_allowed_from: `${start}:00`, start_allowed_until: `${start}:30`,
      overtime_prompt_after: `${end}:55`, timezone: 'America/Sao_Paulo' }, { Authorization: `Bearer ${adminToken}` });
    check('gestor define o horario do estagiario', setRes.status === 200, `HTTP ${setRes.status}`);
    const intern = await newUser({ name: 'Estagiaria Teste', role: 'intern' });
    const { page } = await openApp(); opened.push(page);
    await loginNew(page, intern);
    await button(page, /REGISTRAR ENTRADA/).waitFor({ timeout: 30000 });
    await button(page, /REGISTRAR ENTRADA/).click();
    // Pode haver uma confirmacao antes do pedido.
    const obs = page.getByRole('textbox', { name: /Observacao para o gestor/ });
    for (let i = 0; i < 20 && !(await obs.count()); i++) {
      const sim = page.getByRole('button', { name: /^(Sim|Continuar|Confirmar|Solicitar)/ });
      if (await sim.count()) await sim.first().click();
      await page.waitForTimeout(500);
    }
    await page.screenshot({ path: path.join(SHOTS, '5-pedido.png') });
    await obs.click(); await obs.fill('Cheguei cedo para a vistoria');
    await button(page, /SOLICITAR LIBERACAO/).click();
    let pedido;
    for (let i = 0; i < 30 && !pedido; i++) {
      await page.waitForTimeout(500);
      pedido = (await docs('work_schedule_approval_requests')).find((d) => d.f.user_id?.stringValue === intern.id);
    }
    check('pedido de liberacao chega ao banco', !!pedido, pedido ? `(status ${pedido.f.status.stringValue})` : '');

    const admin = await openApp(); opened.push(admin.page);
    await button(admin.page, 'Entrar com e-mail').click();
    await type(admin.page, 'E-mail', 'admin@vmac.test');
    await type(admin.page, 'Senha', 'admin-forte-1');
    await button(admin.page, 'Entrar').click();
    await tab(admin.page, 'Gestão');
    await admin.page.getByRole('tab', { name: /Liberações/ }).click();
    await button(admin.page, 'LIBERAR').waitFor({ timeout: 30000 });
    await admin.page.screenshot({ path: path.join(SHOTS, '5-gestor-liberacoes.png') });
    await button(admin.page, 'LIBERAR').click();
    await admin.page.getByText('Liberar horário?').waitFor({ timeout: 10000 });
    await admin.page.getByRole('button', { name: 'LIBERAR' }).last().click();
    let entrada = false;
    for (let i = 0; i < 30 && !entrada; i++) {
      await admin.page.waitForTimeout(500);
      entrada = (await recordsOf(intern.id)).includes('check_in');
    }
    check('gestor libera pela tela e a entrada da estagiaria e gravada', entrada);
    await page.reload(); await prepare(page);
    await page.getByText(/Em serviço|EM SERVIÇO|Em servico/i).first().waitFor({ timeout: 30000 }).then(
      () => check('a estagiaria ve o turno aberto', true),
      async () => { await page.screenshot({ path: path.join(SHOTS, '5-estagiaria-depois.png') }); check('a estagiaria ve o turno aberto', false); });
  });

  await scenario('6 Modo diaria', async (opened) => {
    const user = await newUser({ name: 'Diarista Teste', daily_mode: true });
    const { page } = await openApp(); opened.push(page);
    await loginNew(page, user);
    await button(page, /ADICIONAR DIÁRIA|Registrar a diária/).waitFor({ timeout: 30000 });
    await page.screenshot({ path: path.join(SHOTS, '6-diaria.png') });
    await button(page, /ADICIONAR DIÁRIA|Registrar a diária/).click();
    const confirmar = page.getByRole('button', { name: /^Registrar$/ });
    if (await confirmar.count()) await confirmar.first().click();
    let diaria = false;
    for (let i = 0; i < 30 && !diaria; i++) {
      await page.waitForTimeout(500);
      diaria = (await docs('daily_entries')).some((d) => d.f.user_id?.stringValue === user.id);
    }
    check('diaria registrada pelo app', diaria);
  });

  await scenario('7 Offline: abre sem internet, bate e sincroniza', async (opened) => {
    const user = await newUser({ name: 'Obra Sem Sinal' });
    const { context, page } = await openApp(); opened.push(page);
    await loginNew(page, user);
    await button(page, /REGISTRAR ENTRADA/).waitFor({ timeout: 30000 });
    // Da tempo ao service worker de instalar e guardar o app.
    await page.waitForFunction(() => navigator.serviceWorker && navigator.serviceWorker.controller, null, { timeout: 30000 }).catch(() => {});
    await page.reload(); await prepare(page);
    await button(page, /REGISTRAR ENTRADA/).waitFor({ timeout: 30000 });
    await page.waitForTimeout(3000);
    await context.setOffline(true);
    const t = Date.now();
    await page.reload().catch(() => {});
    await prepare(page);
    const abriu = await button(page, /REGISTRAR ENTRADA/).waitFor({ timeout: 45000 }).then(() => true, () => false);
    await page.screenshot({ path: path.join(SHOTS, '7-offline-aberto.png') });
    check('app abre sem internet (service worker)', abriu, `(${Date.now() - t} ms)`);
    if (!abriu) return;
    await button(page, /REGISTRAR ENTRADA/).click();
    await page.waitForTimeout(3000);
    await page.screenshot({ path: path.join(SHOTS, '7-offline-batida.png') });
    const pendente = await page.getByText(/aguardando internet/).count();
    check('batida sem internet fica guardada no aparelho', pendente > 0);
    await context.setOffline(false);
    let chegou = false;
    const t2 = Date.now();
    for (let i = 0; i < 90 && !chegou; i++) {
      await page.waitForTimeout(1000);
      chegou = (await recordsOf(user.id)).includes('check_in');
    }
    check('internet de volta: a batida chega sozinha', chegou, `(${Math.round((Date.now() - t2) / 1000)} s)`);
  });

  await scenario('8 Lancamento em lote do gestor', async (opened) => {
    const user = await newUser({ name: 'Equipe Lote' });
    const admin = await openApp({ viewport: { width: 1280, height: 900 } }); opened.push(admin.page);
    const page = admin.page;
    await button(page, 'Entrar com e-mail').click();
    await type(page, 'E-mail', 'admin@vmac.test');
    await type(page, 'Senha', 'admin-forte-1');
    await button(page, 'Entrar').click();
    await tab(page, 'Gestão');
    await page.getByRole('tab', { name: /Add Ponto/ }).click();
    await page.getByText(/LANÇAMENTO EM LOTE/).waitFor({ timeout: 30000 });
    await page.screenshot({ path: path.join(SHOTS, '8-lote.png') });
    check('aba de lancamento em lote abre', true);
  });

  await browser.close();
  const ok = results.filter((r) => r[1]).length;
  console.log(`\nRESULTADO: ${ok}/${results.length}`);
})().catch((e) => { console.error('ERRO GERAL:', e.message); process.exit(2); });
