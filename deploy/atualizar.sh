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
git pull --ff-only

log "Build do Flutter ($FLUTTER_IMAGE) em $WEB_NEW (o site atual continua no ar)"
rm -rf "$WEB_NEW"
if ! docker run --rm -v "$DIR/frontend:/app" -w /app "$FLUTTER_IMAGE" \
    sh -c "git config --global --add safe.directory '*'; flutter pub get && flutter build web --release --no-wasm-dry-run --output build/web-new"; then
  rm -rf "$WEB_NEW"
  echo "Build do site falhou; nada foi trocado, o site anterior segue no ar."
  exit 1
fi
test -f "$WEB_NEW/index.html"

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
log "ATUALIZADO-OK (build anterior guardado em $WEB_OLD)"
