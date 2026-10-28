# ✅ Checklist de Funcionalidades

## 📱 App Mobile/Web (Flutter)

### Autenticação
- [x] Tela de Login (pelo CPF; "Entrar com e-mail" fica de reserva)
- [x] Cadastro só pelo admin (Gestão → Usuários → Novo usuário), com senha temporária aleatória (mostrada uma vez) e mensagem pronta para mandar (copiar ou WhatsApp); não há mais cadastro pelo app
- [x] Primeiro acesso (ou senha redefinida pelo admin): a pessoa cria a própria senha antes de usar o app
- [x] Trocar senha pelo Perfil
- [x] Validação de email
- [x] Validação de senha
- [x] Formatação automática de CPF
- [x] Armazenamento seguro de token
- [x] Logout

### Registro de Ponto
- [x] Registrar entrada
- [x] Registrar saída
- [x] Iniciar pausa
- [x] Encerrar pausa
- [x] Relógio em tempo real
- [x] Status atual visível
- [x] Botões contextuais (aparecem conforme status)
- [x] Feedback visual de sucesso/erro
- [ ] Geolocalização (opcional - código pronto)
- [ ] Foto/biometria (futuro)
- [x] Modo offline (web/PWA e app; ver OFFLINE.md)
- [x] Modo diária: o admin liga no cadastro (Funcionário) e a tela de ponto vira o botão "Adicionar diária", uma por dia (sem internet fica no aparelho e vai depois)
- [x] Modo diária na gestão: tela "Diárias" por pessoa (Usuários ou Registros) para lançar a diária de um dia ou apagar uma, com motivo e auditoria
- [x] Modo diária na Dash, Meu Mês e Histórico: cada diária aparece com o horário padrão do dia, o mesmo da folha exportada

### Dashboard
- [x] Seletor de mês
- [x] Cards de resumo (horas normais/extras)
- [x] Gráfico de horas por dia
- [x] Lista detalhada diária
- [x] Visualização de entrada/saída
- [x] Destaque de horas extras
- [x] Navegação entre meses
- [x] Pull-to-refresh

### Histórico
- [x] Seletor de data
- [x] Lista de registros do dia
- [x] Ícones por tipo de registro
- [x] Horários formatados
- [x] Local de registro
- [x] Observações
- [x] Indicador de sem dados
- [x] Pull-to-refresh

### Perfil
- [x] Exibição de dados do usuário
- [x] Avatar com inicial
- [x] Informações de CPF, email, cargo
- [x] Carga horária configurada
- [x] Botão de logout
- [x] Exportação de folha de ponto
- [ ] Edição de perfil (futuro)
- [ ] Foto de perfil (futuro)
- [ ] Configurações (futuro)

### Exportação
- [x] Seleção de período
- [x] Geração de PDF
- [x] Tabela formatada
- [x] Totalizadores
- [x] Informações do funcionário
- [x] Data de geração
- [x] Modo diária: Excel com a aba "Diárias" (dias trabalhados e total) e a folha de ponto padrão com um dia de trabalho padrão em cada diária
- [ ] Envio por email (futuro)
- [ ] Upload para nuvem (futuro)

## 🔧 Backend (FastAPI)

### Autenticação e Autorização
- [x] Registro de usuários
- [x] Login com email/senha
- [x] Geração de JWT
- [x] Validação de JWT
- [x] Hash de senhas (bcrypt)
- [x] Controle de roles (employee, manager, admin)
- [ ] Refresh tokens (futuro)
- [ ] 2FA (futuro)
- [ ] Recuperação de senha (futuro)

### Gestão de Usuários
- [x] Criar usuário
- [x] Buscar usuário atual
- [x] Validação de email único
- [x] Validação de CPF único
- [ ] Listar todos usuários (admin) (futuro)
- [ ] Editar usuário (futuro)
- [ ] Desativar usuário (futuro)
- [ ] Resetar senha (futuro)

### Registro de Ponto
- [x] Criar registro (entrada, saída, pausas)
- [x] Listar registros por período
- [x] Filtro por data
- [x] Associação com usuário
- [x] Captura de timestamp automático
- [x] Campo de localização
- [x] Campo de observações
- [ ] Edição de registros (futuro)
- [ ] Exclusão de registros (futuro)
- [ ] Aprovação de ajustes (futuro)

### Relatórios
- [x] Resumo de trabalho por período
- [x] Cálculo de horas normais
- [x] Cálculo de horas extras
- [x] Agrupamento por dia
- [x] Horário de entrada/saída
- [x] Subtração de pausas
- [x] Exportação para contabilidade
- [ ] Relatório consolidado mensal (futuro)
- [ ] Relatório por departamento (futuro)
- [ ] Gráficos de análise (futuro)

### Banco de Dados
- [x] Modelo de Usuário (User)
- [x] Modelo de Registro (TimeRecord)
- [x] Relacionamentos (user → records)
- [x] Índices para performance
- [x] Validações
- [x] SQLite (desenvolvimento)
- [ ] PostgreSQL (produção) (configurável)
- [ ] Migrations automáticas (futuro)

### API e Documentação
- [x] Swagger UI (/docs)
- [x] ReDoc (/redoc)
- [x] CORS configurado
- [x] Validação com Pydantic
- [x] Respostas padronizadas
- [x] Tratamento de erros
- [ ] Rate limiting (futuro)
- [ ] Versionamento da API (futuro)
- [ ] Webhooks (futuro)

## 🔄 Migração

### Script de Migração
- [x] Leitura de CSV
- [x] Mapeamento de usuários
- [x] Mapeamento de registros
- [x] Criação de admin automática
- [x] Validação de dados
- [x] Relatório de migração
- [x] Tratamento de erros
- [ ] Rollback em caso de erro (futuro)
- [ ] Migração incremental (futuro)

### Dados Suportados
- [x] Usuários (nome, email, CPF, cargo)
- [x] Registros de ponto
- [x] Carga horária personalizada
- [ ] Departamentos (futuro)
- [ ] Férias e folgas (futuro)
- [ ] Banco de horas (futuro)

## 📚 Documentação

- [x] README completo
- [x] Guia de instalação rápida
- [x] Guia de deploy
- [x] Diagrama de arquitetura
- [x] Checklist de funcionalidades
- [x] Exemplos de CSV
- [x] Docker compose
- [x] Dockerfile
- [ ] Vídeo tutorial (futuro)
- [ ] API docs detalhada (futuro)

## 🔒 Segurança

- [x] Autenticação JWT
- [x] Hash de senhas
- [x] CORS configurado
- [x] Validação de inputs
- [x] SQL injection protection (ORM)
- [x] XSS protection
- [ ] Rate limiting (futuro)
- [ ] IP whitelist (futuro)
- [ ] Auditoria de acessos (futuro)

## 🚀 DevOps

- [x] Dockerfile
- [x] Docker Compose
- [x] Variáveis de ambiente
- [x] Guia de deploy VPS
- [x] Guia de deploy Cloud
- [ ] CI/CD (GitHub Actions) (futuro)
- [ ] Monitoramento (futuro)
- [ ] Backup automático (futuro)
- [ ] Health checks (futuro)

## 📊 Próximas Features Planejadas

### Alta Prioridade
- [ ] Notificações push
- [ ] Modo offline
- [ ] Aprovação de ajustes de ponto
- [ ] Banco de horas
- [ ] Relatórios gerenciais

### Média Prioridade
- [ ] Reconhecimento facial
- [ ] Múltiplas empresas
- [ ] Departamentos
- [ ] Férias e folgas
- [ ] Integração com folha de pagamento

### Baixa Prioridade
- [ ] Chat interno
- [ ] Sistema de tarefas
- [ ] Gamificação
- [ ] Dashboard executivo
- [ ] App para Apple Watch / Wear OS

---

**Legenda:**
- [x] Implementado
- [ ] Planejado/Futuro
