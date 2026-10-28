FROM python:3.12-slim

WORKDIR /app

# Instalar dependências
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copiar código
COPY main.py .
COPY work_schedule_rules.py .

# Expor porta
EXPOSE 8000

# Variáveis de ambiente
ENV DATABASE_URL=sqlite:///./ponto.db

# Executar aplicação
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
