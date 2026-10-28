# Sistema de Ponto VMac

Controle de ponto eletrônico da VMac Engenharia: app Flutter (Android e
navegador/PWA), Firebase (Auth, Firestore, push) e backend FastAPI.

## 📋 Funcionalidades

- **Acesso:** login por CPF e senha; o admin cadastra a pessoa e o sistema gera
  uma senha temporária, trocada no primeiro acesso. Palavra-chave da empresa
  no site.
- **Ponto:** entrada, até duas pausas e saída, com localização. Online vale a
  hora do servidor; sem internet a batida fica no aparelho e é enviada quando
  a rede volta (até 7 dias). Turno que vira o dia, "esqueci a saída" e pausa
  esquecida fechada sozinha depois de 3 h.
- **Estagiário:** horário controlado (janela de entrada e limite de saída) e
  pedido de liberação ao gestor, com notificação.
- **Modo diária:** para quem recebe por dia, um toque marca a diária.
- **Dash, Histórico e Meu Mês:** horas do dia, da semana e do período da folha.
- **Gestão:** cadastro de usuários, lançamento em lote, edição de ponto com
  auditoria, liberações de horário, diárias.
- **Exportação:** folha de ponto em Excel (modelos administrativo e campo),
  lote em ZIP e relatório HTML.
- **Notificações push** no Android e no navegador; chat de ajustes com o RH.
- **Backup:** completo semanal e incremental diário, com cópia por e-mail
  cifrada.

## 📚 Documentação

| Documento | Conteúdo |
|---|---|
| [ARCHITECTURE.md](docs/ARCHITECTURE.md) | Como as peças se encaixam, quem grava o quê, fluxos e coleções |
| [VPS.md](docs/VPS.md) | Produção: VPS, túnel da Cloudflare, atualizar, diagnóstico |
| [FEATURES.md](docs/FEATURES.md) | Funcionalidades detalhadas |
| [OFFLINE.md](docs/OFFLINE.md) | Modo offline do app web (PWA) |
| [OPERATIONAL_CONFIG.md](docs/OPERATIONAL_CONFIG.md) | Configuração operacional |
| [RECOVERY.md](docs/RECOVERY.md) | Recuperação automática após queda de energia |
| [DEPLOY.md](docs/DEPLOY.md) | Guia geral de publicação (produção atual: VPS.md) |

## 🏗️ Estrutura

```
Sistema-Ponto/
├── backend/                  # FastAPI (Python 3.12)
│   ├── main.py               # rotas, regras de ponto, jobs
│   ├── work_schedule_rules.py
│   ├── restore_backup.py     # decifrar e juntar backups
│   ├── test_*.py             # testes (pytest)
│   ├── requirements.txt
│   └── Dockerfile
├── frontend/                 # app Flutter
│   ├── lib/                  # telas, serviços, cálculo da folha
│   ├── web/                  # index.html, service workers (PWA e push)
│   ├── assets/               # imagens, fontes, modelos do Excel
│   └── test/
├── deploy/                   # scripts do VPS
├── migration/                # migração antiga do AppSheet
├── firestore.rules           # regras de segurança do Firestore
├── firestore.indexes.json
├── docker-compose.yml        # backend + nginx
└── nginx.conf
```

## 🚀 Rodar localmente

### Backend
```bash
cd backend
python -m venv .venv
.venv/Scripts/activate        # Linux/macOS: source .venv/bin/activate
pip install -r requirements.txt
python main.py                # http://localhost:8000
```

Variáveis em `backend/.env` (fora do Git): `FIREBASE_PROJECT_ID`,
`FIREBASE_SERVICE_ACCOUNT_PATH` (ou `FIREBASE_SERVICE_ACCOUNT_JSON`),
`FIREBASE_WEB_API_KEY`, `SECRET_KEY`, `SHARED_ACCESS_TOKEN` (palavra-chave do
site), `MAIL_PASSWORD`, `BACKUP_ZIP_PASSWORD`, `ALLOWED_ORIGINS`,
`ENABLE_API_DOCS`. Sem credencial do Firebase Admin as rotas que usam o
Firestore respondem 503.

### App
```bash
cd frontend
flutter pub get
flutter run -d chrome --dart-define=API_BASE_URL=http://localhost:8000
```
Sem `API_BASE_URL`, o app web usa `<site>/api` e o Android usa
`https://ponto.vmacengenharia.com/api`.

### Docker
```bash
docker compose up -d --build   # backend :8000, site :8080
```

## 🧪 Testes

```bash
cd backend && python -m pytest    # Firestore simulado em memória
cd frontend && flutter test
```

**Ponta a ponta, sem tocar no Firebase real:** com o
[emulador do Firebase](https://firebase.google.com/docs/emulator-suite) e um
projeto `demo-` (que não alcança nenhum projeto real):

```bash
firebase emulators:start --only auth,firestore --project demo-ponto

# backend falando com o emulador
FIRESTORE_EMULATOR_HOST=127.0.0.1:8085 FIREBASE_AUTH_EMULATOR_HOST=127.0.0.1:9099 \
FIREBASE_PROJECT_ID=demo-ponto FIREBASE_WEB_API_KEY=demo-key \
DATABASE_PATH=./data/ponto-emu.db python -m uvicorn main:app --port 8000

# app falando com o emulador
flutter build web --dart-define=USE_FIREBASE_EMULATOR=true \
  --dart-define=API_BASE_URL=http://127.0.0.1:8000
```

## 🚢 Publicar

Produção roda num VPS: `bash /opt/ponto/deploy/atualizar.sh` (detalhes em
[VPS.md](docs/VPS.md)). As **regras do Firestore** não vão nesse script:
`firebase deploy --only firestore:rules`. Mudança de regra que restringe o app
só depois que todos os celulares estiverem na versão nova do app.

## 📊 Migração do AppSheet (histórico)

Scripts da migração inicial em `migration/` (`migrate_from_appsheet.py`, com
exemplos de CSV). Não é usada no dia a dia.
