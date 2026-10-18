#!/usr/bin/env bash
# Atualizacao do dia a dia NO VPS (depois da migracao): puxa o codigo do
# GitHub, gera o build do Flutter aqui mesmo e reinicia o que mudou.
#   bash /opt/ponto/deploy/atualizar.sh
set -euo pipefail

DIR=/opt/ponto
FLUTTER_IMAGE="${FLUTTER_IMAGE:-ghcr.io/cirruslabs/flutter:stable}"
log() { echo "[$(date +%H:%M:%S)] $*"; }

# Volta o site anterior. O nginx monta frontend/build/web: depois de trocar a
# pasta e preciso recriar o container, senao ele segue na pasta apagada e o
# site fica sem pagina (17/10/2026).
voltar_web() {
  log "Falhou: voltando o build anterior do site"
  rm -rf frontend/build/web
  cp -a /root/web-backup frontend/build/web
  docker compose up -d --force-recreate frontend || true
}

cd "$DIR"
log "Puxando codigo"
git pull --ff-only

log "Guardando o build atual em /root/web-backup"
rm -rf /root/web-backup
cp -a frontend/build/web /root/web-backup

log "Build do Flutter ($FLUTTER_IMAGE)"
if ! docker run --rm -v "$DIR/frontend:/app" -w /app "$FLUTTER_IMAGE" \
    sh -c "git config --global --add safe.directory '*'; flutter pub get && flutter build web --release --no-wasm-dry-run"; then
  voltar_web
  exit 1
fi

log "Reiniciando backend e frontend"
if ! docker compose up -d --build backend; then
  # Backend novo nao subiu: o site novo nao fica no ar falando com o backend velho.
  voltar_web
  exit 1
fi
docker compose up -d --force-recreate frontend
docker compose ps
log "ATUALIZADO-OK"
