#!/usr/bin/env bash
# Atualizacao do dia a dia NO VPS (depois da migracao): puxa o codigo do
# GitHub, gera o build do Flutter aqui mesmo e reinicia o que mudou.
#   bash /opt/ponto/deploy/atualizar.sh
#
# O site NAO sai do ar durante o build: o Flutter compila em
# frontend/build/web-new (pasta a parte) enquanto o nginx segue servindo
# frontend/build/web. So no fim as pastas sao trocadas e o container do
# frontend e recriado. Antes, o build apagava a pasta servida logo no
# inicio e o site ficava em branco pelo tempo da compilacao (que num VPS
# pequeno passa de 10 minutos).
set -euo pipefail

DIR=/opt/ponto
FLUTTER_IMAGE="${FLUTTER_IMAGE:-ghcr.io/cirruslabs/flutter:stable}"
WEB=frontend/build/web
WEB_NEW=frontend/build/web-new
WEB_OLD=frontend/build/web-old
log() { echo "[$(date +%H:%M:%S)] $*"; }

# Desfaz a troca de pastas se o nginx nao subir com o build novo. O nginx
# monta frontend/build/web: depois de trocar a pasta e preciso recriar o
# container, senao ele segue na pasta antiga (17/10/2026).
voltar_web() {
  log "Falhou: voltando o build anterior do site"
  if [ -d "$WEB_OLD" ]; then
    rm -rf "$WEB"
    mv "$WEB_OLD" "$WEB"
    docker compose up -d --force-recreate frontend || true
  fi
}

cd "$DIR"
log "Puxando codigo"
# O "flutter pub get" dentro do container reescreve o pubspec.lock (versao do
# Flutter da imagem difere da do PC) e arquivos gerados de plataforma. Sao
# artefatos, nao mudancas de ninguem; sem descartar, o pull recusa com
# "local changes would be overwritten" (aconteceu em 28/10/2026).
git checkout -- frontend/pubspec.lock 2>/dev/null || true
git checkout -- frontend/linux frontend/macos frontend/windows 2>/dev/null || true
git pull --ff-only

# Versao do app: sobe sozinha a cada deploy que da certo (0.1, 0.2, 0.3...).
# A ultima fica em backend/data/versao-app.txt (fora do Git, junto com o
# banco e os backups). Para mudar a numeracao (ex.: passar para 1.0), grave
# a nova base nesse arquivo: o proximo deploy sai 1.1.
VERSION_FILE=backend/data/versao-app.txt
LAST_VERSION=""
if [ -f "$VERSION_FILE" ]; then LAST_VERSION="$(tr -d ' \r\n' < "$VERSION_FILE")"; fi
# Sem arquivo (primeiro deploy) ou conteudo que nao e numero.numero: 0.1.
[[ "$LAST_VERSION" =~ ^[0-9]+\.[0-9]+$ ]] || LAST_VERSION="0.0"
APP_VERSION="${LAST_VERSION%.*}.$(( ${LAST_VERSION##*.} + 1 ))"
# Carimbo unico do deploy (o service worker muda e os celulares atualizam).
BUILD_ID="$APP_VERSION $(git rev-parse --short HEAD) $(date +%Y-%m-%d_%H:%M)"
log "Versao do app neste deploy: $APP_VERSION"

log "Build do Flutter ($FLUTTER_IMAGE) em $WEB_NEW (o site atual continua no ar)"
rm -rf "$WEB_NEW"
if ! docker run --rm -v "$DIR/frontend:/app" -w /app "$FLUTTER_IMAGE" \
    sh -c "git config --global --add safe.directory '*'; flutter pub get && flutter build web --release --no-wasm-dry-run --dart-define=APP_VERSION=$APP_VERSION --output build/web-new"; then
  rm -rf "$WEB_NEW"
  echo "Build do site falhou; nada foi trocado, o site anterior segue no ar."
  exit 1
fi
test -f "$WEB_NEW/index.html"

# Carimba a versao no service worker: arquivo diferente faz o navegador de
# cada celular baixar a versao nova em segundo plano e o app recarregar
# sozinho quando ninguem estiver usando a tela (atualizacao automatica,
# docs/OFFLINE.md). Sem o carimbo os aparelhos so atualizam ao recarregar.
printf '\n// build: %s\n' "$BUILD_ID" >> "$WEB_NEW/pwa_service_worker.js"

log "Reiniciando backend"
if ! docker compose up -d --build backend; then
  # Backend novo nao subiu: o site novo nao fica no ar falando com o backend velho.
  rm -rf "$WEB_NEW"
  echo "Backend nao subiu; o site anterior segue no ar."
  exit 1
fi

log "Trocando o site pelo build novo"
rm -rf "$WEB_OLD"
if [ -d "$WEB" ]; then mv "$WEB" "$WEB_OLD"; fi
mv "$WEB_NEW" "$WEB"
if ! docker compose up -d --force-recreate frontend; then
  voltar_web
  exit 1
fi
docker compose ps
# So agora a versao conta como usada: deploy que falhou nao pula numero.
mkdir -p "$(dirname "$VERSION_FILE")"
echo "$APP_VERSION" > "$VERSION_FILE"
log "ATUALIZADO-OK - Versao $APP_VERSION (aparece no Perfil de cada um; build anterior em $WEB_OLD)"
