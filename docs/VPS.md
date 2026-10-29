# Produção no VPS

O ponto roda num VPS Ubuntu 24.04 (Hostinger KVM 1), em `/opt/ponto`, com o
mesmo `docker-compose.yml` do projeto. O site chega pela internet pelo túnel
da Cloudflare (`Ponto-VMac`), rodando no próprio VPS (`systemctl status
cloudflared`). Nenhuma porta fica aberta: o firewall (`ufw`) só deixa entrar
SSH, e o `deploy/docker-compose.vps.yml` prende as portas 8000/8080 ao
`127.0.0.1` (o Docker passaria por cima do ufw).

## Arquivos que não estão no Git

Ficam só no VPS (vieram do PC na migração):

- `backend/.env` (palavra-chave, chaves, senha de e-mail)
- `backend/service-account.json`
- `backend/data/` (SQLite das assinaturas e backups diários)
- `/opt/ponto/.env` com `COMPOSE_FILE=docker-compose.yml:deploy/docker-compose.vps.yml`

## Atualizar

```bash
bash /opt/ponto/deploy/atualizar.sh
```

Puxa a `main`, gera o build do Flutter num container (`ghcr.io/cirruslabs/flutter`),
recria backend e frontend. Carimba a versao no service worker: os celulares
baixam a versao nova sozinhos e recarregam quando ninguem estiver usando a
tela (docs/OFFLINE.md, "Atualizacoes do app"). O build sai em `frontend/build/web-new`, com o site
atual no ar o tempo todo; so no fim a pasta e trocada (a anterior fica em
`frontend/build/web-old`). Se o build ou o backend falhar, nada e trocado.

## Migração (feita uma vez, a partir do PC antigo)

`deploy/vps-instalar.sh` prepara o VPS (Docker, cloudflared, firewall, código).
`deploy/vps-ativar.sh` recebe o pacote do PC (`.env`, service-account,
`backend/data`, `frontend/build/web`), sobe a stack e liga o túnel com o token
do `Ponto-VMac`. Os atalhos do lado do Windows ficaram fora do repositório
(`Downloads\migracao-vps` no PC antigo).

## Diagnóstico rápido

```bash
cd /opt/ponto && docker compose ps
docker compose logs --tail 50 backend
journalctl -u cloudflared --since "-10min"
curl -s http://127.0.0.1:8000/health
```
