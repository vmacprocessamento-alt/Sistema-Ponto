# Modo offline (web / PWA)

O app em `ponto.vmacengenharia.com` abre e registra ponto sem internet depois
de **uma** abertura com internet (login feito). Os pontos ficam guardados no
aparelho e sobem sozinhos quando o sinal volta.

## O que acontece sem internet

| Etapa | Como funciona |
|---|---|
| Abrir o app | O service worker (`frontend/web/pwa_service_worker.js`) serve a copia salva de `index.html`, `main.dart.js`, canvaskit e assets. |
| Texto na tela | A fonte Roboto vem embutida no app (`frontend/assets/fonts`, declarada no `pubspec.yaml`). Sem ela o Flutter web baixa a Roboto do `fonts.gstatic.com` e, offline, a tela abria com cores e icones mas **sem nenhum texto** (visto no iPhone). Fontes extras que o Flutter busca para simbolos tambem vao para o cache `vmac-ponto-vendor`. |
| Firebase iniciar | O SDK JS do Firebase (`www.gstatic.com/firebasejs/...`) tambem fica no cache do service worker. Sem isso o app parava em "Nao foi possivel iniciar o aplicativo". |
| Sessao | O Firebase Auth guarda a sessao no IndexedDB; nao pede senha de novo. |
| Perfil e pontos do dia | Copia propria em `SharedPreferences` (`ApiService`): o perfil e os pontos dos ultimos 15 dias lidos online por ultimo, mais os pontos confirmados pelo servidor. A tela de ponto abre na hora a partir dela (com ou sem internet) e se atualiza com o servidor em segundo plano. |
| Cache do Firestore | **Desligado no web** (`main.dart`). Com o cache em IndexedDB ligado, o Safari do iPhone travava o Firestore depois de fechar e reabrir o app e a tela de ponto girava sem fim, com ou sem internet. |
| Bater ponto | `ApiService.createTimeRecord` detecta a falta de rede e grava na fila local (`SharedPreferences`), com id de documento ja definido. A tela avisa "Sem internet. Registro salvo no aparelho". |
| Internet volta | `HomeScreen` sincroniza ao detectar conexao, a cada 60 s e no puxar-para-atualizar. Cada registro e gravado no Firestore com o mesmo id, entao nao duplica. |
| Estagiario | Entrada/saida passam pelo backend (`/work-schedule/punch`). Sem rede, o ponto vai para a fila e a sincronizacao reenvia pelo mesmo endpoint, com as regras de horario. |

## Regras importantes

- **Primeira vez precisa de internet.** O cache so existe depois de uma
  abertura online completa (tela de ponto carregada). Oriente a equipe a abrir
  o app no escritorio antes de ir para o campo.
- **A hora registrada e a do aparelho.** Igual ao modo online: o campo
  `timestamp` vem do celular; `created_at` (hora do servidor) so e preenchido
  quando o registro chega ao Firestore. Para auditar, compare os dois.
- **Instalar como app** (menu do navegador > "Adicionar a tela inicial") e
  recomendado: o navegador preserva melhor o cache de apps instalados.
- Limpar os dados do site no navegador apaga o cache E a fila de pontos que
  ainda nao subiu. Antes de limpar, confira na tela inicial se ha
  "registro(s) aguardando internet".

## Atualizacoes do app (automaticas)

Depois de um deploy, cada celular atualiza sozinho, sem ninguem fechar o app
nem dar F5:

1. O `deploy/atualizar.sh` carimba a versao na ultima linha do
   `pwa_service_worker.js` (`// build: <commit>-<data>`).
2. O app confere se o service worker mudou so quando a pessoa usa o app: ao
   abrir (voltar para a tela), trocar de aba e registrar ponto ou diaria. No
   maximo uma vez a cada 5 min (`index.html`, `vmacCheckForUpdate`). Cada
   conferencia e um pedido pequeno do `pwa_service_worker.js`; sem mudanca o
   servidor responde "nao mudou" (304). Nao le o banco de dados.
3. Mudou: o service worker novo baixa a versao nova inteira em segundo plano
   (`index.html`, `main.dart.js`, canvaskit, fontes). Se algum arquivo
   essencial nao vier, a instalacao falha e tenta de novo depois; a versao
   atual segue funcionando e nunca fica meio velha, meio nova.
4. Baixou: ele assume a pagina e marca `vmacUpdateReady`. O app
   (`lib/services/update_service.dart`) recarrega no primeiro momento seguro:
   10 s sem toque na tela, nenhum dialogo ou tela por cima, nenhum campo de
   texto com cursor e nenhuma batida, diaria ou sincronizacao em andamento.
   A tela de abertura mostra "Atualizando o VMac Ponto...".
5. Se o momento seguro nao chega em 20 s (ex.: chat aberto), aparece no topo
   a barra **"Nova versão do app disponível. ATUALIZAR"**.

Trava contra loop: no automatico, no maximo uma recarga a cada 2 min.

**Versao do app.** O Perfil e a tela de login mostram "Versão 0.3". O numero
sobe sozinho a cada deploy que da certo (0.1, 0.2, 0.3...): o `atualizar.sh`
guarda a ultima em `backend/data/versao-app.txt` no VPS e a passa ao build
(`--dart-define=APP_VERSION`). No fim do deploy ele imprime
`ATUALIZADO-OK - Versao 0.3`. No suporte, compare com o Perfil da pessoa.
Sem a linha de versao no Perfil, o celular esta com um app de antes de
29/10/2026. Para mudar a numeracao (ex.: passar para 1.0), grave `1.0` nesse
arquivo: o proximo deploy sai `1.1`.

**Apps de antes da atualizacao automatica.** O service worker novo, ao
ativar, pergunta a cada pagina aberta se ela sabe se atualizar sozinha. A
que nao responde em 2 s (app antigo) e recarregada por ele, uma unica vez,
ja na versao nova. O navegador busca o service worker novo quando o app
antigo recarrega ou, com ele aberto, ate 24 h depois da ultima conferencia.

O nginx manda `Cache-Control: no-cache` para js/wasm/json: o navegador pode
guardar, mas revalida com ETag. Arquivo que nao mudou custa um 304. Para forcar
uma limpeza geral do cache (raro), mude `CACHE_VERSION` em
`pwa_service_worker.js`.

## Deploy

Pelo `deploy/atualizar.sh` no VPS (docs/VPS.md), que ja numera e carimba a
versao. Um build feito a mao aparece como "Versão de teste" e precisa do
carimbo para os celulares atualizarem sozinhos:

```bash
printf '\n// build: %s\n' "$(date +%Y%m%d%H%M%S)" >> frontend/build/web/pwa_service_worker.js
```

## Teste rapido

1. Abra o app com internet, faca login e espere a tela de ponto.
2. Ative o modo aviao.
3. Feche o app e abra de novo: deve carregar e mostrar o status do dia.
4. Bata um ponto: aparece "Sem internet. Registro salvo no aparelho" e o
   registro na lista com o icone de sincronizacao pendente.
5. Desligue o modo aviao: em ate 60 s o aviso "registro(s) aguardando
   internet" some e o ponto aparece no Firestore.

## Diagnostico

No Chrome: `chrome://inspect` (celular via USB) ou DevTools > Application:

- **Service Workers**: `pwa_service_worker.js` deve estar "activated".
- **Cache Storage**: `vmac-ponto-shell-v1` (arquivos do site) e
  `vmac-ponto-vendor-v1` (SDK do Firebase e fontes do Google).
- **IndexedDB**: `firebaseLocalStorageDb` (sessao). O Firestore nao usa
  IndexedDB no web.
- **Local Storage**: `flutter.cached_current_user`,
  `flutter.cached_time_records_<uid>` e `flutter.offline_time_records` (fila).
