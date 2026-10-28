# 🚀 Guia de Deploy em Produção

> **Produção atual:** VPS com túnel da Cloudflare, ver [VPS.md](VPS.md). Este guia
> é genérico (opções de hospedagem) e parte dele é da versão antiga com SQLite.
> Regras do Firestore: `firebase deploy --only firestore:rules`, sempre depois
> de publicar o site. O app é só web (não há mais APK).

## Opção 1: Deploy Tradicional (VPS/Servidor)

### Backend

1. **Preparar o servidor (Ubuntu/Debian):**
```bash
sudo apt update
sudo apt install python3-pip python3-venv nginx
```

2. **Clonar e configurar:**
```bash
git clone seu-repositorio
cd ponto-system/backend
python3 -m venv venv
source venv/bin/activate
pip install -r requirements.txt
```

3. **Configurar variáveis de ambiente:**
```bash
nano .env
```
Adicione:
```
SECRET_KEY=sua-chave-muito-segura-com-32-caracteres-ou-mais
DATABASE_URL=sqlite:///./ponto.db
```

4. **Criar serviço systemd:**
```bash
sudo nano /etc/systemd/system/ponto-api.service
```

Conteúdo:
```ini
[Unit]
Description=Ponto API
After=network.target

[Service]
User=seu-usuario
WorkingDirectory=/home/seu-usuario/ponto-system/backend
Environment="PATH=/home/seu-usuario/ponto-system/backend/venv/bin"
ExecStart=/home/seu-usuario/ponto-system/backend/venv/bin/uvicorn main:app --host 0.0.0.0 --port 8000
Restart=always

[Install]
WantedBy=multi-user.target
```

5. **Ativar serviço:**
```bash
sudo systemctl daemon-reload
sudo systemctl enable ponto-api
sudo systemctl start ponto-api
```

6. **Configurar Nginx:**
```bash
sudo nano /etc/nginx/sites-available/ponto-api
```

Conteúdo:
```nginx
server {
    listen 80;
    server_name api.seudominio.com;

    location / {
        proxy_pass http://localhost:8000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    }
}
```

7. **Ativar site:**
```bash
sudo ln -s /etc/nginx/sites-available/ponto-api /etc/nginx/sites-enabled/
sudo nginx -t
sudo systemctl restart nginx
```

8. **SSL com Let's Encrypt:**
```bash
sudo apt install certbot python3-certbot-nginx
sudo certbot --nginx -d api.seudominio.com
```

### Frontend (App Flutter)

#### Para Web:
```bash
flutter build web --release
```

Hospedar o conteúdo de `build/web` em:
- Netlify
- Vercel
- Firebase Hosting
- Nginx (servidor próprio)

## Opção 2: Deploy com Docker

1. **No servidor:**
```bash
git clone seu-repositorio
cd ponto-system
```

2. **Configurar .env:**
```bash
nano backend/.env
```

3. **Buildar e executar:**
```bash
docker-compose up -d
```

4. **Configurar Nginx (mesmo processo acima)**

## Opção 3: Deploy em Cloud

### Heroku (Backend)

1. **Criar Procfile:**
```
web: uvicorn main:app --host 0.0.0.0 --port $PORT
```

2. **Deploy:**
```bash
heroku create seu-app-ponto
git push heroku main
```

### Google Cloud Platform

1. **Cloud Run (Backend):**
```bash
gcloud run deploy ponto-api --source .
```

2. **Firebase Hosting (Frontend Web):**
```bash
firebase init hosting
flutter build web
firebase deploy
```

### AWS

1. **Elastic Beanstalk (Backend)**
2. **S3 + CloudFront (Frontend Web)**
3. **App Store / Play Store (Apps Mobile)**

## 🔒 Checklist de Segurança

- [ ] Mudar SECRET_KEY para valor aleatório forte
- [ ] Configurar HTTPS (SSL/TLS)
- [ ] Configurar CORS adequadamente
- [ ] Habilitar rate limiting
- [ ] Configurar backups automáticos do banco
- [ ] Configurar monitoramento e logs
- [ ] Implementar rotação de tokens
- [ ] Configurar firewall
- [ ] Atualizar dependências regularmente
- [ ] Implementar política de senhas fortes

## 📊 Monitoramento

### Logs do Backend:
```bash
sudo journalctl -u ponto-api -f
```

### Health Check:
Configure endpoint `/health` na API e monitore com:
- UptimeRobot
- Pingdom
- New Relic
- DataDog

## 💾 Backup

### Backup automático diário:
```bash
sudo nano /etc/cron.daily/ponto-backup
```

```bash
#!/bin/bash
cp /home/usuario/ponto-system/backend/ponto.db /backups/ponto-$(date +%Y%m%d).db
find /backups -name "ponto-*.db" -mtime +30 -delete
```

```bash
sudo chmod +x /etc/cron.daily/ponto-backup
```

## 🔄 Atualização

```bash
cd ponto-system
git pull
sudo systemctl restart ponto-api
```

## 📱 Distribuição

O app é só web (PWA): atualizar o site já atualiza todo mundo na próxima
abertura. Não há mais APK nem App Store.

## 🆘 Troubleshooting

### API não responde:
```bash
sudo systemctl status ponto-api
sudo journalctl -u ponto-api --since "1 hour ago"
```

### Banco de dados corrompido:
```bash
# Restaurar do backup
cp /backups/ponto-YYYYMMDD.db /home/usuario/ponto-system/backend/ponto.db
sudo systemctl restart ponto-api
```

### Alto uso de memória:
```bash
# Verificar recursos
htop
# Reiniciar serviço
sudo systemctl restart ponto-api
```

## 📈 Escalabilidade

Para crescer o sistema:

1. **PostgreSQL ao invés de SQLite**
2. **Redis para cache**
3. **Load balancer (Nginx/HAProxy)**
4. **Múltiplas instâncias da API**
5. **CDN para assets estáticos**
6. **Separar serviços (microservices)**

---

**Importante:** Este é um guia básico. Ajuste conforme suas necessidades específicas!
