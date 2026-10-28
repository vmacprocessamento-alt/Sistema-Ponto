# Operational Configuration

This project uses environment/build-time configuration for operational values. Do not commit local `.env` files, service account JSON files, local databases, virtual environments, build output, or generated caches.

## Backend Environment

Required or commonly used backend variables:

```env
SECRET_KEY=sua-chave-forte
DATABASE_PATH=/app/data/ponto.db
ALLOWED_ORIGINS=https://ponto.vmacengenharia.com
ENABLE_API_DOCS=false
FIREBASE_PROJECT_ID=ponto-vmac
FIREBASE_SERVICE_ACCOUNT_PATH=/caminho/service-account.json
# or FIREBASE_SERVICE_ACCOUNT_JSON={"type":"service_account",...}
FIREBASE_WEB_API_KEY=opcional-para-validacao-rest
MAIL_PASSWORD=senha-de-app-do-google
SHARED_ACCESS_TOKEN=token-para-gate-web
ZAPSIGN_API_TOKEN=token-da-zapsign
ZAPSIGN_API_BASE_URL=https://api.zapsign.com.br/api/v1
ZAPSIGN_APP_URL=https://app.zapsign.com.br/verificar
ZAPSIGN_WEBHOOK_SECRET=segredo-do-webhook
```

Production deployments should keep `ENABLE_API_DOCS=false` unless API docs are protected by a separate access control layer.

## Frontend API URL

The Flutter app reads `API_BASE_URL` through `--dart-define`:

```bash
flutter run --dart-define=API_BASE_URL=https://ponto.vmacengenharia.com/api
flutter build web --release --dart-define=API_BASE_URL=https://ponto.vmacengenharia.com/api
```

Without an override:

- The app (web only) uses `/api` on the current origin.

## Migration Credentials

Migration scripts must receive credentials from the operator:

```bash
set APPSHEET_ADMIN_EMAIL=admin@example.com
set APPSHEET_ADMIN_PASSWORD=troque-esta-senha
set APPSHEET_USER_DEFAULT_PASSWORD=senha-temporaria-forte
python migrate_from_appsheet.py
```

Never use reusable default passwords in real migrations.

## Architecture Contracts

- Backend FastAPI owns HTTP contracts for Firebase authentication, exports, ZapSign documents, notifications, shared access gating, and administrative actions.
- Flutter screens should call service classes such as `ApiService`, `ExportService`, and `NotificationService`.
- Administrative mutations should pass through explicit backend contracts or reviewed Firebase rules.
- OpenSpec changes should identify affected API contracts, specs, and implementation tasks before larger code changes.
