# Arquitetura do Sistema de Ponto

Atualizado em 28/10/2026. Para quem vai mexer no código: como as peças se
encaixam, por onde passa cada operação e onde ficam as regras.

## Visão geral

```
 Navegador (celular ou PC), app web/PWA
            │
            │  Flutter: Firebase Auth + Firestore (leitura) + HTTP (backend)
            ▼
 ┌──────────────────────┐        ┌──────────────────────────────┐
 │ Cloudflare (túnel)   │        │ Firebase (projeto ponto-vmac) │
 └──────────┬───────────┘        │  • Authentication             │
            ▼                     │  • Firestore (dados)          │
 ┌──────────────────────┐        │  • Cloud Messaging (push)     │
 │ nginx  (frontend)    │        └──────────────▲───────────────┘
 │  • app web estático  │                       │ Admin SDK
 │  • /api/ → backend   │        ┌──────────────┴───────────────┐
 └──────────┬───────────┘───────▶│ backend FastAPI (Python 3.12)│
            │                     │  • regras de ponto           │
            │                     │  • login por CPF, cadastro   │
            │                     │  • exportação Excel/HTML     │
            │                     │  • jobs: pausas, backup      │
            │                     │  • SQLite: assinaturas       │
            │                     └──────────────────────────────┘
```

Produção: um VPS com `docker compose` (serviços `backend` e `frontend`), sem
porta aberta para a internet; o acesso chega pelo túnel da Cloudflare
(detalhes em [VPS.md](VPS.md)).

## Quem grava o quê

| Dado | Quem grava | Por quê |
|---|---|---|
| Batida de ponto (todos) | **backend** (`/time-records/punch`, `/work-schedule/punch`) | hora do servidor online, até 7 dias de atraso offline, confere o turno aberto. As regras do Firestore não deixam o app gravar ponto. |
| Lançamento em lote do gestor | app, direto no Firestore | regra: só admin e gestor |
| Edição de ponto | app do admin, direto (transação com auditoria) | regra: só admin |
| Cadastro e edição de usuário, senha | **backend** (Admin SDK) | cria a conta no Auth com senha temporária aleatória |
| Diária (modo diária) | **backend** (`/daily-entries`) | uma por pessoa por dia |
| Pedido de liberação de horário (estagiário) | **backend** | confere a janela de horário e avisa os gestores |
| Token de push (`fcm_tokens`) | app, direto no próprio cadastro | regra permite só esses campos |

O app **lê** o Firestore direto (pontos, perfil, pedidos), sempre pelas regras
de `firestore.rules`.

## Fluxos principais

### Login
1. Pessoa digita CPF e senha → `POST /api/auth/cpf-login`.
2. O backend acha o cadastro pelo campo `cpf_digits` (uma leitura), confere a
   senha no Firebase Auth e devolve o e-mail da conta (o real ou o interno
   `<cpf>@cpf.ponto...`).
3. O app entra no Firebase Auth com esse e-mail. Limite de tentativas: 10 por
   CPF e 30 por IP (o IP real vem do `CF-Connecting-IP`) a cada 15 min.
4. Primeiro acesso (`must_change_password`): o app pede a senha nova
   (`POST /api/me/password`). Enquanto a troca estiver pendente, o backend
   responde 403 em todos os outros endpoints (cabeçalho
   `X-Password-Change-Required: 1`); a senha padrão não dá acesso à API.
   Fora do primeiro acesso, trocar a senha exige a senha atual
   (`current_password`).

### Bater ponto
1. Toque no botão: o GPS começa na hora, junto com a conferência dos pontos.
2. Estagiário, entrada/saída: `POST /api/work-schedule/punch` (horário
   controlado; fora da janela devolve `approval_required` e o app oferece o
   pedido de liberação). Demais batidas: `POST /api/time-records/punch`.
3. Sem internet ou backend fora do ar (404/5xx): a batida vai para a **fila
   do aparelho** (`SharedPreferences`), com id gerado no aparelho. A cada 60 s
   e quando a rede volta, a fila reenvia pelo mesmo endpoint com
   `offline: true`; o mesmo id devolve o ponto já gravado em vez de duplicar.
4. Casos calculados no servidor: saída esquecida (`kind: forgotten_exit`,
   saída 1 s depois da entrada) e pausa vencida (`kind: auto_break_close`,
   pausa aberta há 3 h fecha com 1 h). O job do backend também fecha pausas
   vencidas a cada 15 min, com o mesmo id (`autoclose_<pausa>`).

### Autenticação no backend
Toda rota autenticada recebe o token do Firebase (`Authorization: Bearer`).
O backend confere o token (guardado 5 min em memória) e lê o perfil em
`users/<uid>` com o próprio token do usuário. Um cliente HTTP só é
reaproveitado para as chamadas ao Google.

Rotas que só fazem trabalho bloqueante (Firestore, planilhas) são `def`: o
FastAPI as roda no thread pool e o servidor não para enquanto o Firestore
responde.

## Coleções do Firestore

| Coleção | Conteúdo |
|---|---|
| `users` | cadastro (nome, `cpf`, `cpf_digits`, cargo, jornada, `daily_mode`, `fcm_tokens`...) |
| `time_records` | batidas: `user_id`, `record_type` (`check_in`, `check_out`, `break_start`, `break_end`, `entry_3`, `exit_3`), `timestamp` (hora local sem fuso), `created_at` (hora do servidor) |
| `time_record_audits` | edições de ponto pelo admin |
| `daily_entries` | diárias (`<uid>_<aaaa-mm-dd>`) |
| `work_schedule_settings` | horário padrão do estagiário |
| `work_schedule_approval_requests` | pedidos de liberação de horário |
| `user_notifications` | avisos do sino |
| `adjustment_requests`, `adjustment_conversations` | chat de ajustes com o RH |
| `signature_documents` | documentos para assinatura (ZapSign) |
| `system_audits`, `user_audits` | auditoria de ações do admin |

Plano gratuito (Spark: 50 mil leituras/dia). Por isso: consultas com filtro de
data/tipo, recargas periódicas só com a tela à vista, backup incremental.

## Jobs do backend (lifespan)
- **Fecha pausas vencidas** a cada 15 min.
- **Backup**: completo uma vez por semana, incremental nos outros dias (só o
  que mudou nas coleções que crescem), em `backend/data/backups/`, cópia no
  Storage quando disponível e o completo por e-mail cifrado uma vez por
  semana. Restaurar: `backend/restore_backup.py` (decifrar e `juntar`).

## App (Flutter)
- `lib/services/api_service.dart`: todo acesso a dados (backend, Firestore,
  fila offline, cópia local dos pontos).
- `lib/screens/main_screen.dart`: abas montadas no primeiro toque.
- `lib/utils/`: cálculo da folha (`timesheet.dart`), turnos
  (`shift_records.dart`), CPF, regras de horário.
- Web: `pwa_service_worker.js` (abre offline; rede primeiro com 3 s de
  espera) e `firebase-messaging-sw.js` (push).

## Testes
- Backend: `cd backend && python -m pytest` (Firestore simulado em memória).
- App: `cd frontend && flutter test`.
- Ponta a ponta contra o **emulador do Firebase** (nada toca o Firebase real),
  app web no Chrome: pasta `e2e/` (ver `e2e/README.md`). Em resumo:
  `firebase emulators:start --only auth,firestore --project demo-ponto` e o
  app compilado com `--dart-define=USE_FIREBASE_EMULATOR=true
  --dart-define=API_BASE_URL=http://127.0.0.1:8000`.
