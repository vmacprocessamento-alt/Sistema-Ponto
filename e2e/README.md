# Testes de ponta a ponta (app web)

Rodam o **app web de verdade** no Chrome e o **backend de verdade**, contra o
**emulador do Firebase** (projeto `demo-ponto`): nada toca o Firebase real nem
o Google (os scripts desviam o Auth do Google para o emulador).

## O que cobrem
| Script | Cenários |
|---|---|
| `api_e2e.py` | API e regras do Firestore: cadastro, login por CPF, senha temporária, troca no primeiro acesso, conta desativada, estagiário, batidas, ponto retroativo bloqueado, limite de tentativas, tempos de resposta |
| `batidas.js` | Funcionário no navegador: login, troca de senha, entrada/pausa/retorno, **servidor fora do ar** → fila → envio sozinho, abas |
| `cadastro_admin.js` | Admin cadastra pela tela e recebe a senha temporária; ela entra, a 123456 não |
| `web_suite.js` | Celular pequeno e computador, sessão ao recarregar, sair e entrar, exportar Excel, estagiário fora do horário → **gestor libera pela tela**, modo diária, **offline** (abre sem internet, bate e sincroniza), lançamento em lote |

## Como rodar
Precisa de Node, Python 3.12, Flutter, Java (para o emulador), Chrome e
`npm i -g firebase-tools`.

```bash
# 1. emulador, na raiz do repositório (usa o firebase.json e as regras de lá)
firebase emulators:start --only auth,firestore --project demo-ponto

# 2. backend falando com o emulador (outro terminal)
cd backend
FIRESTORE_EMULATOR_HOST=127.0.0.1:8085 FIREBASE_AUTH_EMULATOR_HOST=127.0.0.1:9099 \
FIREBASE_PROJECT_ID=demo-ponto GOOGLE_CLOUD_PROJECT=demo-ponto FIREBASE_WEB_API_KEY=demo-key \
DATABASE_PATH=./data/ponto-emu.db SECRET_KEY=teste-local ALLOWED_ORIGINS=http://127.0.0.1:5005 \
python -m uvicorn main:app --port 8766

# 3. app web no modo emulador, servido na 5005 (outro terminal)
cd frontend
flutter build web --release --dart-define=USE_FIREBASE_EMULATOR=true \
  --dart-define=API_BASE_URL=http://127.0.0.1:8766 -o ../e2e/app
cd ../e2e/app && python -m http.server 5005 --bind 127.0.0.1

# 4. testes
cd e2e && npm install
python api_e2e.py
npm run batidas && npm run cadastro && npm run suite
```

Um cenário da suíte sozinho: `node web_suite.js offline`. Fotos de cada etapa
(e de qualquer falha) ficam em `e2e/resultados/`.

O limite de tentativas de login é por CPF e fica 15 min na memória do
backend: depois do `api_e2e.py` (que erra senhas de propósito), reinicie o
backend antes do `cadastro_admin.js`, que usa o mesmo CPF.
