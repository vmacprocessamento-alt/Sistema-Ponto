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
| Batida de ponto (todos) | **backend** (`/time-records/punch`, `/work-schedule/punch`) | hora do servidor online, até 48 horas de atraso offline (relógio conferido), GPS obrigatório, confere o turno aberto. As regras do Firestore não deixam o app gravar ponto. |
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
5. **Fuso do celular** (03/11/2026): toda batida, pedido de liberação e
   diária manda `utc_offset_minutes` (minutos a leste de UTC: Mato Grosso =
   -240) e `time_zone` (`America/Cuiaba`); a fila offline guarda os dois e os
   reenvia iguais. O servidor compara o momento real com o relógio dele (antes
   a hora de MT parecia uma hora atrasada e era recusada) e grava a **hora
   local de onde a pessoa bateu**, com o fuso no próprio ponto. O estagiário
   segue o fuso do horário dele. Só fusos do Brasil, de UTC-5 a UTC-2. Sem os
   campos (app antigo), vale Brasília. O fechamento automático de pausa mede a
   pausa no fuso dela, e a Gestão mostra o fuso das batidas feitas fora de
   Brasília.
6. **Segurança da batida** (03/11/2026, versão 0.7):
   - **Fuso preso ao turno.** A entrada define o fuso; pausas e saída do mesmo
     turno gravam no fuso dela, qualquer que seja o do celular (trocar o fuso no
     meio do turno rendia uma hora). O fuso do celular, se diferente, fica em
     `device_utc_offset_minutes`.
   - **Relógio da batida offline.** Toda resposta do backend leva
     `X-Server-Time` (UTC). O app (`services/server_clock.dart`) guarda a do
     último contato e a hora do celular no mesmo momento, e a batida offline
     leva as duas (`server_anchor`, `device_anchor`) e, se o app não foi
     fechado, o cronômetro desde o contato (`anchor_elapsed_ms`). O servidor
     (`_offline_punch_moment`) corrige a hora pelo erro do relógio
     (`clock_skew_seconds`) e recusa a batida que ficar antes do contato (ou
     antes de contato + cronômetro), no futuro ou com mais de **48 horas**.
     Fila de app antigo, sem as âncoras: só a janela, e o ponto fica com
     `offline_without_anchor`.
   - **GPS obrigatório**, dentro do Brasil. Sem ele o app não bate (explica como
     ligar) e o servidor recusa. Ficam de fora a saída esquecida, o retorno
     automático da pausa, o fechar no horário programado e a fila de app antigo.
     A diária não pede GPS.
   - **Tentativas recusadas** suspeitas (relógio mexido, offline velha, GPS fora
     do Brasil, hora longe do servidor) vão para `punch_rejections`.
   - **Aba Conferência** na Gestão (`screens/punch_review_screen.dart`): lista as
     batidas para olhar (regras em `utils/punch_review.dart`: offline enviada 30
     min+ depois, relógio 5 min+ diferente, entrada fora de Brasília, fuso
     trocado no turno) com link do mapa, e as tentativas recusadas. Sem GPS não
     entra: o servidor já recusa, e as que ficam sem ele são antigas ou do
     "Fechar ponto" do estagiário. Conferir é opcional: a batida conta na folha
     de qualquer jeito.
     "Conferido" (`POST /admin/time-records/review`) grava `reviewed_at` e
     `reviewed_by` no ponto e uma linha em `time_record_audits`.
   - **Confirmação da batida** (04/11/2026, `widgets/punch_confirm_dialog.dart`):
     toda batida pede um segundo toque mostrando o tipo e a hora (toque sem
     querer abria turno). A saída do turno de outro dia já é confirmada no aviso
     "Finalizar turno aberto".
   - **Retorno real substitui o automático** (04/11/2026): o retorno da pausa que
     chega da fila offline depois de o sistema fechar a pausa sozinho apaga o
     retorno automático (`autoclose_<pausa>`, cópia em `time_record_audits`).
   - **Jornada sem limite** (09/11/2026): o servidor grava em toda batida feita
     com turno aberto o `shift_entry_id` (a entrada do turno); a saída do
     "Esqueci" e o retorno automático da pausa também, e o lote do gestor liga os
     pontos à entrada do lote. Ponto ligado é do turno na folha
     (`groupRecordsByWorkDay`), no Dash e no Resumo, mesmo passando de 16h
     (deslocamento). O aviso de turno aberto sempre oferece "Registrar saída
     agora". A saída com mais de 16h leva `long_shift_minutes` e aparece na
     Conferência. Ponto antigo, sem a ligação, segue a regra das 16h
     (`maxShiftSpan`): a folha de meses passados não muda. No lote, mais de 16h
     pede confirmação em vez de recusar.
   - Limite que fica: sem internet não há relógio confiável. Adiantar a hora do
     celular, bater a saída offline e só sincronizar depois que a hora real
     passar não é provado pelo servidor; essa batida aparece na Conferência
     (offline enviada muito depois).

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
