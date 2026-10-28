// Teste do app web REAL (build com USE_FIREBASE_EMULATOR) no Chrome:
// login por CPF, troca de senha no primeiro acesso, batidas e abas.
// Uso: node app_e2e.js   (emulador, backend :8766 e app :5005 no ar)
const { chromium } = require('playwright');
const path = require('path');

const APP = process.env.APP_URL || 'http://127.0.0.1:5005/';
const API = process.env.API_URL || 'http://127.0.0.1:8766';
const AUTH = 'http://127.0.0.1:9099/identitytoolkit.googleapis.com/v1';
const FS = 'http://127.0.0.1:8085/v1/projects/demo-ponto/databases/(default)/documents';
const SHOTS = path.join(__dirname, 'resultados');
require('fs').mkdirSync(SHOTS, { recursive: true });
const results = [];

function check(name, ok, extra = '') {
  globalThis.etapa = name;
  results.push([name, !!ok]);
  console.log(`[${ok ? 'OK ' : 'FALHOU'}] ${name} ${extra}`);
}

async function j(method, url, body, headers = {}) {
  const r = await fetch(url, { method, headers: { 'Content-Type': 'application/json', ...headers },
    body: body ? JSON.stringify(body) : undefined });
  let data = null;
  try { data = await r.json(); } catch (_) {}
  return { status: r.status, data };
}

async function seed() {
  await fetch('http://127.0.0.1:8085/emulator/v1/projects/demo-ponto/databases/(default)/documents', { method: 'DELETE' });
  await fetch('http://127.0.0.1:9099/emulator/v1/projects/demo-ponto/accounts', { method: 'DELETE' });
  const up = await j('POST', `${AUTH}/accounts:signUp?key=k`, { email: 'admin@vmac.test', password: 'admin-forte-1', returnSecureToken: true });
  const uid = up.data.localId;
  await j('PATCH', `${FS}/users/${uid}`, { fields: { name: { stringValue: 'Admin' }, role: { stringValue: 'admin' },
    email: { stringValue: 'admin@vmac.test' }, cpf: { stringValue: '' } } }, { Authorization: 'Bearer owner' });
  const tok = (await j('POST', `${AUTH}/accounts:signInWithPassword?key=k`, { email: 'admin@vmac.test', password: 'admin-forte-1', returnSecureToken: true })).data.idToken;
  const created = await j('POST', `${API}/admin/users`, { name: 'Joao Campo', cpf: '529.982.247-25', role: 'employee' }, { Authorization: `Bearer ${tok}` });
  return { empId: created.data.id, password: created.data.default_password };
}

async function records(uid) {
  const r = await j('GET', `${FS}/time_records`, null, { Authorization: 'Bearer owner' });
  return (r.data.documents || []).map((d) => ({
    id: d.name.split('/').pop(),
    type: d.fields.record_type?.stringValue,
    user: d.fields.user_id?.stringValue,
  })).filter((d) => d.user === uid);
}

(async () => {
  require('fs').mkdirSync(SHOTS, { recursive: true });
  const { empId, password } = await seed();
  check('cadastro do funcionario pelo admin (backend)', !!empId, `senha inicial="${password}"`);

  const browser = await chromium.launch({ channel: 'chrome', headless: true });
  const context = await browser.newContext({ viewport: { width: 400, height: 860 }, geolocation: { latitude: -15.79, longitude: -47.88 }, permissions: ['geolocation', 'notifications'] });
  // Auth do Google desviado para o emulador: nenhuma chamada sai para o Google.
  await context.route(/^https:\/\/(identitytoolkit|securetoken)\.googleapis\.com\//, async (route) => {
    const u = new URL(route.request().url());
    await route.fulfill({ response: await route.fetch({ url: `http://127.0.0.1:9099/${u.host}${u.pathname}${u.search}` }) });
  });
  const page = await context.newPage();
  globalThis.page = page;
  const errors = [];
  page.on('pageerror', (e) => errors.push(String(e)));
  page.on('console', async (m) => {
    if (process.env.VERBOSE && /login|senha/.test(globalThis.etapa||'')) console.log('   console.' + m.type() + ': ' + JSON.stringify(m.text().slice(0, 300)));
    if (m.type() !== 'error') return;
    const args = await Promise.all(m.args().map((a) => a.evaluate((v) => (v && v.stack) ? String(v) + ' ' + v.stack.slice(0, 300) : String(v)).catch(() => '?')));
    errors.push(`[etapa ${globalThis.etapa}] ` + JSON.stringify((m.text() || args.join(' ')).slice(0, 300)));
  });
  const shot = (name) => page.screenshot({ path: path.join(SHOTS, `${name}.png`) });

  const t0 = Date.now();
  await page.goto(APP);
  await page.addStyleTag({ content: '.firebase-emulator-warning, #vmac-install { display: none !important; }' });
  // Liga a arvore de acessibilidade do Flutter: botoes e campos viram elementos HTML.
  await page.locator('flt-semantics-placeholder').waitFor({ state: 'attached', timeout: 60000 });
  await page.evaluate(() => document.querySelector('flt-semantics-placeholder').click());
  // Aviso "Instale o app" do index.html: fora do escopo do teste.
  await page.evaluate(() => document.getElementById('vmac-install')?.remove());
  const loginButton = page.getByRole('button', { name: 'Entrar', exact: true });
  await loginButton.waitFor({ timeout: 60000 });
  const openMs = Date.now() - t0;
  check('tela de login aparece', true, `(${openMs} ms desde o carregamento, sem sessao)`);
  await shot('01-login');

  const fill = async (label, value) => {
    const input = page.getByRole('textbox', { name: label });
    await input.click();
    await input.fill(value);
  };
  await fill('CPF', '52998224725');
  await fill('Senha', password);
  await loginButton.click();

  const save = page.getByRole('button', { name: /Salvar senha/ });
  await save.waitFor({ timeout: 30000 });
  check('primeiro acesso pede senha nova', true);
  await shot('02-troca-senha');
  const boxes = page.getByRole('textbox');
  const n = await boxes.count();
  for (let i = 0; i < n; i++) { await boxes.nth(i).click(); await boxes.nth(i).fill('nova-senha-9'); }
  await save.click();

  const entrada = page.getByRole('button', { name: /REGISTRAR ENTRADA/ });
  await entrada.waitFor({ timeout: 30000 });
  check('troca de senha leva a tela de ponto', true);
  await shot('03-ponto');

  async function bater(botao, tipo) {
    const t = Date.now();
    await page.getByRole('button', { name: botao }).click();
    let found = false;
    for (let i = 0; i < 60 && !found; i++) {
      await page.waitForTimeout(250);
      found = (await records(empId)).some((r) => r.type === tipo);
    }
    check(`bateu ${tipo} pelo app (gravado no banco)`, found, `(${Date.now() - t} ms do toque ate o banco)`);
  }
  await bater(/REGISTRAR ENTRADA/, 'check_in');
  await page.getByRole('button', { name: /INICIAR PAUSA 1/ }).waitFor({ timeout: 20000 });
  await shot('04-em-servico');
  await bater(/INICIAR PAUSA 1/, 'break_start');
  await page.getByRole('button', { name: /RETORNAR DA PAUSA/ }).waitFor({ timeout: 20000 });
  await bater(/RETORNAR DA PAUSA/, 'break_end');
  await shot('05-depois-pausa');

  // Servidor fora do ar na hora da saida: a batida vai para a fila do
  // aparelho e chega ao banco sozinha quando o servidor volta.
  await page.route('**/time-records/punch', (route) => route.fulfill({ status: 503, body: '{"detail":"fora"}' }));
  await page.getByRole('button', { name: /INICIAR PAUSA 2|FINALIZAR|REGISTRAR SA/ }).first().waitFor({ timeout: 20000 });
  const sair = page.getByRole('button', { name: /FINALIZAR|REGISTRAR SA/ }).first();
  const temSair = await sair.count();
  if (temSair) {
    await sair.click();
    const confirmar = page.getByRole('button', { name: /^(Sim|Confirmar|Finalizar)/ });
    if (await confirmar.count()) await confirmar.first().click();
  }
  await page.waitForTimeout(3000);
  await shot('05b-servidor-fora');
  const naFila = !(await records(empId)).some((r) => r.type === 'check_out');
  check('servidor fora: saida fica na fila, nao some', temSair && naFila);
  await page.unroute('**/time-records/punch');
  let sincronizou = false;
  const t1 = Date.now();
  for (let i = 0; i < 90 && !sincronizou; i++) {
    await page.waitForTimeout(1000);
    sincronizou = (await records(empId)).some((r) => r.type === 'check_out');
  }
  check('servidor de volta: fila envia a saida sozinha', sincronizou, `(${Math.round((Date.now() - t1) / 1000)} s)`);

  const recs = await records(empId);
  check('pontos gravados pelo backend com id do aparelho', recs.length === 4, JSON.stringify(recs.map((r) => r.type)));

  for (const aba of ['Dash', 'Histórico', 'Perfil', 'Ponto']) {
    const tab = page.getByRole('tab', { name: new RegExp(aba) }).or(page.getByRole('button', { name: new RegExp(`^${aba}`) }));
    globalThis.etapa = 'aba ' + aba;
    await tab.first().click();
    await page.waitForTimeout(1500);
    await shot(`06-aba-${aba}`);
  }
  check('abas abrem sem erro', errors.filter((e) => !/favicon|manifest|status of 503/.test(e)).length === 0, errors.slice(0, 3).join(' || '));

  await browser.close();
  const ok = results.filter((r) => r[1]).length;
  console.log(`\nRESULTADO: ${ok}/${results.length} verificacoes passaram`);
  process.exit(ok === results.length ? 0 : 1);
})().catch(async (e) => {
  console.error('ERRO:', e.message.split(String.fromCharCode(10))[0]);
  try {
    await globalThis.page.screenshot({ path: path.join(SHOTS, 'batidas-erro.png') });
    console.log(await globalThis.page.evaluate(() => [...document.querySelectorAll('[role=button],input,flt-semantics')].map((el) => (el.getAttribute('aria-label') || el.textContent || '').trim().slice(0, 40)).filter(Boolean).slice(0, 25).join(' | ')));
  } catch (_) {}
  process.exit(2);
});
