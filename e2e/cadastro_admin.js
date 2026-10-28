// Admin cadastra uma pessoa pelo app web real e recebe a senha do primeiro acesso (123456, norma da empresa).
const { chromium } = require('playwright');
const path = require('path');

const APP = process.env.APP_URL || 'http://127.0.0.1:5005/';
const API = process.env.API_URL || 'http://127.0.0.1:8766';
const AUTH = 'http://127.0.0.1:9099/identitytoolkit.googleapis.com/v1';
const FS = 'http://127.0.0.1:8085/v1/projects/demo-ponto/databases/(default)/documents';
const SHOTS = path.join(__dirname, 'resultados');
require('fs').mkdirSync(SHOTS, { recursive: true });
const results = [];
const check = (name, ok, extra = '') => { results.push(!!ok); console.log(`[${ok ? 'OK ' : 'FALHOU'}] ${name} ${extra}`); };

async function j(method, url, body, headers = {}) {
  const r = await fetch(url, { method, headers: { 'Content-Type': 'application/json', ...headers }, body: body ? JSON.stringify(body) : undefined });
  let data = null; try { data = await r.json(); } catch (_) {}
  return { status: r.status, data };
}

(async () => {
  await fetch('http://127.0.0.1:8085/emulator/v1/projects/demo-ponto/databases/(default)/documents', { method: 'DELETE' });
  await fetch('http://127.0.0.1:9099/emulator/v1/projects/demo-ponto/accounts', { method: 'DELETE' });
  const up = await j('POST', `${AUTH}/accounts:signUp?key=k`, { email: 'admin@vmac.test', password: 'admin-forte-1', returnSecureToken: true });
  await j('PATCH', `${FS}/users/${up.data.localId}`, { fields: { name: { stringValue: 'Admin Teste' }, role: { stringValue: 'admin' },
    email: { stringValue: 'admin@vmac.test' }, cpf: { stringValue: '' } } }, { Authorization: 'Bearer owner' });

  const browser = await chromium.launch({ channel: 'chrome', headless: true });
  const context = await browser.newContext({ viewport: { width: 420, height: 900 }, permissions: ['clipboard-read', 'clipboard-write'] });
  // Auth do Google desviado para o emulador: nenhuma chamada sai para o Google.
  await context.route(/^https:\/\/(identitytoolkit|securetoken)\.googleapis\.com\//, async (route) => {
    const u = new URL(route.request().url());
    await route.fulfill({ response: await route.fetch({ url: `http://127.0.0.1:9099/${u.host}${u.pathname}${u.search}` }) });
  });
  const page = await context.newPage();
  globalThis.page = page;
  await page.goto(APP);
  await page.addStyleTag({ content: '.firebase-emulator-warning, #vmac-install { display: none !important; }' });
  await page.locator('flt-semantics-placeholder').waitFor({ state: 'attached', timeout: 60000 });
  await page.evaluate(() => document.querySelector('flt-semantics-placeholder').click());

  await page.getByRole('button', { name: 'Entrar com e-mail' }).click();
  const type = async (name, value) => { const f = page.getByRole('textbox', { name }); await f.click(); await f.fill(value); };
  await type('E-mail', 'admin@vmac.test');
  await type('Senha', 'admin-forte-1');
  await page.getByRole('button', { name: 'Entrar', exact: true }).click();

  await page.getByRole('button', { name: /^Gestão/ }).or(page.getByRole('tab', { name: /Gestão/ })).first().click({ timeout: 30000 });
  await page.getByRole('tab', { name: /Usuários/ }).click({ timeout: 30000 });
  await page.getByRole('button', { name: /Novo usuário/ }).click({ timeout: 30000 });
  await type('Nome completo', 'Maria Obra');
  await type(/CPF/, '11144477735');
  await page.screenshot({ path: path.join(SHOTS, 'admin-01-cadastro.png') });
  await page.getByRole('button', { name: 'Cadastrar' }).click();

  await page.getByRole('button', { name: 'Copiar' }).click({ timeout: 30000 });
  await page.waitForTimeout(500);
  const message = await page.evaluate(() => navigator.clipboard.readText());
  const password = message.match(/Senha do primeiro acesso: (\d+)/)[1];
  await page.screenshot({ path: path.join(SHOTS, 'admin-02-senha.png') });
  check('admin cadastra e a mensagem traz a senha do primeiro acesso', password === '123456', `(${password})`);

  const ok = await j('POST', `${API}/auth/cpf-login`, { cpf: '11144477735', password }, { 'X-Real-IP': '10.9.9.9' });
  check('a pessoa entra com a 123456 no primeiro acesso', ok.status === 200, `HTTP ${ok.status}`);
  const wrong = await j('POST', `${API}/auth/cpf-login`, { cpf: '11144477735', password: '654321' }, { 'X-Real-IP': '10.9.9.8' });
  check('senha errada nao entra', wrong.status === 401, `HTTP ${wrong.status}`);

  await browser.close();
  console.log(`\nRESULTADO: ${results.filter(Boolean).length}/${results.length}`);
})().catch(async (e) => {
  console.error('ERRO:', e.message.split('\n').slice(0, 3).join(' / '));
  try {
    await globalThis.page.screenshot({ path: path.join(SHOTS, 'admin-erro.png') });
    console.log(await globalThis.page.evaluate(() => [...document.querySelectorAll('[role=button],[role=tab],input')]
      .map((el) => `${el.getAttribute('role') || el.tagName}:${(el.getAttribute('aria-label') || el.textContent || '').trim().slice(0, 30)}`).join(' | ')));
  } catch (_) {}
  process.exit(2);
});
