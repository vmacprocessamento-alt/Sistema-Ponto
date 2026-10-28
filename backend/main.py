import os
import asyncio
import random
import shutil
import tempfile
import zipfile
import html
import re
import base64
import json
import sqlite3
import hashlib
import hmac
import secrets
import logging
from contextlib import asynccontextmanager
from datetime import datetime, timedelta, time, date
from calendar import monthrange
from typing import Optional, List, Dict, Any
from zoneinfo import ZoneInfo

import httpx
import openpyxl
from openpyxl.styles import Alignment, Font, Border, Side
from fastapi import FastAPI, HTTPException, UploadFile, File, Form, Depends, Request
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse, HTMLResponse, RedirectResponse, Response
from fastapi_mail import FastMail, MessageSchema, ConnectionConfig, MessageType
from pydantic import BaseModel
from starlette.background import BackgroundTask

from work_schedule_rules import (
    DEFAULT_INTERN_WORK_SCHEDULE as RULES_DEFAULT_INTERN_WORK_SCHEDULE,
    is_start_within_schedule,
    time_on_day,
    validate_work_schedule,
)

logger = logging.getLogger(__name__)

try:
    import firebase_admin
    from firebase_admin import auth as firebase_auth
    from firebase_admin import credentials, firestore, messaging, storage
except ImportError:
    firebase_admin = None
    firebase_auth = None
    credentials = None
    firestore = None
    messaging = None
    storage = None

try:
    # Erro do create() do Firestore quando o documento ja existe.
    from google.api_core.exceptions import AlreadyExists
except ImportError:
    class AlreadyExists(Exception):
        pass

# --- CONFIGURAÇÕES ---
SECRET_KEY = os.getenv("SECRET_KEY", "").strip()
if not SECRET_KEY or SECRET_KEY in {
    "sua-chave-secreta-aqui-mude-em-producao",
    "sua-chave-secreta-super-segura-mude-isso",
    "change-this-in-production",
}:
    logger.warning("SECRET_KEY ausente ou insegura; usando chave temporaria desta execucao.")
    SECRET_KEY = secrets.token_urlsafe(32)
ALGORITHM = "HS256"
ACCESS_TOKEN_EXPIRE_MINUTES = 30
ZAPSIGN_API_TOKEN = os.getenv("ZAPSIGN_API_TOKEN", "")
ZAPSIGN_API_BASE_URL = os.getenv(
    "ZAPSIGN_API_BASE_URL",
    "https://sandbox.api.zapsign.com.br/api/v1",
).rstrip("/")
ZAPSIGN_APP_URL = os.getenv(
    "ZAPSIGN_APP_URL",
    "https://sandbox.app.zapsign.com.br/verificar",
).rstrip("/")
ZAPSIGN_WEBHOOK_SECRET = os.getenv("ZAPSIGN_WEBHOOK_SECRET", "")
DATABASE_PATH = os.getenv("DATABASE_PATH", "/app/data/ponto.db")
FIREBASE_WEB_API_KEY = os.getenv("FIREBASE_WEB_API_KEY", "")
SHARED_ACCESS_TOKEN = os.getenv("SHARED_ACCESS_TOKEN", "")
SHARED_ACCESS_COOKIE = "ponto_access"
ENABLE_API_DOCS = os.getenv("ENABLE_API_DOCS", "false").strip().lower() in {
    "1",
    "true",
    "yes",
    "sim",
}
ALLOWED_ORIGINS = [
    origin.strip()
    for origin in os.getenv(
        "ALLOWED_ORIGINS",
        "https://ponto.vmacengenharia.com,http://localhost:8080,http://127.0.0.1:8080",
    ).split(",")
    if origin.strip()
]

# Configurações de E-mail
MAIL_USERNAME = "vmac.rh.01@gmail.com"
# ATENÇÃO: Use uma "App Password" do Google, não a senha normal.
MAIL_PASSWORD = os.getenv("MAIL_PASSWORD", "mude-me")
MAIL_FROM = "vmac.rh.01@gmail.com"
MAIL_PORT = 587
MAIL_SERVER = "smtp.gmail.com"
MAIL_FROM_NAME = "Assistente VMac"

conf = ConnectionConfig(
    MAIL_USERNAME=MAIL_USERNAME,
    MAIL_PASSWORD=MAIL_PASSWORD,
    MAIL_FROM=MAIL_FROM,
    MAIL_PORT=MAIL_PORT,
    MAIL_SERVER=MAIL_SERVER,
    MAIL_FROM_NAME=MAIL_FROM_NAME,
    MAIL_STARTTLS=True,
    MAIL_SSL_TLS=False,
    USE_CREDENTIALS=True,
    VALIDATE_CERTS=True
)

# Regras de Horários e Valores (Conforme Ponto.py)
NORMAL_INI = time(13, 30)
NORMAL_FIM = time(19, 30)

RATE_NORMAL = 8.33
RATE_EXTRA = 8.33
RATE_50 = 12.50
RATE_100 = 16.66

# Resumo financeiro (B41:E44)
SUMMARY_ROW_TITLE = 41
SUMMARY_ROW_HOURS = 42
SUMMARY_ROW_VALUE = 43
SUMMARY_ROW_FINAL = 44
SUMMARY_START_COL = 2

@asynccontextmanager
async def _lifespan(_app):
    """Sobe com o servidor: tabela local das assinaturas e os jobs de fundo
    (fechar pausas vencidas, backup). Desce fechando os clientes HTTP. As
    funcoes ficam mais abaixo; o nome so e resolvido quando o servidor sobe."""
    init_signature_documents_table()
    jobs = [asyncio.create_task(_auto_close_breaks_loop()), asyncio.create_task(_backup_loop())]
    try:
        yield
    finally:
        for job in jobs:
            job.cancel()
        await _close_http_clients()

app = FastAPI(
    lifespan=_lifespan,
    title="Ponto System API",
    docs_url="/docs" if ENABLE_API_DOCS else None,
    redoc_url="/redoc" if ENABLE_API_DOCS else None,
    openapi_url="/openapi.json" if ENABLE_API_DOCS else None,
)
security = HTTPBearer(auto_error=True)


@app.get("/health")
async def health():
    """Sonda do healthcheck do Docker: so diz que o processo responde.

    Nao toca no Firestore de proposito - roda a cada 30s e comeria cota a toa.
    """
    return {"status": "ok"}


def _normalize_access_key(value: str) -> str:
    """Palavra-chave sem diferenca de maiuscula/minuscula nem espacos nas
    pontas: o pessoal digita no celular, muitas vezes com corretor ligado."""
    return (value or "").strip().lower()


def _access_key_matches(value: str) -> bool:
    expected = _normalize_access_key(SHARED_ACCESS_TOKEN)
    return bool(expected) and secrets.compare_digest(
        _normalize_access_key(value).encode("utf-8"), expected.encode("utf-8")
    )


def _shared_access_cookie_value() -> str:
    """Returns a signed value without exposing the shared access token."""
    return hmac.new(
        SECRET_KEY.encode("utf-8"),
        _normalize_access_key(SHARED_ACCESS_TOKEN).encode("utf-8"),
        hashlib.sha256,
    ).hexdigest()


def _safe_redirect_path(path: str) -> str:
    return path if path.startswith("/") and not path.startswith("//") else "/"


# Desbloqueio vale 1 ano no aparelho: o pessoal nao deveria ter de digitar
# a palavra-chave de novo todo mes.
_ACCESS_COOKIE_MAX_AGE = 60 * 60 * 24 * 365


def _unlocked_redirect(next_path: str) -> RedirectResponse:
    response = RedirectResponse(url=_safe_redirect_path(next_path), status_code=303)
    response.set_cookie(
        key=SHARED_ACCESS_COOKIE,
        value=_shared_access_cookie_value(),
        max_age=_ACCESS_COOKIE_MAX_AGE,
        secure=True,
        httponly=True,
        samesite="lax",
    )
    return response


def _access_page(next_path: str, error: bool = False) -> str:
    safe_next = html.escape(_safe_redirect_path(next_path), quote=True)
    error_html = (
        '<p class="erro">Palavra-chave errada. Confira e tente de novo.</p>'
        if error
        else ""
    )
    return f"""<!doctype html>
<html lang="pt-BR"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Acesso ao Ponto</title><style>
body{{margin:0;min-height:100vh;display:grid;place-items:center;background:#f5f5f5;font-family:Arial,sans-serif;color:#18212b}}
main{{width:min(360px,calc(100% - 48px));background:#fff;padding:32px;border-radius:14px;box-shadow:0 12px 32px #0002}}
h1{{margin:0 0 10px;font-size:24px;color:#8B0000}}p{{margin:0 0 20px;color:#52606d;line-height:1.45;font-size:17px}}
.erro{{color:#b00020;font-weight:bold}}label{{display:block;font-weight:600;margin-bottom:8px;font-size:17px}}
input{{box-sizing:border-box;width:100%;padding:14px;border:2px solid #b8c2cc;border-radius:10px;font-size:20px}}
button{{width:100%;margin-top:16px;padding:16px;border:0;border-radius:10px;background:#8B0000;color:#fff;font-size:19px;font-weight:700;cursor:pointer}}
</style></head><body><main><h1>Ponto VMac</h1><p>Digite a palavra-chave da empresa. Isso so e pedido uma vez neste celular.</p>{error_html}
<form method="post" action="/access/login"><input type="hidden" name="next" value="{safe_next}"><label for="token">Palavra-chave</label><input id="token" name="token" type="text" autocomplete="off" autocapitalize="off" autocorrect="off" spellcheck="false" autofocus required><button type="submit">Entrar</button></form>
</main></body></html>"""


@app.get("/access/unlock", response_class=HTMLResponse)
async def access_unlock_form(next: str = "/", k: str = ""):
    # Link pronto (WhatsApp / QR Code): /access/unlock?k=<palavra-chave>
    # libera o aparelho sem digitar nada.
    if k and _access_key_matches(k):
        return _unlocked_redirect(next)
    return HTMLResponse(_access_page(next, error=bool(k)))


@app.post("/access/login")
async def access_unlock(token: str = Form(...), next: str = Form("/")):
    if not _access_key_matches(token):
        return HTMLResponse(_access_page(next, error=True), status_code=401)
    return _unlocked_redirect(next)


@app.get("/access/check")
async def access_check(request: Request):
    is_authorized = SHARED_ACCESS_TOKEN and secrets.compare_digest(
        request.cookies.get(SHARED_ACCESS_COOKIE, ""),
        _shared_access_cookie_value(),
    )
    return Response(status_code=204 if is_authorized else 401)

# CORS
app.add_middleware(
    CORSMiddleware,
    allow_origins=ALLOWED_ORIGINS,
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# --- AUXILIARES DE CÁLCULO (Lógica Ponto.py) ---

def minutes_between_str(s1: str, s2: str) -> int:
    try:
        t1 = datetime.strptime(s1, "%H:%M")
        t2 = datetime.strptime(s2, "%H:%M")
        diff = (t2 - t1).total_seconds() / 60
        if diff < 0: diff += 1440 # Virada de dia
        return int(diff)
    except: return 0

def classify_day_minutes(check_in: str, check_out: str, b_start: str = None, b_end: str = None) -> dict:
    total = minutes_between_str(check_in, check_out)
    if b_start and b_end:
        total -= minutes_between_str(b_start, b_end)

    total = max(0, total)
    res = {"normal": 0, "extras": 0, "extra_50": 0, "extra_100": 0}

    if total <= 360:
        res["normal"] = total
    else:
        res["normal"] = 360
        res["extras"] = total - 360

    return res

def split_hours_and_rem(total_min: int):
    return total_min // 60, total_min % 60

# --- GERAÇÃO AUTOMÁTICA (DO 0) ---

class ExportRecord(BaseModel):
    date: str
    check_in: Optional[str] = None
    check_out: Optional[str] = None
    break_start: Optional[str] = None
    break_end: Optional[str] = None
    entry_3: Optional[str] = None
    exit_3: Optional[str] = None
    total_hours: Optional[float] = None
    regular_hours: Optional[float] = None
    overtime_hours: Optional[float] = None
    extra_50: Optional[float] = None
    extra_100: Optional[float] = None
    # Data (yyyy-mm-dd) em que o primeiro par comeca de verdade, mandada pelo
    # app (computeWorkDay). A entrada 23:50 arredonda para 00:00 do dia
    # seguinte, mas a linha continua na data da entrada.
    start_date: Optional[str] = None

class EstagRules(BaseModel):
    saturday_50: bool = True
    sunday_100: bool = True
    night_100: bool = True

def _record_start_day(record: ExportRecord, record_date: date) -> date:
    """Dia em que o primeiro par comeca: o start_date do app, se for o dia da
    linha ou o seguinte; senao a data da linha. So pelo "00:00" a entrada 23:50
    arredondada nao se distingue de uma entrada real 00:05 do proprio dia."""
    try:
        start = date.fromisoformat((record.start_date or "")[:10])
    except ValueError:
        return record_date
    if record_date <= start <= record_date + timedelta(days=1):
        return start
    return record_date

def record_segments(record: ExportRecord, record_date: date) -> List[tuple]:
    """Os 3 pares de colunas como intervalos (inicio, fim) de verdade, a partir
    do dia do primeiro par (_record_start_day): o par que passa da meia-noite
    termina no dia seguinte, e o par que comeca antes do fim do anterior
    (00:00-03:00 depois de 21:00-23:00) ja e do dia seguinte. Mesmos minutos de
    session_minutes."""
    segments = []
    cursor = datetime.combine(_record_start_day(record, record_date), time.min)
    for ini, fim in (
        (record.check_in, record.check_out),
        (record.break_start, record.break_end),
        (record.entry_3, record.exit_3),
    ):
        if not (ini and fim):
            continue
        try:
            ini_time = datetime.strptime(ini, "%H:%M").time()
            fim_time = datetime.strptime(fim, "%H:%M").time()
        except ValueError:
            continue
        start = datetime.combine(cursor.date(), ini_time)
        if start < cursor:
            start += timedelta(days=1)
        end = datetime.combine(start.date(), fim_time)
        if end < start:
            end += timedelta(days=1)
        segments.append((start, end))
        cursor = end
    return segments

def session_minutes(record: ExportRecord) -> int:
    """Soma os minutos trabalhados nos 3 pares de colunas (C-D / E-F / G-H).
    As refeicoes sao os intervalos entre as sessoes, entao ja ficam descontadas."""
    total = 0
    for ini, fim in (
        (record.check_in, record.check_out),
        (record.break_start, record.break_end),
        (record.entry_3, record.exit_3),
    ):
        if ini and fim:
            total += minutes_between_str(ini, fim)
    return total

def split_normal_extra(total_min: int) -> dict:
    total_min = max(0, total_min)
    if total_min <= 360:
        return {"normal": total_min, "extras": 0}
    return {"normal": 360, "extras": total_min - 360}

def classify_estag_payroll(record: ExportRecord, record_date: date, holiday_days: set, rules: Optional[EstagRules]) -> dict:
    """Minutos do estagiario por tipo. Cada minuto vale pelo PROPRIO dia, como
    no app (computeWorkDay): pela data da linha, a madrugada de domingo do
    turno de sabado 19:30-07:00 ia a 50% e o app mostrava 100%.
      - domingo ou feriado: 100% (sem sunday_100, conta como dia comum, sem
        separar o noturno)
      - noturno 22h-05h: 100% (night_100)
      - sabado: 50% (saturday_50)
      - o resto: normal ate 6h no dia, depois extras
    holiday_days aceita o dia do mes (12) ou a data ISO ("2026-10-12")."""
    rules = rules or EstagRules()
    result = {"normal": 0, "extras": 0, "50": 0, "100": 0}
    common = 0
    for start, end in record_segments(record, record_date):
        current = start
        while current < end:
            day = current.date()
            is_holiday = day.day in holiday_days or day.isoformat() in holiday_days
            if day.weekday() == 6 or is_holiday:
                if rules.sunday_100:
                    result["100"] += 1
                else:
                    common += 1
            elif rules.night_100 and (current.hour >= 22 or current.hour < 5):
                result["100"] += 1
            elif day.weekday() == 5 and rules.saturday_50:
                result["50"] += 1
            else:
                common += 1
            current += timedelta(minutes=1)
    mins = split_normal_extra(common)
    result["normal"] = mins["normal"]
    result["extras"] = mins["extras"]
    return result

def generate_scratch_records(year: int, month: int, total_hours: float, days: Optional[List[date]] = None) -> List[ExportRecord]:
    total_min = int(total_hours * 60)
    dias_uteis = []
    if days is not None:
        candidate = list(days)
    else:
        num_days = monthrange(year, month)[1]
        candidate = [date(year, month, d) for d in range(1, num_days + 1)]
    for dt in candidate:
        if dt.weekday() != 6: dias_uteis.append(dt)

    if not dias_uteis: return []

    dist = [480 for _ in dias_uteis]
    rest = total_min - sum(dist)
    indices = list(range(len(dias_uteis)))
    random.shuffle(indices)
    for i in indices:
        if rest <= 0: break
        add = min(60, rest); dist[i] += add; rest -= add

    recs = []
    for dt, m in zip(dias_uteis, dist):
        ini = random.choice(["08:00", "08:30"])
        ini_dt = datetime.combine(dt, datetime.strptime(ini, "%H:%M").time())
        s1 = ini_dt + timedelta(minutes=240)
        e2 = s1 + timedelta(minutes=random.choice([60, 75]))
        s2 = e2 + timedelta(minutes=(m - 240))
        recs.append(ExportRecord(
            date=dt.isoformat(),
            check_in=ini,
            check_out=s1.strftime("%H:%M"),
            break_start=e2.strftime("%H:%M"),
            break_end=s2.strftime("%H:%M")
        ))
    return recs

# Carga do dia padrao da diaria quando o cadastro nao tem uma valida.
DAILY_MODE_DEFAULT_HOURS = 8.0

def _daily_standard_seed(name: str, day: date) -> int:
    """Numero que escolhe a entrada e o almoco do dia padrao, tirado do nome
    e da data. A mesma conta de _standardSeed (frontend/lib/utils/
    daily_entries.dart): a Dash mostra o horario da folha exportada."""
    value = 0
    for byte in f"{name}|{day.isoformat()}".encode("utf-8"):
        value = (value * 31 + byte) % 1000003
    return value

def daily_standard_sessions(name: str, day: date, daily_hours: Optional[float]) -> List[tuple]:
    """Sessoes (entrada, saida) do dia padrao de uma diaria: entrada 08:00 ou
    08:30, 4h de manha, almoco de 1h ou 1h15 e o resto da carga diaria a
    tarde (8h sem carga valida no cadastro). Mesma regra de
    dailyStandardSessions (frontend/lib/utils/daily_entries.dart)."""
    hours = daily_hours or 0
    if not 0 < hours <= 16:
        hours = DAILY_MODE_DEFAULT_HOURS
    total = int(round(hours * 60))
    seed = _daily_standard_seed(name, day)
    start = datetime.combine(day, time(8, 30 if seed % 2 else 0))
    if total <= 240:
        return [(start, start + timedelta(minutes=total))]
    lunch = start + timedelta(minutes=240)
    back = lunch + timedelta(minutes=75 if (seed // 2) % 2 else 60)
    return [(start, lunch), (back, back + timedelta(minutes=total - 240))]

def daily_mode_records(data: "ExportData") -> List[ExportRecord]:
    """Folha de quem esta no modo diaria: o dia padrao (daily_standard_sessions)
    em cada dia com diaria do periodo, domingo inclusive. Exportar de novo
    (Excel ou HTML) da os mesmos horarios, e a Dash do app mostra os mesmos."""
    period = set(export_period_dates(data))
    days = set()
    for raw in data.daily_dates or []:
        try:
            day = date.fromisoformat(str(raw)[:10])
        except ValueError:
            continue
        if day in period:
            days.add(day)

    records = []
    for day in sorted(days):
        sessions = daily_standard_sessions(data.employee_name, day, data.daily_hours)
        columns = {}
        for (start_key, end_key), (start, end) in zip(
            (("check_in", "check_out"), ("break_start", "break_end")), sessions
        ):
            columns[start_key] = start.strftime("%H:%M")
            columns[end_key] = end.strftime("%H:%M")
        records.append(ExportRecord(date=day.isoformat(), **columns))
    return records

# --- MODELS PARA API ---

class ExportData(BaseModel):
    employee_name: str
    employee_role: str
    month: str
    year: str
    is_campo: bool
    daily_records: List[ExportRecord]
    custom_role: Optional[str] = None
    custom_department: Optional[str] = None
    custom_work_hours: Optional[str] = None
    generate_from_scratch: Optional[bool] = False
    target_hours: Optional[float] = 210.0
    holidays: Optional[List[int]] = None
    estag_rules: Optional[EstagRules] = None
    period_start: Optional[str] = None
    period_end: Optional[str] = None
    period_label: Optional[str] = None
    # Modo diaria: os dias (yyyy-mm-dd) com diaria no periodo. A folha leva um
    # dia padrao de daily_hours em cada um (daily_mode_records) e o arquivo
    # ganha a aba "Diárias".
    daily_mode: Optional[bool] = False
    daily_dates: Optional[List[str]] = None
    daily_hours: Optional[float] = None

def export_period_dates(data: ExportData) -> List[date]:
    if data.period_start and data.period_end:
        start = datetime.fromisoformat(data.period_start[:10]).date()
        end = datetime.fromisoformat(data.period_end[:10]).date()
    else:
        year = int(data.year)
        month = int(data.month)
        start = date(year, month, 1)
        end = date(year, month, monthrange(year, month)[1])

    if end < start:
        raise ValueError("Periodo de fechamento invalido.")

    dates = []
    current = start
    while current <= end:
        dates.append(current)
        current += timedelta(days=1)
    return dates

def export_period_label(data: ExportData) -> str:
    if data.period_label:
        return data.period_label
    dates = export_period_dates(data)
    if not dates:
        return f"{data.month}/{data.year}"
    if len(dates) == monthrange(int(data.year), int(data.month))[1] and dates[0].day == 1:
        return f"{MONTH_NAMES.get(int(data.month), data.month)}/{data.year}"
    return f"{dates[0].strftime('%d/%m/%Y')} a {dates[-1].strftime('%d/%m/%Y')}"

_FIXED_NATIONAL_HOLIDAYS = {
    (1, 1), (4, 21), (5, 1), (9, 7), (10, 12), (11, 2), (11, 15), (12, 25),
}

def _good_friday(year: int) -> date:
    """Sexta-feira Santa: Pascoa (Meeus/Jones/Butcher) menos 2 dias."""
    a = year % 19
    b, c = divmod(year, 100)
    d, e = divmod(b, 4)
    f = (b + 8) // 25
    g = (b - f + 1) // 3
    h = (19 * a + b - d - g + 15) % 30
    i, k = divmod(c, 4)
    l = (32 + 2 * e + 2 * i - h - k) % 7
    m = (a + 11 * h + 22 * l) // 451
    month, day = divmod(h + l - 7 * m + 114, 31)
    return date(year, month, day + 1) - timedelta(days=2)

def is_national_holiday(day: date) -> bool:
    """Feriado nacional, a mesma regra de isHoliday (frontend/lib/utils/
    timesheet.dart): datas fixas, Consciencia Negra (20/11) desde 2024 e
    Sexta-feira Santa."""
    if (day.month, day.day) in _FIXED_NATIONAL_HOLIDAYS:
        return True
    if day.year >= 2024 and (day.month, day.day) == (11, 20):
        return True
    return day == _good_friday(day.year)

def holiday_date_keys(data: ExportData) -> set:
    # O app manda o feriado como dia do mes (15 = dia 15). Ler o numero tambem
    # como posicao no periodo marcava um segundo dia errado no fechamento
    # 29..28 (o "15" virava 15/10 e tambem 13/10, o 15o dia do periodo).
    days = set(data.holidays or [])
    period = export_period_dates(data)
    keys = {current.isoformat() for current in period if current.day in days}
    # O dia seguinte ao fim do periodo nao pode ser digitado (o "1" do
    # fechamento de dezembro e 01/12), mas a madrugada do turno do ultimo dia
    # cai nele: vale o calendario nacional, como no app. Sem isso a noite de
    # 31/12 pagava 05-07 de 01/01 como dia comum.
    if period:
        after = period[-1] + timedelta(days=1)
        if is_national_holiday(after):
            keys.add(after.isoformat())
    return keys

class DeleteUserRequest(BaseModel):
    user_id: str

class AdminUserUpdateRequest(BaseModel):
    name: str
    email: str
    role: str
    job_title: str
    daily_hours: float
    cpf: str
    disabled: bool = False
    new_password: Optional[str] = None
    # Gera uma senha temporaria (devolvida na resposta) em vez de new_password.
    reset_password: bool = False
    work_schedule_override_enabled: bool = False
    work_schedule_override: Optional[Dict[str, str]] = None
    # None (app antigo, sem o campo) mantem o modo diaria como esta.
    daily_mode: Optional[bool] = None

class WorkScheduleConfigRequest(BaseModel):
    shift_start: str = "13:30"
    shift_end: str = "19:30"
    start_allowed_from: str = "13:25"
    start_allowed_until: str = "19:25"
    overtime_prompt_after: str = "19:35"
    timezone: str = "America/Sao_Paulo"

class SchedulePunchRequest(BaseModel):
    record_type: str
    timestamp: Optional[str] = None
    location: Optional[str] = None
    notes: Optional[str] = None
    latitude: Optional[float] = None
    longitude: Optional[float] = None
    close_at_scheduled_end: bool = False
    # Id gerado no aparelho: vira o id do documento e torna o reenvio
    # idempotente (a fila offline reenvia a mesma batida ate ter resposta).
    client_record_id: Optional[str] = None
    # Batida feita sem internet e sincronizada depois (hora do aparelho).
    offline: bool = False

class ScheduleApprovalCreateRequest(BaseModel):
    request_type: str
    attempted_at: Optional[str] = None
    shift_start_at: Optional[str] = None
    location: Optional[str] = None
    notes: Optional[str] = None
    latitude: Optional[float] = None
    longitude: Optional[float] = None

class ScheduleApprovalDecisionRequest(BaseModel):
    reason: Optional[str] = None

class AdminTimeRecordUpdateRequest(BaseModel):
    new_timestamp: str
    reason: str
    notes: Optional[str] = None

def init_firebase_admin():
    if firebase_admin is None:
        raise HTTPException(
            status_code=500,
            detail="firebase-admin nao esta instalado no backend. Rode: pip install -r requirements.txt",
        )

    if firebase_admin._apps:
        return

    service_account_path = os.getenv("FIREBASE_SERVICE_ACCOUNT_PATH")
    service_account_json = os.getenv("FIREBASE_SERVICE_ACCOUNT_JSON")
    if not (service_account_path or service_account_json
            or os.getenv("GOOGLE_APPLICATION_CREDENTIALS")
            or os.getenv("FIRESTORE_EMULATOR_HOST")):
        # Sem credencial nenhuma o SDK procurava a padrao do Google (servidor de
        # metadados do Google Cloud) e cada requisicao travava ~30 s, com o
        # servidor inteiro parado junto. Recusa na hora.
        raise HTTPException(
            status_code=503,
            detail="Credencial do Firebase Admin nao configurada no servidor "
                   "(FIREBASE_SERVICE_ACCOUNT_PATH ou FIREBASE_SERVICE_ACCOUNT_JSON).",
        )
    project_id = os.getenv("FIREBASE_PROJECT_ID", "")
    options = {"projectId": project_id} if project_id else None
    if service_account_json:
        cred = credentials.Certificate(json.loads(service_account_json))
        firebase_admin.initialize_app(cred, options=options)
    elif service_account_path:
        cred = credentials.Certificate(service_account_path)
        firebase_admin.initialize_app(cred, options=options)
    elif os.getenv("FIRESTORE_EMULATOR_HOST"):
        # Emulador local (testes): nao ha credencial; sem esta anonima o SDK
        # procuraria a padrao do Google e travaria.
        firebase_admin.initialize_app(_EmulatorCredential(), options=options)
    else:
        firebase_admin.initialize_app(options=options)

if credentials is not None:
    class _EmulatorCredential(credentials.Base):
        def get_credential(self):
            from google.auth.credentials import AnonymousCredentials
            return AnonymousCredentials()

def _google_api(host: str, path: str) -> str:
    """URL de uma API do Google, ou do emulador quando ligado (testes):
    FIRESTORE_EMULATOR_HOST e FIREBASE_AUTH_EMULATOR_HOST, as mesmas variaveis
    que o Admin SDK usa."""
    if host == "firestore.googleapis.com" and os.getenv("FIRESTORE_EMULATOR_HOST"):
        return f"http://{os.environ['FIRESTORE_EMULATOR_HOST']}/{path}"
    if host == "identitytoolkit.googleapis.com" and os.getenv("FIREBASE_AUTH_EMULATOR_HOST"):
        return f"http://{os.environ['FIREBASE_AUTH_EMULATOR_HOST']}/identitytoolkit.googleapis.com/{path}"
    return f"https://{host}/{path}"

def get_firestore_admin():
    init_firebase_admin()
    try:
        return firestore.client()
    except Exception as exc:
        if "default credentials" in str(exc).lower():
            raise HTTPException(
                status_code=503,
                detail="Firebase Admin nao configurado; o cliente deve usar o modo autenticado compativel.",
            ) from exc
        raise

DEFAULT_INTERN_WORK_SCHEDULE = RULES_DEFAULT_INTERN_WORK_SCHEDULE

def _validate_work_schedule(raw: Optional[dict]) -> dict:
    try:
        return validate_work_schedule(raw)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc

def _resolve_effective_work_schedule(db, user_data: dict) -> dict:
    if user_data.get("work_schedule_override_enabled") is True:
        override = user_data.get("work_schedule_override")
        if isinstance(override, dict):
            return _validate_work_schedule(override)

    settings_doc = db.collection("work_schedule_settings").document("intern_default").get()
    settings = settings_doc.to_dict() if settings_doc.exists else None
    return _validate_work_schedule(settings)

def _parse_schedule_datetime(value: Optional[str], timezone_name: str) -> datetime:
    if not value:
        return datetime.now(ZoneInfo(timezone_name))
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError as exc:
        raise HTTPException(status_code=400, detail="Data/hora invalida.") from exc
    timezone = ZoneInfo(timezone_name)
    if parsed.tzinfo is None:
        return parsed.replace(tzinfo=timezone)
    return parsed.astimezone(timezone)

def _local_iso(dt: datetime) -> str:
    """Hora de parede local, sem offset, para gravar em time_records.

    O app agrupa e exibe pontos em hora local; guardar sem tzinfo mantem o
    banco num unico formato (ingenuo-local) e evita o desalinhamento de fuso.
    `dt` deve estar no fuso local (vindo de _parse_schedule_datetime).
    """
    if dt.tzinfo is not None:
        dt = dt.replace(tzinfo=None)
    return dt.isoformat()

_LOCAL_TZ = "America/Sao_Paulo"

def _local_now() -> datetime:
    """Agora em hora de parede de Brasilia, sem tzinfo.

    O container roda em UTC: datetime.now() puro sai 3h adiantado e, entre
    21h e meia-noite, ja cai no dia seguinte. Use para janelas por dia e para
    hora exibida; carimbos de auditoria seguem em utcnow() + "Z".
    """
    return datetime.now(ZoneInfo(_LOCAL_TZ)).replace(tzinfo=None)

def _time_on_day(day: date, hhmm: str, timezone_name: str) -> datetime:
    return time_on_day(day, hhmm, timezone_name)

def _is_start_within_schedule(attempted: datetime, schedule: dict) -> bool:
    return is_start_within_schedule(attempted, schedule)

def _is_intern_profile(user_data: dict) -> bool:
    role = str(user_data.get("role") or "").lower()
    job_title = str(user_data.get("job_title") or "").lower()
    return "intern" in role or "estag" in role or "estag" in job_title

def _approval_dict(snapshot) -> dict:
    data = snapshot.to_dict() or {}
    for key, value in list(data.items()):
        if isinstance(value, datetime):
            data[key] = value.isoformat()
    return {"id": snapshot.id, **data}

def _user_records_sorted(db, user_id: str, lookback_days: int = 14) -> List[dict]:
    """Pontos recentes do usuario, do mais antigo para o mais novo.

    So o passado recente importa para detectar turno aberto: um check_in sem
    check_out ha mais de duas semanas e dado quebrado, nao turno. Filtrar por
    data no Firestore evita ler o historico inteiro a cada batida - era esse
    volume de leituras que derrubava o endpoint no horario de pico (todo mundo
    batendo junto) e fazia o app cair no fallback e duplicar/errar registro.
    Exige o indice composto user_id + timestamp (firestore.indexes.json).
    """
    collection = db.collection("time_records").where("user_id", "==", user_id)
    if lookback_days > 0:
        # Meia-noite local de hoje menos N dias, a mesma janela do app: os
        # timestamps sao hora local ingenua, entao o corte tambem precisa ser.
        midnight = datetime.combine(_local_now().date(), time.min)
        since = (midnight - timedelta(days=lookback_days)).isoformat()
        try:
            snapshots = list(collection.where("timestamp", ">=", since).stream())
        except Exception as exc:  # indice ausente ou consulta indisponivel
            print(f"[schedule] consulta por data indisponivel, lendo tudo: {exc}")
            snapshots = list(collection.stream())
    else:
        snapshots = list(collection.stream())
    records = [{"id": item.id, **(item.to_dict() or {})} for item in snapshots]
    return _sort_records(records)

# Ordem dos tipos de ponto no MESMO timestamp (o lote do gestor grava sem
# segundos): fim da pausa, saida, entrada e inicio da pausa. A saida antes da
# entrada fecha um turno antes de abrir o seguinte (noite 19:00-07:00 e dia
# 07:00-15:00 no lote); ao contrario, a ordem vinha do id aleatorio e o turno
# aberto mudava. Mesma ordem de compareRecords (frontend/lib/utils/shift_records.dart).
# O ponto do lote no mesmo minuto de uma batida com segundos segue a mesma
# ordem (_sort_records).
_SAME_TIMESTAMP_RANK = {
    "break_end": 0,
    "exit_3": 0,
    "check_out": 1,
    "check_in": 2,
    "break_start": 3,
    "entry_3": 3,
}

_TIMESTAMP_RE = re.compile(r"(\d{4}-\d{2}-\d{2}T\d{2}:\d{2})(?::(\d{2})(?:\.(\d+))?)?(.*)")

def _normalized_timestamp(value) -> str:
    """Timestamp com segundos e a fracao em 6 digitos: "...19:30:00" (este
    backend, isoformat sem microssegundos) e "...19:30:00.000" (app e lote)
    sao o mesmo instante. Comparando o texto cru, o mais curto vinha antes e o
    desempate pelo tipo nunca rodava: o fim da pausa do lote igual a saida do
    FECHAR PONTO caia depois dela e sumia. Mesma regra de _normalizedTimestamp
    (frontend/lib/utils/shift_records.dart)."""
    raw = str(value or "")
    match = _TIMESTAMP_RE.fullmatch(raw)
    if match is None:
        return raw
    fraction = (match.group(3) or "").ljust(6, "0")[:6]
    return f"{match.group(1)}:{match.group(2) or '00'}.{fraction}{match.group(4)}"

def _record_sort_key(record: dict) -> tuple:
    """Chave cronologica de um ponto: o instante (_normalized_timestamp), se
    vai logo depois de outro ponto do mesmo minuto (o do lote, em
    _sort_records), o tipo (_SAME_TIMESTAMP_RANK) e o id."""
    return (
        _normalized_timestamp(record.get("timestamp")),
        False,
        _SAME_TIMESTAMP_RANK.get(record.get("record_type"), len(_SAME_TIMESTAMP_RANK)),
        str(record.get("id") or ""),
    )

def _is_whole_minute_batch(record: dict, key: tuple) -> bool:
    """Ponto do lote novo num minuto cheio (o lote grava HH:mm:00.000)."""
    return record.get("batch_real_dates") is True and key[0][16:26] == ":00.000000"

def _sort_records(records: List[dict]) -> List[dict]:
    """Ordena records no lugar, em ordem cronologica, e devolve a lista.

    O lote do gestor grava so hora e minuto; a batida do app e a deste
    backend tem segundos. O ponto do lote vale pelo minuto inteiro: vai logo
    depois da ultima batida do mesmo usuario no mesmo minuto com tipo antes do
    dele (_SAME_TIMESTAMP_RANK) e, sem nenhuma, no comeco do minuto. Pelo
    horario cru, a Entrada 07:00 do lote vinha antes da Saida 07:00:14 da noite
    anterior: a saida virava o "Esqueci" do dia, a noite perdia as horas e o
    turno do dia nao aparecia aberto ("Nao existe turno aberto"). A Saida
    07:00 do lote fica depois da Pausa fim 07:00:20 do app e antes da Entrada
    07:00:20 do turno seguinte. Entre pontos do lote, e entre batidas do app,
    nada muda. Mesma regra de chronologicalOrder
    (frontend/lib/utils/shift_records.dart)."""
    own = [_record_sort_key(record) for record in records]

    def minute_of(index: int) -> tuple:
        return (str(records[index].get("user_id") or ""), own[index][0][:16])

    punches_by_minute: Dict[tuple, List[int]] = {}
    for index, record in enumerate(records):
        if not _is_whole_minute_batch(record, own[index]):
            punches_by_minute.setdefault(minute_of(index), []).append(index)
    keys = []
    for index, record in enumerate(records):
        key = own[index]
        if _is_whole_minute_batch(record, key):
            lower = [own[j] for j in punches_by_minute.get(minute_of(index), []) if own[j][2] < key[2]]
            if lower:
                key = (max(lower)[0], True, key[2], key[3])
        keys.append((key, index))
    order = sorted(range(len(records)), key=lambda index: keys[index])
    records[:] = [records[index] for index in order]
    return records

# Id da batida em _records_before_punch: depois de qualquer id do Firestore.
_AFTER_EVERY_ID = "\U0010ffff"

def _records_before_punch(records: List[dict], punch: dict) -> List[dict]:
    """Pontos de records (de um usuario) que vem antes da batida punch
    (user_id, record_type e timestamp), em ordem (_sort_records): o turno
    aberto no momento da batida offline, que chega depois. Pelo texto do
    horario, a Entrada 07:00 do lote do turno do dia ficava antes da Saida
    07:00:14 da noite batida offline, e a saida fechava o turno do dia. Os
    pontos do mesmo horario e tipo da batida contam (pode ser ela mesma, ja
    gravada). Mesma regra de recordsBeforePunch
    (frontend/lib/utils/shift_records.dart)."""
    probe = {**punch, "id": _AFTER_EVERY_ID}
    ordered = _sort_records([*records, probe])
    position = next(index for index, item in enumerate(ordered) if item is probe)
    return ordered[:position]

# Maior distancia entre a entrada e a saida de um turno (maxShiftSpan do app).
_MAX_SHIFT_SPAN = timedelta(hours=16)

def _is_legacy_batch(record: dict) -> bool:
    """Ponto do lote ANTIGO do gestor: lancado para outra pessoa
    (created_by_admin) sem batch_real_dates. Esse lote gravava todos os
    horarios na data escolhida (a saida 07:00 da noite ficava antes da
    entrada 19:30, no mesmo dia). O lote novo grava a data real e marca
    batch_real_dates: vale pelo horario, como a batida do app. Mesma regra de
    isLegacyBatchRecord (frontend/lib/utils/shift_records.dart)."""
    return record.get("created_by_admin") is True and record.get("batch_real_dates") is not True

def _manual_night_exit_index(records: List[dict], index: int) -> Optional[int]:
    """Turno da noite lancado no lote ANTIGO do gestor (_is_legacy_batch): o
    lote antigo gravava todos os horarios na data escolhida, entao a saida
    07:00 fica ANTES da entrada 19:30, no mesmo dia, e o turno ja vem fechado.
    E a ultima entrada do dia, do lote antigo, sem saida depois dela, e com
    uma saida do lote antigo antes da PRIMEIRA entrada do dia (as saidas
    depois dela fecham os turnos do proprio dia, como o 08-17 da dobra). Com
    mais de uma, vale a mais perto da entrada. Pontos do app e do lote novo
    (data real) nunca entram aqui.
    Sem nenhuma, vale a saida do lote antigo depois da primeira entrada que
    outra saida substitui antes da proxima entrada (a mais perto da noite):
    na dobra 06:50-16:00 e 19:00-07:00 a saida 07:00 cai depois da entrada
    06:50, e o turno do dia ja a ignora (vale a ultima saida).
    A noite vai no maximo _MAX_SHIFT_SPAN da entrada ate a saida do dia
    seguinte: a entrada 08:00 do gestor no dia da saida 07:00 que corrige o
    "Esqueci" da vespera nao e uma noite de 23h, e sim o turno do dia, aberto.
    Devolve o indice dessa saida em records (cronologico), ou None.

    Mesma regra de manualNightExitIndex (frontend/lib/utils/shift_records.dart):
    sem ela aqui, o app mostrava o turno fechado e liberava a entrada, e este
    endpoint recusava com "Ja existe um turno aberto" por 14 dias."""
    entry = records[index]
    if entry.get("record_type") != "check_in" or not _is_legacy_batch(entry):
        return None
    day = str(entry.get("timestamp") or "")[:10]
    for later in records[index + 1:]:
        if str(later.get("timestamp") or "")[:10] != day:
            break
        if later.get("record_type") in ("check_in", "check_out"):
            return None
    entry_at = _to_local_naive(str(entry.get("timestamp") or ""))

    def fits_night(exit_index: int) -> bool:
        exit_at = _to_local_naive(str(records[exit_index].get("timestamp") or ""))
        return (
            entry_at is not None
            and exit_at is not None
            and exit_at + timedelta(days=1) - entry_at <= _MAX_SHIFT_SPAN
        )

    def legacy_check_out(record: dict) -> bool:
        return record.get("record_type") == "check_out" and _is_legacy_batch(record)

    def superseded(exit_index: int) -> bool:
        for later in records[exit_index + 1:]:
            if later.get("record_type") == "check_in":
                return False
            if later.get("record_type") == "check_out":
                return True
        return False

    first_check_in = index
    for j in range(index - 1, -1, -1):
        if str(records[j].get("timestamp") or "")[:10] != day:
            break
        if records[j].get("record_type") == "check_in":
            first_check_in = j
    for j in range(first_check_in - 1, -1, -1):
        earlier = records[j]
        if str(earlier.get("timestamp") or "")[:10] != day:
            break
        if legacy_check_out(earlier):
            if fits_night(j):
                return j
            break
    for j in range(index - 1, first_check_in, -1):
        if legacy_check_out(records[j]) and superseded(j):
            return j if fits_night(j) else None
    return None

def _open_shift_start(records: List[dict]) -> Optional[dict]:
    """Entrada do turno ainda aberto (a ultima sem saida depois dela), ou None.
    A noite do lote antigo do gestor ja vem fechada (_manual_night_exit_index);
    a do lote novo fecha pela saida gravada no dia seguinte, como no app."""
    last_check_in = None
    for index, record in enumerate(records):
        record_type = record.get("record_type")
        if record_type == "check_in":
            closed = _manual_night_exit_index(records, index) is not None
            last_check_in = None if closed else record
        elif record_type == "check_out":
            last_check_in = None
    return last_check_in

def _reusable_approval_check_in(
    records: List[dict],
    request_id: str,
    request: dict,
    open_shift: Optional[dict],
) -> Optional[dict]:
    """check_in ja gravado que atende este pedido de entrada, se houver.

    Primeiro o do proprio pedido: uma tentativa anterior gravou o ponto e caiu
    antes de marcar a decisao. Depois o de OUTRO pedido do mesmo dia, mas so
    se for o mesmo turno - ainda aberto, ou este pedido foi feito antes da
    saida dele (pedido duplicado de um turno ja trabalhado). Pedido feito
    depois daquela saida e uma nova entrada e precisa do proprio ponto.
    """
    for item in records:
        if item.get("record_type") == "check_in" and item.get("schedule_approval_request_id") == request_id:
            return item

    attempted = _to_local_naive(request.get("attempted_at"))
    for idx, item in enumerate(records):
        if item.get("record_type") != "check_in" or not item.get("schedule_approval_request_id"):
            continue
        if str(item.get("timestamp") or "")[:10] != request.get("day_key"):
            continue
        if open_shift is not None and item.get("id") == open_shift.get("id"):
            return item
        following = next(
            (later for later in records[idx + 1:] if later.get("record_type") in ("check_in", "check_out")),
            None,
        )
        if following is None or following.get("record_type") != "check_out":
            continue
        ended = _to_local_naive(following.get("timestamp"))
        if attempted is not None and ended is not None and attempted <= ended:
            return item
    return None

# Idade maxima de um pedido de entrada fora do horario para a liberacao
# ainda criar o ponto.
_START_APPROVAL_MAX_AGE = timedelta(hours=12)

def _start_request_expired(attempted: Optional[datetime], now: datetime) -> bool:
    """Pedido de entrada velho demais para virar ponto. Mede a idade, nao a
    data: o pedido das 23:55 liberado as 00:03 ainda e o mesmo turno, mas pela
    data era "de outro dia" e ficava pendente para sempre."""
    return attempted is not None and now - attempted > _START_APPROVAL_MAX_AGE

# Dois pedidos de entrada ate 15 min um do outro (a mesma folga do relogio)
# sao a mesma tentativa repetida; mais longe, e uma entrada nova.
_START_REQUEST_RETRY_WINDOW = timedelta(minutes=15)

def _is_start_request_retry(previous: Optional[datetime], attempted: Optional[datetime]) -> bool:
    """O pedido de entrada feito em [attempted] repete o de [previous]?
    Sem as duas horas, trata como repeticao (comportamento antigo)."""
    if previous is None or attempted is None:
        return True
    return abs(attempted - previous) <= _START_REQUEST_RETRY_WINDOW

def _newer_start_attempt(db, request_id: str, data: dict) -> Optional[dict]:
    """Outro pedido de entrada do mesmo dia feito bem depois deste (fora da
    janela de repeticao). Liberar este abriria o turno na hora antiga, que o
    estagiario ja tinha refeito."""
    attempted = _to_local_naive(data.get("attempted_at"))
    if attempted is None:
        return None
    for item in _find_schedule_requests(
        db, data["user_id"], "start_exception", data.get("day_key") or "",
        {"pending", "approved", "rejected"},
    ):
        if item.id == request_id:
            continue
        other = _to_local_naive((item.to_dict() or {}).get("attempted_at"))
        if other is not None and other > attempted and not _is_start_request_retry(attempted, other):
            return {"id": item.id, **(item.to_dict() or {})}
    return None

def _find_schedule_requests(
    db,
    user_id: str,
    request_type: str,
    day_key: str,
    statuses: Optional[set] = None,
) -> List[Any]:
    """Pedidos do usuario para o tipo/dia, do mais novo para o mais antigo.

    Filtra tipo e dia no Firestore: so pelo usuario, lia todos os pedidos que
    ele ja fez, duas vezes a cada 90 s com a tela do estagiario aberta, e a
    conta so crescia. So igualdades: o Firestore resolve com os indices de
    campo unico, sem indice composto.
    """
    candidates = (
        db.collection("work_schedule_approval_requests")
        .where("user_id", "==", user_id)
        .where("request_type", "==", request_type)
        .where("day_key", "==", day_key)
        .stream()
    )
    matches = []
    for item in candidates:
        data = item.to_dict() or {}
        if data.get("request_type") != request_type or data.get("day_key") != day_key:
            continue
        if statuses is not None and data.get("status") not in statuses:
            continue
        matches.append(item)
    matches.sort(
        key=lambda item: str((item.to_dict() or {}).get("created_at") or ""),
        reverse=True,
    )
    return matches

def _find_schedule_request(
    db,
    user_id: str,
    request_type: str,
    day_key: str,
    statuses: Optional[set] = None,
) -> Optional[Any]:
    matches = _find_schedule_requests(db, user_id, request_type, day_key, statuses)
    return matches[0] if matches else None

def _create_user_notification(
    db,
    user_id: str,
    title: str,
    body: str,
    notification_type: str,
    request_id: str,
):
    db.collection("user_notifications").document().set({
        "user_id": user_id,
        "title": title,
        "body": body,
        "type": notification_type,
        "request_id": request_id,
        "is_read": False,
        "created_at": firestore.SERVER_TIMESTAMP,
    })

def _send_user_push(user_id: str, title: str, body: str, data: Optional[dict] = None):
    if messaging is None:
        return
    try:
        db = get_firestore_admin()
        user_ref = db.collection("users").document(user_id)
        user_doc = user_ref.get()
        user_data = user_doc.to_dict() or {} if user_doc.exists else {}
        tokens = [token for token in user_data.get("fcm_tokens", []) if isinstance(token, str) and token]
        if not tokens:
            return
        response = messaging.send_each_for_multicast(messaging.MulticastMessage(
            tokens=tokens,
            notification=messaging.Notification(title=title, body=body),
            data={key: str(value) for key, value in (data or {}).items()},
            android=messaging.AndroidConfig(
                priority="high",
                notification=messaging.AndroidNotification(
                    channel_id="work_schedule_approvals",
                    icon="notification_icon",
                    color="#8B0000",
                ),
            ),
            apns=messaging.APNSConfig(
                payload=messaging.APNSPayload(aps=messaging.Aps(sound="default"))
            ),
        ))
        invalid = []
        for token, result in zip(tokens, response.responses):
            if result.success or result.exception is None:
                continue
            code = getattr(result.exception, "code", "")
            if code in {"registration-token-not-registered", "invalid-registration-token"}:
                invalid.append(token)
        if invalid:
            user_ref.update({"fcm_tokens": firestore.ArrayRemove(invalid)})
    except Exception as exc:
        logger.warning("Falha ao enviar push de horario: %s", exc)

def send_document_push_notification(user_id: str, title: str, body: str, document_id: str):
    """Envia o push aos aparelhos cadastrados pelo colaborador.

    Falhas de push nao impedem a criacao do documento nem a notificacao interna.
    """
    if messaging is None:
        logger.warning("Push de documento ignorado: firebase-admin indisponivel.")
        return

    try:
        db = get_firestore_admin()
        user_ref = db.collection("users").document(user_id)
        user_doc = user_ref.get()
        user_data = user_doc.to_dict() or {} if user_doc.exists else {}
        tokens = [token for token in user_data.get("fcm_tokens", []) if isinstance(token, str) and token]
        if not tokens:
            logger.info("Push de documento sem aparelho cadastrado para o usuario %s", user_id)
            return

        invalid_tokens = []
        for start in range(0, len(tokens), 500):
            batch_tokens = tokens[start:start + 500]
            message = messaging.MulticastMessage(
                tokens=batch_tokens,
                notification=messaging.Notification(title=title, body=body),
                data={"type": "signature_document", "document_id": document_id},
                android=messaging.AndroidConfig(
                    priority="high",
                    notification=messaging.AndroidNotification(
                        channel_id="signature_documents",
                        icon="notification_icon",
                        color="#8B0000",
                    ),
                ),
                apns=messaging.APNSConfig(
                    payload=messaging.APNSPayload(aps=messaging.Aps(sound="default"))
                ),
            )
            response = messaging.send_each_for_multicast(message)
            for token, item in zip(batch_tokens, response.responses):
                if item.success or item.exception is None:
                    continue
                error_code = getattr(item.exception, "code", "")
                if error_code in {"registration-token-not-registered", "invalid-registration-token"}:
                    invalid_tokens.append(token)

        if invalid_tokens:
            user_ref.update({"fcm_tokens": firestore.ArrayRemove(invalid_tokens)})
    except Exception as exc:
        logger.warning("Falha ao enviar push de documento: %s", exc)

def decode_firestore_value(value: dict):
    if "stringValue" in value:
        return value["stringValue"]
    if "booleanValue" in value:
        return value["booleanValue"]
    if "integerValue" in value:
        return int(value["integerValue"])
    if "doubleValue" in value:
        return float(value["doubleValue"])
    if "timestampValue" in value:
        return value["timestampValue"]
    if "nullValue" in value:
        return None
    if "mapValue" in value:
        fields = value["mapValue"].get("fields", {})
        return {key: decode_firestore_value(item) for key, item in fields.items()}
    if "arrayValue" in value:
        return [
            decode_firestore_value(item)
            for item in value["arrayValue"].get("values", [])
        ]
    return None

# Um cliente HTTP so, reaproveitado: criar um httpx.AsyncClient carrega os
# certificados de novo (~200 ms) e cada um abria conexao TLS nova com o
# Google. Eram dois por requisicao autenticada. Um por event loop: o cliente
# nao pode ser usado num loop diferente do que o criou (os testes rodam cada
# chamada num asyncio.run proprio).
_http_clients: Dict[int, httpx.AsyncClient] = {}

def _http_client() -> httpx.AsyncClient:
    loop_id = id(asyncio.get_running_loop())
    client = _http_clients.get(loop_id)
    if client is None or client.is_closed:
        _http_clients.clear()
        client = _http_clients[loop_id] = httpx.AsyncClient(timeout=20.0)
    return client

# Token ja conferido no Google vale por alguns minutos sem nova consulta: o
# app manda o mesmo token (dura 1h) em todas as chamadas. Desativar ou excluir
# a conta pelo painel tira os tokens dela daqui na hora (_forget_user_tokens).
_TOKEN_CACHE_TTL = timedelta(minutes=5)
_TOKEN_CACHE_MAX = 2000
_verified_tokens: Dict[str, tuple] = {}

def _token_key(id_token: str) -> str:
    return hashlib.sha256(id_token.encode("utf-8")).hexdigest()

def _cached_token_uid(id_token: str) -> Optional[str]:
    hit = _verified_tokens.get(_token_key(id_token))
    if hit and hit[1] > datetime.utcnow():
        return hit[0]
    return None

def _forget_user_tokens(user_uid: str) -> None:
    for key in [k for k, (uid, _) in _verified_tokens.items() if uid == user_uid]:
        del _verified_tokens[key]

def _remember_token(id_token: str, user_uid: str) -> None:
    now = datetime.utcnow()
    if len(_verified_tokens) >= _TOKEN_CACHE_MAX:
        for key in [k for k, (_, exp) in _verified_tokens.items() if exp <= now]:
            del _verified_tokens[key]
        if len(_verified_tokens) >= _TOKEN_CACHE_MAX:
            _verified_tokens.clear()
    _verified_tokens[_token_key(id_token)] = (user_uid, now + _TOKEN_CACHE_TTL)

async def _close_http_clients() -> None:
    for client in list(_http_clients.values()):
        await client.aclose()
    _http_clients.clear()

async def get_firestore_document_with_user_token(
    collection_name: str,
    document_id: str,
    id_token: str,
) -> Optional[dict]:
    project_id = os.getenv("FIREBASE_PROJECT_ID", "")
    if not project_id:
        raise HTTPException(status_code=503, detail="FIREBASE_PROJECT_ID nao configurado.")

    url = _google_api(
        "firestore.googleapis.com",
        f"v1/projects/{project_id}/databases/(default)/documents/{collection_name}/{document_id}",
    )
    response = await _http_client().get(
        url,
        headers={"Authorization": f"Bearer {id_token}"},
    )
    if response.status_code == 404:
        return None
    if response.status_code == 429:
        # Cota do Firestore esgotada nao e falta de permissao. Devolver 403 aqui
        # fazia toda a tela acusar "sem permissao" e escondia a causa real.
        # 429 tambem evita o fallback do app (que so dispara em 404/5xx e
        # bateria na mesma cota estourada).
        raise HTTPException(
            status_code=429,
            detail="Cota diaria do banco de dados esgotada. Tente novamente mais tarde.",
        )
    if response.status_code in (401, 403):
        raise HTTPException(
            status_code=403,
            detail="Nao foi possivel validar as permissoes no Firebase.",
        )
    if response.status_code < 200 or response.status_code >= 300:
        # Firestore fora do ar (5xx) ou resposta inesperada nao e falta de
        # permissao: com 403 o app tratava como recusa da regra e deixava a
        # batida da fila offline parada, em vez de tentar de novo.
        raise HTTPException(
            status_code=503,
            detail="Firebase indisponivel no momento. Tente novamente.",
        )

    fields = response.json().get("fields", {})
    return {key: decode_firestore_value(value) for key, value in fields.items()}

async def verify_firebase_user_token(id_token: str) -> str:
    cached_uid = _cached_token_uid(id_token)
    if cached_uid:
        return cached_uid
    if FIREBASE_WEB_API_KEY:
        try:
            response = await _http_client().post(
                _google_api("identitytoolkit.googleapis.com", "v1/accounts:lookup"),
                params={"key": FIREBASE_WEB_API_KEY},
                json={"idToken": id_token},
            )
        except httpx.RequestError as exc:
            raise HTTPException(status_code=502, detail="Falha ao validar a sessao Firebase.") from exc

        users = response.json().get("users", []) if response.is_success else []
        user_uid = users[0].get("localId") if users else None
        if user_uid:
            _remember_token(id_token, user_uid)
            return user_uid
        raise HTTPException(status_code=401, detail="Token invalido ou expirado.")

    init_firebase_admin()
    try:
        decoded = await asyncio.to_thread(firebase_auth.verify_id_token, id_token)
        user_uid = decoded.get("uid")
    except Exception as exc:
        logger.warning("Firebase token validation failed: %s: %s", type(exc).__name__, exc)
        raise HTTPException(status_code=401, detail="Token invalido ou expirado.")

    if not user_uid:
        raise HTTPException(status_code=401, detail="Usuario nao autenticado.")
    _remember_token(id_token, user_uid)
    return user_uid

async def require_authenticated_user(token: HTTPAuthorizationCredentials = Depends(security)):
    user_uid = await verify_firebase_user_token(token.credentials)

    user_data = await get_firestore_document_with_user_token(
        "users",
        user_uid,
        token.credentials,
    )
    if user_data is None:
        raise HTTPException(status_code=403, detail="Perfil do usuario nao encontrado.")

    return {
        "id": user_uid,
        "_id_token": token.credentials,
        **user_data,
    }

async def require_admin_user(user=Depends(require_authenticated_user)):
    if user.get("role") not in ["admin", "manager"]:
        raise HTTPException(status_code=403, detail="Apenas admin ou manager pode executar esta acao.")
    return user

def _response_safe(data: dict) -> dict:
    """Copia de `data` para devolver na resposta: o SERVER_TIMESTAMP do
    Firestore e um marcador que so o banco preenche e nao vira JSON. Com ele
    na resposta o endpoint gravava o documento e devolvia 500, e o app caia no
    plano B pelo Firestore (o dobro do tempo em toda batida do estagiario)."""
    server_now = datetime.utcnow().isoformat() + "Z"
    return {
        key: server_now if value is firestore.SERVER_TIMESTAMP else value
        for key, value in data.items()
    }

def serialize_firestore_document(document) -> dict:
    data = document.to_dict() or {}
    for key, value in list(data.items()):
        if isinstance(value, datetime):
            data[key] = value.isoformat()
    return {"id": document.id, **data}

def get_zapsign_headers() -> dict:
    if not ZAPSIGN_API_TOKEN or ZAPSIGN_API_TOKEN.startswith("cole-aqui"):
        raise HTTPException(
            status_code=503,
            detail="ZapSign nao configurada. Defina ZAPSIGN_API_TOKEN no backend.",
        )
    return {
        "Authorization": f"Bearer {ZAPSIGN_API_TOKEN}",
        "Content-Type": "application/json",
    }

async def zapsign_request(method: str, path: str, json_data: Optional[dict] = None) -> dict:
    try:
        response = await _http_client().request(
            method,
            f"{ZAPSIGN_API_BASE_URL}/{path.lstrip('/')}",
            headers=get_zapsign_headers(),
            json=json_data,
            timeout=60.0,
        )
    except httpx.RequestError as exc:
        raise HTTPException(status_code=502, detail=f"Falha ao conectar com a ZapSign: {exc}")

    if response.status_code < 200 or response.status_code >= 300:
        try:
            detail = response.json()
        except ValueError:
            detail = response.text
        raise HTTPException(
            status_code=502,
            detail=f"ZapSign recusou a operacao ({response.status_code}): {detail}",
        )

    return response.json()

def zapsign_document_fields(payload: dict) -> dict:
    signers = payload.get("signers") or []
    signer = signers[0] if signers else {}
    signer_token = signer.get("token", "")
    return {
        "zapsign_document_token": payload.get("token", ""),
        "zapsign_signer_token": signer_token,
        "status": payload.get("status", "pending"),
        "signer_status": signer.get("status", "new"),
        "sign_url": f"{ZAPSIGN_APP_URL}/{signer_token}" if signer_token else "",
        "original_file_url": payload.get("original_file") or "",
        "signed_file_url": payload.get("signed_file") or "",
        "signed_at": signer.get("signed_at"),
        "zapsign_last_update_at": payload.get("last_update_at"),
    }

SIGNATURE_DOCUMENT_COLUMNS = """
    id, user_id, user_name, user_email, title, message, original_file_name,
    status, signer_status, zapsign_document_token, zapsign_signer_token,
    sign_url, original_file_url, signed_file_url, signed_at,
    zapsign_last_update_at, error_message, webhook_event,
    created_by_id, created_by_name, created_by_email, created_at, updated_at
"""

def signature_db_connection():
    connection = sqlite3.connect(DATABASE_PATH)
    connection.row_factory = sqlite3.Row
    # WAL + synchronous=FULL: queda de energia no meio de um write deixava o
    # arquivo corrompido. Com WAL o commit vira append no -wal e o FULL forca
    # o fsync antes de confirmar, entao o pior caso e perder a transacao em
    # andamento em vez do banco inteiro.
    connection.execute("PRAGMA journal_mode=WAL")
    connection.execute("PRAGMA synchronous=FULL")
    return connection

def init_signature_documents_table():
    with signature_db_connection() as connection:
        connection.execute("""
            CREATE TABLE IF NOT EXISTS signature_documents (
                id TEXT PRIMARY KEY,
                user_id TEXT NOT NULL,
                user_name TEXT NOT NULL,
                user_email TEXT NOT NULL,
                title TEXT NOT NULL,
                message TEXT NOT NULL DEFAULT '',
                original_file_name TEXT NOT NULL,
                status TEXT NOT NULL DEFAULT 'creating',
                signer_status TEXT NOT NULL DEFAULT '',
                zapsign_document_token TEXT NOT NULL DEFAULT '',
                zapsign_signer_token TEXT NOT NULL DEFAULT '',
                sign_url TEXT NOT NULL DEFAULT '',
                original_file_url TEXT NOT NULL DEFAULT '',
                signed_file_url TEXT NOT NULL DEFAULT '',
                signed_at TEXT,
                zapsign_last_update_at TEXT,
                error_message TEXT NOT NULL DEFAULT '',
                webhook_event TEXT NOT NULL DEFAULT '',
                created_by_id TEXT NOT NULL,
                created_by_name TEXT NOT NULL DEFAULT '',
                created_by_email TEXT NOT NULL DEFAULT '',
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL
            )
        """)
        connection.execute("""
            CREATE TABLE IF NOT EXISTS signature_notifications (
                id TEXT PRIMARY KEY,
                user_id TEXT NOT NULL,
                title TEXT NOT NULL,
                body TEXT NOT NULL,
                document_id TEXT NOT NULL DEFAULT '',
                is_read INTEGER NOT NULL DEFAULT 0,
                created_at TEXT NOT NULL
            )
        """)

def get_signature_document(document_id: str) -> Optional[dict]:
    with signature_db_connection() as connection:
        row = connection.execute(
            f"SELECT {SIGNATURE_DOCUMENT_COLUMNS} FROM signature_documents WHERE id = ?",
            (document_id,),
        ).fetchone()
    return dict(row) if row else None

def update_signature_document(document_id: str, fields: dict):
    allowed_fields = {
        "status", "signer_status", "zapsign_document_token",
        "zapsign_signer_token", "sign_url", "original_file_url",
        "signed_file_url", "signed_at", "zapsign_last_update_at",
        "error_message", "webhook_event", "updated_at",
    }
    values = {key: value for key, value in fields.items() if key in allowed_fields}
    if not values:
        return
    assignments = ", ".join(f"{key} = ?" for key in values)
    with signature_db_connection() as connection:
        connection.execute(
            f"UPDATE signature_documents SET {assignments} WHERE id = ?",
            (*values.values(), document_id),
        )

def find_signature_document_id(document_token: str) -> Optional[str]:
    with signature_db_connection() as connection:
        row = connection.execute(
            "SELECT id FROM signature_documents WHERE zapsign_document_token = ? LIMIT 1",
            (document_token,),
        ).fetchone()
    return row["id"] if row else None

def create_signature_notification(user_id: str, title: str, body: str, document_id: str):
    if not user_id:
        return
    with signature_db_connection() as connection:
        connection.execute(
            """
            INSERT INTO signature_notifications (id, user_id, title, body, document_id, created_at)
            VALUES (?, ?, ?, ?, ?, ?)
            """,
            (
                secrets.token_urlsafe(16), user_id, title, body, document_id,
                datetime.utcnow().isoformat() + "Z",
            ),
        )

def create_signed_notification_if_needed(document: dict, previous_status: str, current_status: str):
    if previous_status == "signed" or current_status != "signed":
        return
    create_signature_notification(
        document.get("created_by_id", ""),
        "Documento assinado",
        f"{document.get('user_name', 'O colaborador')} assinou \"{document.get('title', 'o documento')}\".",
        document.get("id", ""),
    )

# --- JOB: fechamento automatico de pausa (paridade com a regra do app) ---
# Garante o fechamento mesmo com o app/site fechado, o que a regra do cliente
# (que so roda com a tela aberta) nao cobre.

_AUTO_CLOSE_TZ = "America/Sao_Paulo"
_AUTO_CLOSE_INTERVAL_SECONDS = 900        # varre a cada 15 min
_AUTO_CLOSE_AFTER = timedelta(hours=3)    # pausa aberta ha 3h
_AUTO_CLOSE_DURATION = timedelta(hours=1)  # fecha 1h apos o inicio
_AUTO_CLOSE_MAX_AGE = timedelta(days=2)   # ignora pausas antigas demais
# So le registros recentes: no plano Spark ler o historico inteiro a cada
# rodada estoura a cota diaria de leituras (foi o que derrubou a auth).
_AUTO_CLOSE_WINDOW = timedelta(hours=10)

def _to_local_naive(value: Optional[str]) -> Optional[datetime]:
    if not value:
        return None
    try:
        return _parse_schedule_datetime(value, _AUTO_CLOSE_TZ).replace(tzinfo=None)
    except Exception:
        return None

def _run_auto_close_breaks(window: timedelta = _AUTO_CLOSE_WINDOW) -> bool:
    """Fecha as pausas vencidas. Devolve False se nao conseguiu consultar."""
    try:
        db = get_firestore_admin()
    except Exception:
        return False  # Firestore indisponivel; tenta na proxima rodada

    now = datetime.now(ZoneInfo(_AUTO_CLOSE_TZ)).replace(tzinfo=None)
    window_start = (now - window).isoformat()
    try:
        # Consulta de campo unico (indice automatico, sem indice composto):
        # so os registros recentes de todos os usuarios de uma vez.
        recent = list(
            db.collection("time_records")
            .where("timestamp", ">=", window_start)
            .stream()
        )
    except Exception as exc:
        print(f"[auto-close] falha na consulta: {exc}")
        return False

    by_user: Dict[str, List[dict]] = {}
    for doc in recent:
        data = doc.to_dict() or {}
        uid = data.get("user_id")
        if uid:
            by_user.setdefault(uid, []).append({"id": doc.id, **data})

    for uid, records in by_user.items():
        _sort_records(records)
        # O ultimo registro na janela e o ultimo do usuario (a janela e o
        # trecho mais recente); se o cliente ja fechou, aparece aqui.
        last = records[-1]
        ltype = last.get("record_type")
        if ltype not in ("break_start", "entry_3"):
            continue
        start = _to_local_naive(last.get("timestamp"))
        if start is None:
            continue
        age = now - start
        if age < _AUTO_CLOSE_AFTER or age > _AUTO_CLOSE_MAX_AGE:
            continue

        close_type = "break_end" if ltype == "break_start" else "exit_3"
        close_at = start + _AUTO_CLOSE_DURATION
        # ID deterministico: rodar de novo grava o mesmo doc (idempotente).
        doc_id = f"autoclose_{last.get('id')}"
        try:
            db.collection("time_records").document(doc_id).set({
                "user_id": uid,
                "record_type": close_type,
                "timestamp": _local_iso(close_at),
                "location": "Sistema (Auto)",
                "notes": "Retorno automatico (pausa excedeu 3h; ajustado para 1h) [servidor]",
                "auto_closed": True,
                "created_at": firestore.SERVER_TIMESTAMP,
            })
            _create_user_notification(
                db, uid, "Pausa encerrada",
                "Sua pausa excedeu 3h e foi fechada automaticamente com 1 hora de pausa.",
                "break_auto_closed", "",
            )
            _send_user_push(
                uid, "Pausa encerrada",
                "Sua pausa excedeu 3h e foi fechada automaticamente.",
                {"type": "break_auto_closed"},
            )
            print(f"[auto-close] pausa fechada para {uid} (inicio {last.get('timestamp')})")
        except Exception as exc:
            print(f"[auto-close] falha ao fechar pausa de {uid}: {exc}")
    return True

async def _auto_close_breaks_loop() -> None:
    # A primeira rodada sai ja no boot e olha _AUTO_CLOSE_MAX_AGE para tras:
    # com o servidor fora do ar, pausas venceram sem ninguem fechar e a janela
    # de 10h nao alcancaria todas. A recuperacao so termina quando a consulta
    # funciona (logo apos uma queda o Firestore pode ainda nao responder);
    # depois volta a janela curta, que mantem as leituras baixas.
    window = _AUTO_CLOSE_MAX_AGE
    while True:
        try:
            if await asyncio.to_thread(_run_auto_close_breaks, window):
                window = _AUTO_CLOSE_WINDOW
        except Exception as exc:
            print(f"[auto-close] loop: {exc}")
        await asyncio.sleep(_AUTO_CLOSE_INTERVAL_SECONDS)

# --- JOB: backup diario (Firestore + SQLite) ---
# Firestore no plano Spark nao tem backup gerenciado; este job exporta tudo,
# guarda local (host, via bind mount) e envia copia off-machine ao Storage.

_BACKUP_DIR = "/app/data/backups"
# Completo uma vez por semana; nos outros dias so o que mudou nas colecoes que
# so crescem. Ler o banco inteiro todo dia comia a cota diaria do plano Spark
# (50 mil leituras) conforme os pontos se acumulavam (28/10/2026).
_BACKUP_FULL_EVERY = timedelta(days=7)
_BACKUP_FULLS_KEPT = 3
# Colecoes que crescem sem parar. No incremental entram so os documentos com
# created_at ou updated_at depois do ultimo backup; as demais (usuarios,
# configuracoes...) sao pequenas e vao inteiras.
_GROWING_COLLECTIONS = {
    "time_records", "time_record_audits", "system_audits", "user_audits",
    "user_notifications", "daily_entries", "work_schedule_approval_requests",
    "adjustment_requests", "adjustment_conversations", "signature_documents",
}
# Folga na janela do incremental: relogios e o tempo do proprio backup.
_BACKUP_OVERLAP = timedelta(hours=1)
_BACKUP_MIN_INTERVAL = timedelta(hours=20)      # nao repete se ja ha um recente
_BACKUP_CHECK_INTERVAL_SECONDS = 6 * 3600        # confere a cada 6h
_BACKUP_STORAGE_PREFIX = "backups/"
_BACKUP_STORAGE_BUCKET = os.getenv(
    "FIREBASE_STORAGE_BUCKET", "ponto-vmac.firebasestorage.app"
)

def _json_default(obj):
    if isinstance(obj, (datetime, date)):
        return obj.isoformat()
    if isinstance(obj, bytes):
        return base64.b64encode(obj).decode("ascii")
    return str(obj)

def _export_firestore(db, since: Optional[datetime] = None) -> tuple:
    """(dump, colecoes completas). Com since (incremental), as colecoes de
    _GROWING_COLLECTIONS levam so o criado ou alterado desde since."""
    dump, complete = {}, []
    for coll in db.collections():
        if since is None or coll.id not in _GROWING_COLLECTIONS:
            dump[coll.id] = [{"id": doc.id, **(doc.to_dict() or {})} for doc in coll.stream()]
            complete.append(coll.id)
            continue
        changed = {}
        for field in ("created_at", "updated_at"):
            for doc in coll.where(field, ">=", since).stream():
                changed[doc.id] = {"id": doc.id, **(doc.to_dict() or {})}
        dump[coll.id] = list(changed.values())
    return dump, complete

def _is_incremental(name: str) -> bool:
    return name.endswith("-inc.zip")

def _backup_order(name: str) -> tuple:
    """Pela data do nome; na mesma data o completo antes do incremental (na
    ordem alfabetica "-inc.zip" viria antes de ".zip")."""
    stamp = name[:-len("-inc.zip")] if _is_incremental(name) else name[:-len(".zip")]
    return stamp, _is_incremental(name)

def _local_backups() -> List[str]:
    try:
        return sorted(
            (f for f in os.listdir(_BACKUP_DIR)
             if f.startswith("backup-") and f.endswith(".zip")),
            key=_backup_order,
        )
    except FileNotFoundError:
        return []

def _backups_to_delete(names: List[str]) -> List[str]:
    """Os _BACKUP_FULLS_KEPT completos mais novos ficam, e os incrementais a
    partir do mais antigo deles (um incremental sem o completo de antes nao
    restaura nada)."""
    names = sorted(names, key=_backup_order)
    fulls = [n for n in names if not _is_incremental(n)]
    if len(fulls) <= _BACKUP_FULLS_KEPT:
        oldest_kept = fulls[0] if fulls else None
    else:
        oldest_kept = fulls[-_BACKUP_FULLS_KEPT]
    if oldest_kept is None:
        return []
    return [n for n in names if _backup_order(n) < _backup_order(oldest_kept)]

def _rotate_local_backups():
    for old in _backups_to_delete(_local_backups()):
        try:
            os.remove(os.path.join(_BACKUP_DIR, old))
        except OSError:
            pass

def _upload_backup_to_storage(path: str, name: str) -> str:
    if storage is None:
        return "storage indisponivel"
    try:
        bucket = storage.bucket(_BACKUP_STORAGE_BUCKET)
        bucket.blob(_BACKUP_STORAGE_PREFIX + name).upload_from_filename(path)
        remote = {
            b.name[len(_BACKUP_STORAGE_PREFIX):]: b
            for b in bucket.list_blobs(prefix=_BACKUP_STORAGE_PREFIX)
            if b.name.endswith(".zip")
        }
        for old in (remote[n] for n in _backups_to_delete(list(remote))):
            try:
                old.delete()
            except Exception:
                pass
        return "ok"
    except Exception as exc:
        return f"falha: {exc}"

def _run_backup(force: bool = False) -> dict:
    try:
        db = get_firestore_admin()
    except Exception as exc:
        return {"status": "skip", "reason": f"firestore indisponivel: {exc}"}

    os.makedirs(_BACKUP_DIR, exist_ok=True)
    if not force:
        existing = _local_backups()
        if existing:
            newest = os.path.getmtime(os.path.join(_BACKUP_DIR, existing[-1]))
            if datetime.now().timestamp() - newest < _BACKUP_MIN_INTERVAL.total_seconds():
                return {"status": "skip", "reason": "backup recente ja existe"}

    existing = _local_backups()
    fulls = [n for n in existing if not _is_incremental(n)]
    now = datetime.now().timestamp()
    full = force or not fulls or (
        now - os.path.getmtime(os.path.join(_BACKUP_DIR, fulls[-1]))
        >= _BACKUP_FULL_EVERY.total_seconds()
    )
    since = None
    if not full:
        last = os.path.getmtime(os.path.join(_BACKUP_DIR, existing[-1]))
        since = datetime.fromtimestamp(last, ZoneInfo("UTC")) - _BACKUP_OVERLAP

    stamp = datetime.now(ZoneInfo(_AUTO_CLOSE_TZ)).strftime("%Y%m%d-%H%M%S")
    name = f"backup-{stamp}.zip" if full else f"backup-{stamp}-inc.zip"
    zip_path = os.path.join(_BACKUP_DIR, name)
    tmp_dir = tempfile.mkdtemp()
    try:
        fs_dump, complete = _export_firestore(db, since)
        fs_path = os.path.join(tmp_dir, "firestore.json")
        with open(fs_path, "w", encoding="utf-8") as handle:
            json.dump(fs_dump, handle, ensure_ascii=False, default=_json_default)
        # Para o restore_backup.py juntar o completo e os incrementais.
        manifest_path = os.path.join(tmp_dir, "manifest.json")
        with open(manifest_path, "w", encoding="utf-8") as handle:
            json.dump({
                "type": "full" if full else "incremental",
                "since": since.isoformat() if since else None,
                "base": None if full else fulls[-1],
                "complete_collections": complete,
            }, handle, ensure_ascii=False)

        sqlite_path = os.path.join(tmp_dir, "ponto.db")
        source = sqlite3.connect(DATABASE_PATH)
        try:
            source.execute("VACUUM INTO ?", (sqlite_path,))
        except Exception:
            shutil.copy(DATABASE_PATH, sqlite_path)  # fallback
        finally:
            source.close()

        with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as archive:
            archive.write(fs_path, "firestore.json")
            archive.write(manifest_path, "manifest.json")
            if os.path.exists(sqlite_path):
                archive.write(sqlite_path, "ponto.db")
    finally:
        shutil.rmtree(tmp_dir, ignore_errors=True)

    upload = _upload_backup_to_storage(zip_path, name)
    _rotate_local_backups()
    counts = {k: len(v) for k, v in fs_dump.items()}
    size = os.path.getsize(zip_path)
    print(f"[backup] {name} ({size} bytes) upload={upload} colecoes={counts}")
    return {"status": "ok", "file": name, "type": "full" if full else "incremental",
            "bytes": size, "upload": upload, "collections": counts}

# Copia off-machine por email (semanal). O Storage exige plano pago; o email
# reusa o SMTP ja configurado. O anexo vai cifrado (AES) por conter dados
# pessoais.
_BACKUP_EMAIL = os.getenv("BACKUP_EMAIL", MAIL_USERNAME)
_BACKUP_ZIP_PASSWORD = os.getenv("BACKUP_ZIP_PASSWORD", "")
_BACKUP_EMAIL_INTERVAL = timedelta(days=7)
_BACKUP_EMAIL_MARKER = os.path.join(_BACKUP_DIR, ".last_email")

def _encrypt_backup(zip_path: str, out_path: str) -> bool:
    # Fernet (AES) em blob opaco. O Gmail bloqueia zip cifrado (reconhece a
    # assinatura do arquivo), mas entrega um binario sem formato reconhecivel.
    # Restaurar: backend/restore_backup.py com a BACKUP_ZIP_PASSWORD.
    try:
        import base64
        import hashlib
        from cryptography.fernet import Fernet
    except Exception as exc:
        print(f"[backup-email] cryptography indisponivel: {exc}")
        return False
    try:
        key = base64.urlsafe_b64encode(
            hashlib.sha256(_BACKUP_ZIP_PASSWORD.encode("utf-8")).digest()
        )
        with open(zip_path, "rb") as handle:
            token = Fernet(key).encrypt(handle.read())
        with open(out_path, "wb") as handle:
            handle.write(token)
        return True
    except Exception as exc:
        print(f"[backup-email] falha ao cifrar: {exc}")
        return False

def _send_backup_email() -> str:
    if not _BACKUP_ZIP_PASSWORD:
        return "sem senha configurada (BACKUP_ZIP_PASSWORD)"
    if not MAIL_PASSWORD or MAIL_PASSWORD == "mude-me":
        return "SMTP nao configurado"
    # So o completo: o incremental sozinho nao restaura nada.
    backups = [n for n in _local_backups() if not _is_incremental(n)]
    if not backups:
        return "sem backup para enviar"
    latest = os.path.join(_BACKUP_DIR, backups[-1])
    enc_path = latest + ".enc"
    if not _encrypt_backup(latest, enc_path):
        return "falha ao cifrar"

    import smtplib
    from email.message import EmailMessage
    try:
        msg = EmailMessage()
        msg["Subject"] = f"Backup Ponto VMac - {backups[-1]}"
        msg["From"] = MAIL_FROM
        msg["To"] = _BACKUP_EMAIL
        msg.set_content(
            "Backup semanal do sistema de ponto em anexo (arquivo .enc cifrado).\n"
            "Para restaurar: backend/restore_backup.py <arquivo.enc>, informando a\n"
            "BACKUP_ZIP_PASSWORD do servidor. Gera de volta o .zip com\n"
            "firestore.json + ponto.db.\n"
            "Contem dados pessoais; guarde com cuidado."
        )
        with open(enc_path, "rb") as handle:
            msg.add_attachment(
                handle.read(), maintype="application", subtype="octet-stream",
                filename=os.path.basename(enc_path),
            )
        with smtplib.SMTP(MAIL_SERVER, MAIL_PORT, timeout=60) as server:
            server.starttls()
            server.login(MAIL_USERNAME, MAIL_PASSWORD)
            server.send_message(msg)
        return "ok"
    except Exception as exc:
        return f"falha no envio: {exc}"
    finally:
        try:
            os.remove(enc_path)
        except OSError:
            pass

def _maybe_email_backup() -> None:
    try:
        if os.path.exists(_BACKUP_EMAIL_MARKER):
            last = os.path.getmtime(_BACKUP_EMAIL_MARKER)
            if datetime.now().timestamp() - last < _BACKUP_EMAIL_INTERVAL.total_seconds():
                return
        result = _send_backup_email()
        print(f"[backup-email] {result}")
        if result == "ok":
            with open(_BACKUP_EMAIL_MARKER, "w") as handle:
                handle.write(datetime.now().isoformat())
    except Exception as exc:
        print(f"[backup-email] erro: {exc}")

async def _backup_loop() -> None:
    while True:
        try:
            await asyncio.to_thread(_run_backup)
            await asyncio.to_thread(_maybe_email_backup)
        except Exception as exc:
            print(f"[backup] loop: {exc}")
        await asyncio.sleep(_BACKUP_CHECK_INTERVAL_SECONDS)

@app.post("/admin/backup/run")
async def run_backup_endpoint(admin=Depends(require_admin_user)):
    result = await asyncio.to_thread(_run_backup, True)
    if result.get("status") != "ok":
        raise HTTPException(status_code=503, detail=result.get("reason", "falha no backup"))
    return result

@app.post("/admin/backup/email")
async def email_backup_endpoint(admin=Depends(require_admin_user)):
    await asyncio.to_thread(_run_backup, True)
    result = await asyncio.to_thread(_send_backup_email)
    if result != "ok":
        raise HTTPException(status_code=503, detail=result)
    return {"status": "ok", "sent_to": _BACKUP_EMAIL}

@app.get("/admin/backup/list")
def list_backups_endpoint(admin=Depends(require_admin_user)):
    out = []
    for name in reversed(_local_backups()):
        path = os.path.join(_BACKUP_DIR, name)
        out.append({
            "file": name,
            "bytes": os.path.getsize(path),
            "modified": datetime.fromtimestamp(
                os.path.getmtime(path), ZoneInfo(_LOCAL_TZ)
            ).replace(tzinfo=None).isoformat(),
        })
    return {"retention": _BACKUP_RETENTION, "bucket": _BACKUP_STORAGE_BUCKET,
            "backups": out}

def delete_query_in_batches(db, query, batch_size: int = 300) -> int:
    deleted = 0
    while True:
        docs = list(query.limit(batch_size).stream())
        if not docs:
            return deleted

        batch = db.batch()
        for doc in docs:
            batch.delete(doc.reference)
        batch.commit()
        deleted += len(docs)

def delete_user_cascade(db, user_id: str) -> dict:
    collections_by_user_id = [
        "time_records",
        "daily_entries",
        "adjustment_requests",
        "adjustment_conversations",
    ]
    deleted_counts = {}

    for collection_name in collections_by_user_id:
        count = delete_query_in_batches(
            db,
            db.collection(collection_name).where("user_id", "==", user_id),
        )
        deleted_counts[collection_name] = count

    # As auditorias (time_record_audits, user_audits) ficam: sao o registro de quem mexeu em que e as regras do
    # Firestore as declaram imutaveis. Apagar o usuario nao apaga o rastro (17/10/2026).

    user_ref = db.collection("users").document(user_id)
    if user_ref.get().exists:
        user_ref.delete()
        deleted_counts["users"] = 1
    else:
        deleted_counts["users"] = 0

    return deleted_counts

# --- LÓGICA EXCEL ---

# Um modelo por tipo, valido para qualquer mes: dia e dia da semana (colunas
# A/B) sao escritos aqui a partir do periodo. Os modelos antigos eram um
# arquivo por mes/ano e a exportacao quebrava em todo ano novo sem modelo.
EXCEL_TEMPLATE_FILES = {
    True: ("Excel-Campo", "Folha_Ponto_Campo.xlsx"),
    False: ("Excel-Administrativos", "Folha_Ponto_administrativo.xlsx"),
}
EXCEL_WEEKDAY_NAMES = ["Seg", "Ter", "Qua", "Qui", "Sex", "Sáb", "Dom"]
EXCEL_FIRST_DAY_ROW = 9
EXCEL_DAY_ROWS = 31
# Bloco de assinaturas (M8:P35): N34 e o total do mes; o resto e texto fixo
# do modelo e nao pode ser apagado.
EXCEL_MONTH_TOTAL_CELL = "N34"
# A coluna A (numero do dia) entra na impressao: o modelo marca B1:P39, mas
# sem a coluna A a folha impressa sai sem as datas.
EXCEL_PRINT_AREA = "A1:P39"
# Estagiario: inclui o resumo financeiro das linhas 40-44.
EXCEL_PRINT_AREA_INTERN = "A1:P44"
# Largura da coluna A com a data "dd/mm" do fechamento 29..28.
EXCEL_CUSTOM_DAY_WIDTH = 6.5

def excel_template_path(is_campo: bool) -> str:
    type_path, file_name = EXCEL_TEMPLATE_FILES[bool(is_campo)]
    for base in (
        os.path.join("..", "frontend"),
        "frontend",
        os.path.join("ponto-system", "frontend"),
    ):
        candidate = os.path.join(base, "assets", "templates", type_path, file_name)
        if os.path.exists(candidate):
            return candidate
    raise FileNotFoundError(f"Template não encontrado: {file_name}")

DAILY_SHEET_TITLE = "Diárias"
DAILY_WEEKDAY_NAMES = [
    "Segunda-feira", "Terça-feira", "Quarta-feira", "Quinta-feira",
    "Sexta-feira", "Sábado", "Domingo",
]
DAILY_HEADER_ROW = 7

def add_daily_entries_sheet(wb, timesheet_ws, data: ExportData) -> None:
    """Aba "Diárias", a primeira do arquivo e a que abre: os dias com diaria
    do periodo e o total. A folha de ponto padrao fica na aba seguinte, com
    um dia padrao em cada um desses dias (daily_mode_records)."""
    ws = wb.create_sheet(DAILY_SHEET_TITLE, 0)
    days = [date.fromisoformat(record.date) for record in data.daily_records]
    bold = Font(bold=True)
    thin = Side(style="thin", color="000000")
    border = Border(left=thin, right=thin, top=thin, bottom=thin)
    center = Alignment(horizontal="center", vertical="center")

    ws["A1"] = "Diárias trabalhadas"
    ws["A1"].font = Font(bold=True, size=14)
    ws["A3"] = f"Colaborador: {data.employee_name}"
    # A mesma funcao que a folha mostra (C6).
    ws["A4"] = f"Função: {timesheet_ws.cell(row=6, column=3).value or ''}"
    ws["A5"] = f"Período: {export_period_label(data)}"

    for col, title in enumerate(("Nº", "Data", "Dia da semana"), start=1):
        cell = ws.cell(row=DAILY_HEADER_ROW, column=col, value=title)
        cell.font = bold
        cell.border = border
        cell.alignment = center
    row = DAILY_HEADER_ROW
    for number, day in enumerate(days, start=1):
        row = DAILY_HEADER_ROW + number
        values = (number, day, DAILY_WEEKDAY_NAMES[day.weekday()])
        for col, value in enumerate(values, start=1):
            cell = ws.cell(row=row, column=col, value=value)
            cell.border = border
            cell.alignment = center
        ws.cell(row=row, column=2).number_format = "DD/MM/YYYY"

    total_row = row + 2
    ws.cell(row=total_row, column=1, value="Total de diárias").font = bold
    ws.merge_cells(start_row=total_row, start_column=1, end_row=total_row, end_column=2)
    total = ws.cell(row=total_row, column=3, value=len(days))
    total.font = bold
    total.alignment = center
    for col in range(1, 4):
        ws.cell(row=total_row, column=col).border = border

    # A + B + C cabem "Colaborador: <nome completo>" na impressao.
    ws.column_dimensions["A"].width = 8
    ws.column_dimensions["B"].width = 16
    ws.column_dimensions["C"].width = 26
    ws.print_area = f"A1:C{total_row}"

    # Abre nesta aba. Com a folha ainda marcada como selecionada, o Excel
    # abria as duas agrupadas e a edicao de uma mudava a outra.
    timesheet_ws.sheet_view.tabSelected = False
    ws.sheet_view.tabSelected = True
    wb.active = ws

def generate_excel_file(data: ExportData) -> str:
    wb = openpyxl.load_workbook(excel_template_path(data.is_campo))
    ws = wb.active

    if data.daily_mode:
        data.daily_records = daily_mode_records(data)
    elif data.generate_from_scratch:
        scratch_days = export_period_dates(data) if (data.period_start and data.period_end) else None
        data.daily_records = generate_scratch_records(int(data.year), int(data.month), data.target_hours or 210.0, days=scratch_days)

    period_dates = export_period_dates(data)
    custom_period = bool(data.period_start and data.period_end)
    row_by_date = {
        current.isoformat(): EXCEL_FIRST_DAY_ROW + idx
        for idx, current in enumerate(period_dates[:EXCEL_DAY_ROWS])
    }

    ws.cell(row=5, column=3).value = data.employee_name
    is_estagiario = "estagiario" in data.employee_role.lower() or "intern" in data.employee_role.lower()

    if data.custom_role: ws.cell(row=6, column=3).value = data.custom_role
    elif is_estagiario: ws.cell(row=6, column=3).value = "Aux. Administrativo"
    else:
        name_norm = data.employee_name.strip().lower()
        ws.cell(row=6, column=3).value = "Técnico Geral" if (data.is_campo and name_norm.startswith("kelvyn")) else "Aux. Geral"

    ws.cell(row=5, column=11).value = data.custom_work_hours or ("13:30 - 19:30" if is_estagiario else "-")
    ws.cell(row=6, column=9).value = data.custom_department or ("Processamento de Dados" if is_estagiario else "Campo")
    if custom_period:
        ws.cell(row=7, column=2).value = f"Fechamento: {export_period_label(data)}"
        # A coluna A do modelo (4,9) cabe "01".."31", nao "29/09": cortada, a
        # data saia "29/0" na tela e na impressao.
        width = ws.column_dimensions["A"].width or 0
        ws.column_dimensions["A"].width = max(width, EXCEL_CUSTOM_DAY_WIDTH)

    total_bank = {"normal": 0, "extras": 0, "50": 0, "100": 0}

    day_format = "%d/%m" if custom_period else "%d"
    for idx in range(EXCEL_DAY_ROWS):
        row_idx = EXCEL_FIRST_DAY_ROW + idx
        current_date = period_dates[idx] if idx < len(period_dates) else None
        # Limpa a linha inteira (A..I) antes: as linhas alem do fim do periodo
        # (mes de 28/30 dias) ficam vazias, sem dia nem formula.
        for clear_col in range(1, 10):
            ws.cell(row=row_idx, column=clear_col).value = None
        if current_date is None:
            continue
        ws.cell(row=row_idx, column=1).value = current_date.strftime(day_format)
        ws.cell(row=row_idx, column=2).value = EXCEL_WEEKDAY_NAMES[current_date.weekday()]
        # So conta o par se AMBAS as celulas (entrada e saida) estiverem preenchidas.
        # Sem isso, um turno aberto (saida vazia) gera MOD(-entrada,1) = horas ate a meia-noite (bug do 10:30).
        ws.cell(row=row_idx, column=9).value = (
            f"=IF(OR(C{row_idx}=\"\",D{row_idx}=\"\"),0,MOD(D{row_idx}-C{row_idx},1))"
            f"+IF(OR(E{row_idx}=\"\",F{row_idx}=\"\"),0,MOD(F{row_idx}-E{row_idx},1))"
            f"+IF(OR(G{row_idx}=\"\",H{row_idx}=\"\"),0,MOD(H{row_idx}-G{row_idx},1))"
        )
        ws.cell(row=row_idx, column=9).number_format = "[h]:mm"

    holiday_keys = holiday_date_keys(data)

    for record in data.daily_records:
        record_date = datetime.fromisoformat(record.date).date()
        row_idx = row_by_date.get(record_date.isoformat())
        if row_idx is None:
            continue
        # "00:00" vai como veio: o MOD(D-C,1) da coluna I ja conta a saida a
        # meia-noite. Trocar por "23:59" tirava 1 min do dia, de I40 e de N34
        # (e so nas colunas D e H, nao na F).
        if record.check_in: ws.cell(row=row_idx, column=3).value = record.check_in
        if record.check_out: ws.cell(row=row_idx, column=4).value = record.check_out
        if record.break_start: ws.cell(row=row_idx, column=5).value = record.break_start
        if record.break_end: ws.cell(row=row_idx, column=6).value = record.break_end
        if record.entry_3: ws.cell(row=row_idx, column=7).value = record.entry_3
        if record.exit_3: ws.cell(row=row_idx, column=8).value = record.exit_3

        if is_estagiario and record.check_in and record.check_out:
            payroll = classify_estag_payroll(record, record_date, holiday_keys, data.estag_rules)
            total_bank["normal"] += payroll["normal"]
            total_bank["extras"] += payroll["extras"]
            total_bank["50"] += payroll["50"]
            total_bank["100"] += payroll["100"]

    if is_estagiario:
        ws.cell(row=SUMMARY_ROW_TITLE, column=2).value = "Normais"
        ws.cell(row=SUMMARY_ROW_TITLE, column=3).value = "Extras"
        ws.cell(row=SUMMARY_ROW_TITLE, column=4).value = "50%"
        ws.cell(row=SUMMARY_ROW_TITLE, column=5).value = "100%"
        ws.cell(row=SUMMARY_ROW_HOURS, column=2).value = total_bank["normal"] / 1440.0
        ws.cell(row=SUMMARY_ROW_HOURS, column=3).value = total_bank["extras"] / 1440.0
        ws.cell(row=SUMMARY_ROW_HOURS, column=4).value = total_bank["50"] / 1440.0
        ws.cell(row=SUMMARY_ROW_HOURS, column=5).value = total_bank["100"] / 1440.0
        ws.cell(row=SUMMARY_ROW_VALUE, column=2).value = f"=B42*24*{RATE_NORMAL}"
        ws.cell(row=SUMMARY_ROW_VALUE, column=3).value = f"=C42*24*{RATE_EXTRA}"
        ws.cell(row=SUMMARY_ROW_VALUE, column=4).value = f"=D42*24*{RATE_50}"
        ws.cell(row=SUMMARY_ROW_VALUE, column=5).value = f"=E42*24*{RATE_100}"
        bold = Font(bold=True); thin = Side(style="thin", color="000000"); border = Border(left=thin, right=thin, top=thin, bottom=thin)
        for i in range(2, 6):
            ws.cell(row=SUMMARY_ROW_HOURS, column=i).number_format = "[h]:mm"
            ws.cell(row=SUMMARY_ROW_VALUE, column=i).number_format = '#,##0.00'
            for r in [SUMMARY_ROW_TITLE, SUMMARY_ROW_HOURS, SUMMARY_ROW_VALUE]:
                ws.cell(row=r, column=i).font = bold; ws.cell(row=r, column=i).border = border
        ws.cell(row=SUMMARY_ROW_FINAL, column=2).value = "TOTAL GERAL"
        ws.cell(row=SUMMARY_ROW_FINAL, column=3).value = "=SUM(B43:E43)+500"
        ws.cell(row=SUMMARY_ROW_FINAL, column=3).number_format = '"R$ "#,##0.00'; ws.cell(row=SUMMARY_ROW_FINAL, column=3).font = bold

    # Nao ha mais limpeza das colunas M..T: ela vinha dos modelos antigos, com
    # colunas de apoio que nenhum modelo atual tem. Agora M..P sao o bloco de
    # assinaturas (celulas mescladas, apagar quebraria o texto) e Q..T estao
    # vazias.

    try: ws.unmerge_cells('I40:J40')
    except: pass
    ws.merge_cells('I40:J40')
    cell_total = ws['I40']; cell_total.value = "=SUM(I9:I39)"; cell_total.number_format = "[h]:mm"
    cell_total.alignment = Alignment(horizontal="center", vertical="center"); cell_total.font = Font(bold=True)

    # O valor de N34 no modelo e so exemplo; aqui vira o total real do mes.
    month_total = ws[EXCEL_MONTH_TOTAL_CELL]
    month_total.value = "=SUM(I9:I39)"
    month_total.number_format = "[h]:mm"

    ws.print_area = EXCEL_PRINT_AREA_INTERN if is_estagiario else EXCEL_PRINT_AREA

    if data.daily_mode:
        add_daily_entries_sheet(wb, ws, data)

    tmp = tempfile.NamedTemporaryFile(delete=False, suffix=".xlsx")
    wb.save(tmp.name); wb.close()
    return tmp.name

# --- LOGICA HTML (RELATORIO MENSAL COM ABAS) ---

def is_intern_export(data: ExportData) -> bool:
    role = data.employee_role.lower()
    custom_role = (data.custom_role or "").lower()
    return "estag" in role or "intern" in role or "estag" in custom_role

def excel_download_filename(data: ExportData) -> str:
    if is_intern_export(data):
        suffix = "_estag"
    elif data.daily_mode:
        suffix = "_diarias"
    else:
        suffix = ""
    return f"Folha_Ponto_{data.employee_name}_{data.month}{suffix}.xlsx"

MONTH_NAMES = {
    1: "Janeiro", 2: "Fevereiro", 3: "Marco", 4: "Abril",
    5: "Maio", 6: "Junho", 7: "Julho", 8: "Agosto",
    9: "Setembro", 10: "Outubro", 11: "Novembro", 12: "Dezembro",
}

WEEKDAY_NAMES = ["Seg", "Ter", "Qua", "Qui", "Sex", "Sab", "Dom"]

HTML_STYLE = """
*{box-sizing:border-box;margin:0;padding:0}
body{font-family:'Segoe UI',Arial,sans-serif;background:#f0f2f5;color:#222;font-size:14px}
header{background:#1a3a5c;color:#fff;padding:1rem 1.5rem}
header h1{font-size:1.15rem}
header p{font-size:.8rem;opacity:.78;margin-top:.2rem}
.tabs-wrap{background:#1a3a5c;padding:0 .5rem;display:flex;flex-wrap:wrap;gap:2px;align-items:flex-end;position:sticky;top:0;z-index:10}
.tab-btn{background:rgba(255,255,255,.1);color:#cde;border:none;padding:.45rem .75rem;cursor:pointer;font-size:.78rem;border-radius:4px 4px 0 0;white-space:nowrap;transition:background .15s}
.tab-btn:hover{background:rgba(255,255,255,.22)}
.tab-btn.active{background:#f0f2f5;color:#1a3a5c;font-weight:700}
.tab-btn.consolidado{background:#c07010;color:#fff;margin-left:auto}
.tab-btn.consolidado.active{background:#f0f2f5;color:#c07010}
.badge{display:inline-block;font-size:.62rem;padding:1px 5px;border-radius:3px;margin-left:3px;vertical-align:middle}
.badge.estag{background:#3a7bd5;color:#fff}.badge.rev{background:#c05010;color:#fff}.badge.clt{background:#28724f;color:#fff}.badge.diaria{background:#7a4fb0;color:#fff}
.content{padding:1rem}
.tab-panel{background:#fff;border-radius:6px;padding:1.1rem;box-shadow:0 1px 5px rgba(0,0,0,.1)}
.emp-header{margin-bottom:.6rem}.emp-info h2{font-size:1.2rem;color:#1a3a5c}
.emp-info span{display:inline-block;margin-right:1.2rem;font-size:.85rem;color:#555;margin-top:.25rem}
.data-warn{background:#fff3cd;border:1px solid #f0ad4e;border-left:4px solid #e67e00;border-radius:4px;padding:.55rem .8rem;font-size:.82rem;color:#6d4400;margin-bottom:.7rem}
.summary-grid{display:flex;flex-wrap:wrap;gap:.5rem;margin:.6rem 0 .8rem}
.s-card{background:#f4f6fa;border-radius:5px;padding:.45rem .8rem;min-width:100px;text-align:center;border-top:3px solid #cbd3e8}
.s-card span{display:block;font-size:.68rem;color:#666}.s-card strong{font-size:1rem;color:#1a3a5c}
.s-card.normal{border-color:#3a7bd5}.s-card.he50{border-color:#e89020}.s-card.he100{border-color:#d04020}
.s-card.noc{border-color:#5040a0}.s-card.noc2{border-color:#8060d0}.s-card.dom{border-color:#c02060}.s-card.fer{border-color:#e06010}.s-card.dsr{border-color:#b06000}
.payroll-notice{background:#f0f6ff;border:1px solid #b8d4f8;border-left:4px solid #1a5fc8;border-radius:4px;padding:.6rem 1rem;margin:.6rem 0 .8rem}
.payroll-notice.ok{background:#eafaf1;border-color:#a3d9a5;border-left-color:#27ae60;color:#1a5c2a}
.payroll-notice.estag-note{background:#fdf4e7;border-color:#f5c980;border-left-color:#c07010;color:#704000}
.pn-title{font-weight:700;font-size:.85rem;margin-bottom:.3rem;color:#1a3a5c}
.payroll-notice.ok .pn-title,.payroll-notice.estag-note .pn-title{color:inherit}
.pn-list{padding-left:1.2rem;margin:0;font-size:.82rem;line-height:1.7}
.pi-lbl{display:inline-block;font-size:.65rem;font-weight:700;padding:1px 6px;border-radius:3px;margin-right:4px;vertical-align:middle}
.pi-lbl.he50{background:#fde9c0;color:#7a4800}.pi-lbl.he100{background:#fdd;color:#900}.pi-lbl.noc{background:#ede;color:#408}.pi-lbl.dom{background:#fcd;color:#900}.pi-lbl.fer{background:#ffe0b2;color:#7a3600}.pi-lbl.dsr{background:#fda;color:#640}
.section-title{font-size:.92rem;font-weight:700;color:#1a3a5c;background:#e8eef8;border-left:4px solid #1a3a5c;padding:.35rem .7rem;border-radius:0 4px 4px 0;margin-bottom:.4rem}
.legend{font-size:.78rem;color:#555;margin-bottom:.6rem;line-height:1.6}
.table-wrap{overflow-x:auto}table{width:100%;border-collapse:collapse;font-size:.82rem}
th{background:#1a3a5c;color:#fff;padding:.4rem .5rem;text-align:center;white-space:nowrap}
td{padding:.28rem .45rem;text-align:center;border-bottom:1px solid #eee;white-space:nowrap}
tr:hover td{background:#f5f8ff}tr.sabado td{background:#fffbe6}tr.domingo td{background:#fff0f4}tr.feriado td{background:#fff4e0}tr.estag-row td{background:#f0f8ff}
tr.totals td{background:#eef2fa;font-weight:600}tr.grand-total td{background:#1a3a5c;color:#fff}
.soma{font-weight:700;color:#1a3a5c}.hn{color:#2255aa}.he50{color:#b06000;font-weight:600}.he100{color:#c02000;font-weight:600}.noc{color:#5040a0}.dom{color:#c02060}.fer{color:#c05000}.dsr-col{color:#7a4000;font-weight:600}
.hora-zero{color:#ccc}.num{color:#444}.na{color:#aaa;font-style:italic;font-size:.75rem}.nil{color:#bbb}.centro{text-align:center}.warn-ico{color:#e67e00;font-style:normal}
.flags{text-align:left;white-space:normal;min-width:80px}.flag{display:inline-block;font-size:.63rem;padding:1px 5px;border-radius:3px;margin:1px 2px;font-weight:700;white-space:nowrap}
.flag.dom{background:#fcd;color:#900}.flag.fer{background:#ffe0b2;color:#7a3600}.flag.dsr{background:#fda;color:#640}.flag.noc{background:#dce;color:#408;cursor:help}.flag.warn{background:#fff3cd;color:#7a4400;border:1px solid #f0ad4e}
.tag{display:inline-block;font-size:.63rem;font-weight:700;padding:1px 5px;border-radius:3px;margin:1px}.tag.he50{background:#fde9c0;color:#7a4800}.tag.he100{background:#fdd;color:#900}.tag.noc{background:#ede;color:#408}.tag.dom{background:#fcd;color:#900}.tag.fer{background:#ffe0b2;color:#7a3600}
.fonte{font-size:.72rem;color:#888;margin-top:.7rem;text-align:right}
@media print{.tabs-wrap{display:none}.tab-panel{display:block!important;page-break-after:always}body{background:#fff}.content{padding:0}.tab-panel{box-shadow:none;border-radius:0}}
"""

def esc(value) -> str:
    return html.escape("" if value is None else str(value))

def tab_id(name: str, idx: int, month: str, year: str, is_estagiario: bool = False) -> str:
    base = re.sub(r"[^A-Za-z0-9_]+", "_", name.strip())
    suffix = "_estag" if is_estagiario else ""
    tail = "" if idx == 0 else f"_{idx}"
    return f"Folha_Ponto_{base}_{month}-{year}{suffix}{tail}"

def abbreviated_name(name: str) -> str:
    parts = [part for part in name.strip().split() if part]
    if len(parts) <= 1:
        return name or "Colaborador"
    if len(parts) == 2:
        return f"{parts[0]} {parts[1][0]}."
    middle = " ".join(f"{part[0]}." for part in parts[1:-1] if part)
    return f"{parts[0]} {middle} {parts[-1]}".strip()

def hours_to_minutes(value) -> int:
    if value is None:
        return 0
    try:
        return int(round(float(value) * 60))
    except Exception:
        return 0

def fmt_minutes(minutes: int, dash: bool = True) -> str:
    minutes = int(round(minutes))
    if minutes <= 0 and dash:
        return "-"
    return f"{minutes // 60:02d}:{minutes % 60:02d}"

def record_total_minutes(record: ExportRecord) -> int:
    if record.total_hours is not None:
        return hours_to_minutes(record.total_hours)

    total = 0
    pairs = [
        (record.check_in, record.check_out),
        (record.break_start, record.break_end),
        (record.entry_3, record.exit_3),
    ]
    for start, end in pairs:
        if start and end:
            total += minutes_between_str(start, end)
    return total

def classify_html_day(record: ExportRecord, is_estagiario: bool, current_date: date, is_holiday: bool = False, rules: Optional[EstagRules] = None, holiday_days: Optional[set] = None) -> dict:
    total = record_total_minutes(record)
    if is_estagiario:
        # Todos os feriados do periodo, nao so o do dia: a madrugada do turno
        # da vespera de um feriado cai no feriado.
        if holiday_days is None:
            holiday_days = {current_date.isoformat()} if is_holiday else set()
        payroll = classify_estag_payroll(record, current_date, holiday_days, rules)
        return {
            "total": total,
            "normal": payroll["normal"],
            "extra_contract": payroll["extras"],
            "he50": payroll["50"],
            "he100": payroll["100"],
            "noc_real": 0,
            "noc_ficto": 0,
        }

    normal = hours_to_minutes(record.regular_hours)
    he50 = hours_to_minutes(record.extra_50)
    he100 = hours_to_minutes(record.extra_100)

    if normal or he50 or he100:
        return {"total": total or normal + he50 + he100, "normal": normal, "extra_contract": 0, "he50": he50, "he100": he100, "noc_real": 0, "noc_ficto": 0}

    if current_date.weekday() == 6 or is_holiday:
        return {"total": total, "normal": 0, "extra_contract": 0, "he50": 0, "he100": total, "noc_real": 0, "noc_ficto": 0}

    normal = min(total, 480)
    he50 = min(max(total - 480, 0), 120)
    he100 = max(total - 600, 0)
    return {"total": total, "normal": normal, "extra_contract": 0, "he50": he50, "he100": he100, "noc_real": 0, "noc_ficto": 0}

def employee_role(data: ExportData, is_estagiario: bool) -> str:
    if data.custom_role:
        return data.custom_role
    if is_estagiario:
        return "Aux. Administrativo"
    return data.employee_role if data.employee_role not in ["employee", "manager", "admin"] else "Aux. Geral"

def employee_department(data: ExportData, is_estagiario: bool) -> str:
    if data.custom_department:
        return data.custom_department
    return "Processamento de Dados" if is_estagiario else "Campo"

def build_employee_html(data: ExportData, panel_id: str, visible: bool) -> tuple[str, dict]:
    year = int(data.year)
    month = int(data.month)
    is_estagiario = "estag" in data.employee_role.lower() or "intern" in data.employee_role.lower()
    role = employee_role(data, is_estagiario)
    department = employee_department(data, is_estagiario)
    is_daily = bool(data.daily_mode)

    if is_daily:
        data.daily_records = daily_mode_records(data)
    elif data.generate_from_scratch:
        scratch_days = export_period_dates(data) if (data.period_start and data.period_end) else None
        data.daily_records = generate_scratch_records(year, month, data.target_hours or 210.0, days=scratch_days)

    period_dates = export_period_dates(data)
    holiday_keys = holiday_date_keys(data)
    records_by_date = {datetime.fromisoformat(r.date).date().isoformat(): r for r in data.daily_records}
    totals = {"days": 0, "total": 0, "normal": 0, "extra_contract": 0, "he50": 0, "he100": 0, "noc_real": 0, "noc_ficto": 0}
    rows = []

    for index, current_date in enumerate(period_dates, start=1):
        record = records_by_date.get(current_date.isoformat())
        classes = []
        is_holiday = current_date.isoformat() in holiday_keys
        if is_holiday:
            classes.append("feriado")
        elif current_date.weekday() == 5:
            classes.append("sabado")
        elif current_date.weekday() == 6:
            classes.append("domingo")
        if is_estagiario:
            classes.append("estag-row")

        vals = {"total": 0, "normal": 0, "extra_contract": 0, "he50": 0, "he100": 0, "noc_real": 0, "noc_ficto": 0}
        if record:
            vals = classify_html_day(record, is_estagiario, current_date, is_holiday, data.estag_rules, holiday_keys)
            if vals["total"] > 0:
                totals["days"] += 1
            for key in ["total", "normal", "extra_contract", "he50", "he100", "noc_real", "noc_ficto"]:
                totals[key] += vals[key]

        flags = []
        if current_date.weekday() == 6:
            flags.append('<span class="flag dom">DOM</span>')
            if vals["total"] > 0:
                flags.append('<span class="flag dsr">DSR</span>')
        if is_holiday:
            flags.append('<span class="flag fer">FERIADO +100%</span>')
            if vals["total"] > 0:
                flags.append('<span class="flag dsr">100%</span>')
        if vals["noc_ficto"] > 0:
            flags.append(f'<span class="flag noc" title="Real: {fmt_minutes(vals["noc_real"])}">AN {fmt_minutes(vals["noc_ficto"])}</span>')

        rows.append(f"""
<tr class="{' '.join(classes)}">
  <td>{current_date.strftime('%d/%m')}</td><td>{WEEKDAY_NAMES[current_date.weekday()]}</td>
  <td>{esc(record.check_in if record else '')}</td><td>{esc(record.check_out if record else '')}</td>
  <td>{esc(record.break_start if record else '')}</td><td>{esc(record.break_end if record else '')}</td>
  <td>{esc(record.entry_3 if record else '')}</td><td>{esc(record.exit_3 if record else '')}</td>
  <td class="soma {'hora-zero' if vals['total'] <= 0 else ''}">{fmt_minutes(vals['total'])}</td>
  <td class="hn">{fmt_minutes(vals['normal'], dash=False) if vals['normal'] else ''}</td>
  <td class="he50">{fmt_minutes(vals['he50'], dash=False) if vals['he50'] else ''}</td>
  <td class="he100">{fmt_minutes(vals['he100'], dash=False) if vals['he100'] else ''}</td>
  <td class="flags">{''.join(flags)}</td>
</tr>""")

    notice = (
        f"""<div class="payroll-notice estag-note"><div class="pn-title">Estagiario - regras aplicadas</div><ul class="pn-list">
<li><span class="pi-lbl he50">Sabado 50%</span> <strong>{fmt_minutes(totals['he50'])}</strong> - horas de sabado entre 06h e 22h</li>
<li><span class="pi-lbl he100">100%</span> <strong>{fmt_minutes(totals['he100'])}</strong> - domingo, feriado e horario noturno 22h-05h</li>
<li><span class="pi-lbl he50">Extras contrato</span> <strong>{fmt_minutes(totals['extra_contract'])}</strong> - excedente de jornada em dia normal</li>
</ul></div>"""
        if is_estagiario
        else f"""<div class="payroll-notice"><div class="pn-title">Lancamentos na Folha de Pagamento</div><ul class="pn-list">
<li><span class="pi-lbl he50">HE 50%</span> <strong>{fmt_minutes(totals['he50'])}</strong> - horas extras entre 8h e 10h/dia</li>
<li><span class="pi-lbl he100">HE 100%</span> <strong>{fmt_minutes(totals['he100'])}</strong> - horas extras acima de 10h/dia e domingos/DSR</li>
<li><span class="pi-lbl noc">Ad. Noturno</span> <strong>{fmt_minutes(totals['noc_ficto'])}</strong> h ficto</li>
</ul></div>"""
    )

    daily_notice = (
        f"""<div class="payroll-notice ok"><div class="pn-title">Modo diaria - {len(data.daily_records)} diaria(s) no periodo</div></div>"""
        if is_daily
        else ""
    )
    badge = '<span class="badge estag">Estag.</span>' if is_estagiario else (
        '<span class="badge diaria">Diária</span>' if is_daily else ''
    )

    panel = f"""
<div class="tab-panel" id="panel-{panel_id}" style="display:{'block' if visible else 'none'}">
  <div class="emp-header"><div class="emp-info">
    <h2>{esc(data.employee_name)}{badge}</h2>
    <span>Funcao: <strong>{esc(role)}</strong></span>
    <span>Departamento: <strong>{esc(department)}</strong></span>
  </div></div>
  <div class="summary-grid">
    <div class="s-card"><span>Total Horas</span><strong>{fmt_minutes(totals['total'])}</strong></div>
    <div class="s-card normal"><span>Horas Normais</span><strong>{fmt_minutes(totals['normal'])}</strong></div>
    <div class="s-card he50"><span>{'Sabado 50%' if is_estagiario else 'HE 50% (8h-10h)'}</span><strong>{fmt_minutes(totals['he50'])}</strong></div>
    <div class="s-card he100"><span>{'Dom/Fer/Not. 100%' if is_estagiario else 'HE 100% (&gt;10h)'}</span><strong>{fmt_minutes(totals['he100'])}</strong></div>
    <div class="s-card noc"><span>Ad. Not. real</span><strong>{fmt_minutes(totals['noc_real'])}</strong></div>
    <div class="s-card noc2"><span>AN ficto (x8/7)</span><strong>{fmt_minutes(totals['noc_ficto'])}</strong></div>
  </div>
  {daily_notice}
  {notice}
  <div class="legend">
    <span class="flag fer">FERIADO</span> Feriado trabalhado (+100%) &nbsp;
    <span class="flag dom">DOM</span> Domingo (+100%) &nbsp;
    <span class="flag dsr">DSR</span> Horas no DSR (HE 100%) &nbsp;
    <span class="flag noc">AN hh:mm</span> Ad. Noturno ficto (x8/7, 22h-05h)
  </div>
  <div class="table-wrap"><table>
    <thead><tr>
      <th>Dia</th><th></th><th>Ent.</th><th>Sai.</th><th>Ent.</th><th>Sai.</th><th>Ent.</th><th>Sai.</th>
      <th>Total</th><th title="Horas normais ate 8h/dia">HN</th><th title="Horas 50%">HE 50%</th><th title="Horas 100%">HE 100%</th><th>Obs.</th>
    </tr></thead>
    <tbody>{''.join(rows)}</tbody>
    <tfoot><tr class="totals"><td colspan="8">Totais</td><td class="soma">{fmt_minutes(totals['total'])}</td><td class="hn">{fmt_minutes(totals['normal'])}</td><td class="he50">{fmt_minutes(totals['he50'])}</td><td class="he100">{fmt_minutes(totals['he100'])}</td><td></td></tr></tfoot>
  </table></div>
  <div class="fonte">Arquivo: {esc(excel_download_filename(data))}</div>
</div>"""

    summary = {**totals, "name": data.employee_name, "role": role, "department": department, "is_estagiario": is_estagiario, "is_daily": is_daily}
    return panel, summary

def build_consolidated_html(summaries: List[dict], month_label: str) -> str:
    rows = []
    grand = {"days": 0, "total": 0, "normal": 0, "he50": 0, "he100": 0, "noc_ficto": 0}
    for summary in summaries:
        for key in grand:
            grand[key] += summary[key]
        estag = summary["is_estagiario"]
        kind = ("estag", "Estag.") if estag else (("diaria", "Diária") if summary.get("is_daily") else ("clt", "CLT"))
        rows.append(f"""
<tr class="{'estag-row' if estag else ''}">
  <td>{esc(summary['name'])}{'<span class="badge estag">Estag.</span>' if estag else ''}</td>
  <td class="centro"><span class="badge {kind[0]}">{kind[1]}</span></td>
  <td>{esc(summary['role'])}</td><td>{esc(summary['department'])}</td>
  <td class="num">{summary['days']}</td>
  <td class="hn">{fmt_minutes(summary['normal'])}</td>
  <td class="he50">{fmt_minutes(summary['he50'])}</td>
  <td class="he100">{fmt_minutes(summary['he100'])}</td>
  <td class="noc">{fmt_minutes(summary['noc_ficto'])}</td>
  <td class="soma">{fmt_minutes(summary['total'])}</td>
</tr>""")

    return f"""
<div class="tab-panel" id="panel-consolidado" style="display:none">
  <h2>Consolidado - {esc(month_label)}</h2>
  <div class="section-title">Resumo de Apuracao</div>
  <div class="legend" style="margin-bottom:.5rem">
    <strong>HN</strong>=Horas normais &nbsp;|&nbsp;
    <strong>HE 50%</strong>=Extras 8h-10h / sabado estagiario &nbsp;|&nbsp;
    <strong>HE 100%</strong>=Extras &gt;10h + domingos + feriados + noturno estagiario &nbsp;|&nbsp;
    <strong>AN ficto</strong>=Ad.Noturno hora ficta &nbsp;|&nbsp;
    HN + HE50% + HE100% = Total Horas
  </div>
  <div class="table-wrap"><table>
    <thead><tr><th>Empregado</th><th>Tipo</th><th>Funcao</th><th>Departamento</th><th>Dias</th><th class="hn">HN</th><th class="he50">HE 50%</th><th class="he100">HE 100%</th><th class="noc">AN ficto</th><th class="soma">Total</th></tr></thead>
    <tbody>{''.join(rows)}</tbody>
    <tfoot><tr class="grand-total"><td colspan="4">TOTAL GERAL</td><td>{grand['days']}</td><td class="hn">{fmt_minutes(grand['normal'])}</td><td class="he50">{fmt_minutes(grand['he50'])}</td><td class="he100">{fmt_minutes(grand['he100'])}</td><td class="noc">{fmt_minutes(grand['noc_ficto'])}</td><td class="soma">{fmt_minutes(grand['total'])}</td></tr></tfoot>
  </table></div>
</div>"""

def generate_batch_html_file(data_list: List[ExportData]) -> str:
    if not data_list:
        raise ValueError("Nenhum colaborador para exportar.")

    first = data_list[0]
    month_label = export_period_label(first)
    tabs = []
    panels = []
    summaries = []

    for idx, data in enumerate(data_list):
        is_estagiario = "estag" in data.employee_role.lower() or "intern" in data.employee_role.lower()
        panel_id = tab_id(data.employee_name, idx, data.month, data.year, is_estagiario)
        tabs.append(
            f"""<button class="tab-btn {'active' if idx == 0 else ''}" onclick="showTab('{panel_id}')" id="btn-{panel_id}">{esc(abbreviated_name(data.employee_name))}{'<span class="badge estag">Estag.</span>' if is_estagiario else ('<span class="badge diaria">Diária</span>' if data.daily_mode else '')}</button>"""
        )
        panel, summary = build_employee_html(data, panel_id, idx == 0)
        panels.append(panel)
        summaries.append(summary)

    tabs.append("""<button class="tab-btn consolidado" onclick="showTab('consolidado')" id="btn-consolidado">&#9776; Consolidado</button>""")
    panels.append(build_consolidated_html(summaries, month_label))

    content = f"""<!DOCTYPE html>
<html lang="pt-BR">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Folhas de Ponto - VM Engenharia - {esc(month_label)}</title>
<style>{HTML_STYLE}</style>
</head>
<body>
<header>
  <h1>VM Engenharia de Infraestruturas Ltda - CNPJ: 53.655.381/0001-03</h1>
  <p>Folhas de Ponto - {esc(month_label)} - gerado em {_local_now().strftime('%d/%m/%Y %H:%M')}</p>
</header>
<div class="legend" style="padding:.7rem 1rem;background:#fff;border-bottom:1px solid #dde">
  HN <=8h/dia &nbsp;|&nbsp; HE 50% &nbsp;|&nbsp; HE 100% &nbsp;|&nbsp;
  Ad. Noturno 22h-05h &nbsp;|&nbsp; Dom.+Feriado = +100%
</div>
<div class="tabs-wrap">{''.join(tabs)}</div>
<div class="content">{''.join(panels)}</div>
<script>
function showTab(id){{
  document.querySelectorAll('.tab-panel').forEach(p=>p.style.display='none');
  document.querySelectorAll('.tab-btn').forEach(b=>b.classList.remove('active'));
  document.getElementById('panel-'+id).style.display='block';
  document.getElementById('btn-'+id).classList.add('active');
}}
</script>
</body>
</html>"""

    tmp = tempfile.NamedTemporaryFile(delete=False, suffix=".html", mode="w", encoding="utf-8")
    tmp.write(content)
    tmp.close()
    return tmp.name

def _remove_after_send(path: str, whole_dir: bool = False) -> BackgroundTask:
    """Apaga o arquivo gerado (ou a pasta temporaria dele) depois que a
    resposta foi enviada. Sem isso cada folha, lote ou relatorio exportado
    ficava no /tmp do container para sempre, enchendo o disco do servidor."""
    def remove():
        if whole_dir:
            shutil.rmtree(os.path.dirname(path), ignore_errors=True)
            return
        try:
            os.unlink(path)
        except OSError:
            pass
    return BackgroundTask(remove)

@app.post("/export-excel")
def export_excel(
    data: ExportData,
    user=Depends(require_authenticated_user),
):
    try:
        file_path = generate_excel_file(data)
        return FileResponse(
            file_path,
            filename=excel_download_filename(data),
            media_type="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
            background=_remove_after_send(file_path),
        )
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

@app.post("/export-batch")
def export_batch(
    data_list: List[ExportData],
    user=Depends(require_authenticated_user),
):
    try:
        temp_dir = tempfile.mkdtemp()
        zip_path = os.path.join(temp_dir, "folhas_ponto.zip")
        with zipfile.ZipFile(zip_path, 'w') as zipf:
            for data in data_list:
                file_path = generate_excel_file(data)
                zipf.write(file_path, arcname=excel_download_filename(data))
                os.unlink(file_path)
        return FileResponse(
            zip_path,
            filename="Folhas_Ponto_Lote.zip",
            media_type="application/zip",
            background=_remove_after_send(zip_path, whole_dir=True),
        )
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

@app.post("/export-batch-html")
def export_batch_html(
    data_list: List[ExportData],
    user=Depends(require_authenticated_user),
):
    try:
        file_path = generate_batch_html_file(data_list)
        first = data_list[0]
        return FileResponse(
            file_path,
            filename=f"Folhas_Ponto_VM_{first.month}-{first.year}.html",
            media_type="text/html; charset=utf-8",
            background=_remove_after_send(file_path),
        )
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

@app.post("/send-assistant-message")
async def send_assistant_message(
    employee_name: str = Form(...),
    employee_email: str = Form(...),
    message: str = Form(...),
    audio: Optional[UploadFile] = File(None),
    user=Depends(require_authenticated_user),
):
    try:
        body = f"""
        Solicitação de Ajuste de Ponto - Assistente VMac

        Colaborador: {employee_name}
        E-mail: {employee_email}
        Data/Hora: {_local_now().strftime('%d/%m/%Y %H:%M')}

        Mensagem:
        {message}
        """

        message_schema = MessageSchema(
            subject=f"Ajuste de Ponto - {employee_name}",
            recipients=["vmac.rh.01@gmail.com"],
            body=body,
            subtype=MessageType.plain
        )

        if audio:
            # Salvar áudio temporariamente para anexar
            temp = tempfile.NamedTemporaryFile(delete=False, suffix=".m4a")
            content = await audio.read()
            temp.write(content)
            temp.close()
            message_schema.attachments = [temp.name]

        fm = FastMail(conf)
        await fm.send_message(message_schema)

        if audio:
            os.unlink(temp.name)

        return {"status": "success", "message": "E-mail enviado com sucesso"}
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Erro ao enviar e-mail: {str(e)}")

@app.post("/admin/signature-documents")
async def create_signature_document(
    target_user_id: str = Form(...),
    target_user_name: str = Form(...),
    target_user_email: str = Form(...),
    local_document_id: str = Form(...),
    title: str = Form(...),
    message: str = Form(""),
    pdf: UploadFile = File(...),
    admin=Depends(require_admin_user),
):
    if not title.strip():
        raise HTTPException(status_code=400, detail="Informe o titulo do documento.")

    file_name = pdf.filename or "documento.pdf"
    if not file_name.lower().endswith(".pdf"):
        raise HTTPException(status_code=400, detail="Envie um arquivo PDF.")

    pdf_bytes = await pdf.read()
    if not pdf_bytes or not pdf_bytes.startswith(b"%PDF"):
        raise HTTPException(status_code=400, detail="O arquivo enviado nao e um PDF valido.")
    if len(pdf_bytes) > 10 * 1024 * 1024:
        raise HTTPException(status_code=400, detail="O PDF deve ter no maximo 10 MB.")

    target_name = target_user_name.strip()
    target_email = target_user_email.strip()
    if not target_name:
        raise HTTPException(status_code=400, detail="Informe o nome do colaborador.")
    if not target_email:
        raise HTTPException(status_code=400, detail="O colaborador precisa ter um e-mail cadastrado.")

    now = datetime.utcnow().isoformat() + "Z"
    with signature_db_connection() as connection:
        connection.execute(
            """
            INSERT INTO signature_documents (
                id, user_id, user_name, user_email, title, message,
                original_file_name, status, created_by_id, created_by_name,
                created_by_email, created_at, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                local_document_id, target_user_id, target_name, target_email,
                title.strip(), message.strip(), file_name, "creating",
                admin["id"], admin.get("name", ""), admin.get("email", ""),
                now, now,
            ),
        )

    payload = {
        "name": title.strip()[:255],
        "base64_pdf": base64.b64encode(pdf_bytes).decode("ascii"),
        "lang": "pt-br",
        "external_id": local_document_id,
        "folder_path": "/Ponto-VMac/",
        "disable_signer_emails": False,
        "allow_refuse_signature": True,
        "signers": [{
            "name": target_name,
            "email": target_email,
            "auth_mode": "assinaturaTela-tokenEmail",
            "send_automatic_email": True,
            "lock_name": True,
            "lock_email": True,
            "external_id": target_user_id,
        }],
    }

    try:
        result = await zapsign_request("POST", "/docs/", payload)
        update_signature_document(local_document_id, {
            **zapsign_document_fields(result),
            "updated_at": datetime.utcnow().isoformat() + "Z",
        })
    except HTTPException as exc:
        update_signature_document(local_document_id, {
            "status": "error",
            "error_message": str(exc.detail),
            "updated_at": datetime.utcnow().isoformat() + "Z",
        })
        raise

    document = get_signature_document(local_document_id)
    create_signature_notification(
        target_user_id,
        "Documento aguardando assinatura",
        f"RH enviou \"{title.strip()}\" para sua assinatura.",
        local_document_id,
    )
    send_document_push_notification(
        target_user_id,
        "Documento aguardando assinatura",
        f"RH enviou \"{title.strip()}\" para sua assinatura.",
        local_document_id,
    )
    return document

@app.get("/signature-notifications")
def list_signature_notifications(user=Depends(require_authenticated_user)):
    with signature_db_connection() as connection:
        rows = connection.execute(
            """
            SELECT id, title, body, document_id, is_read, created_at
            FROM signature_notifications
            WHERE user_id = ?
            ORDER BY created_at DESC
            LIMIT 30
            """,
            (user["id"],),
        ).fetchall()
    return [dict(row) for row in rows]

@app.post("/signature-notifications/read")
def mark_signature_notifications_read(user=Depends(require_authenticated_user)):
    with signature_db_connection() as connection:
        connection.execute(
            "UPDATE signature_notifications SET is_read = 1 WHERE user_id = ? AND is_read = 0",
            (user["id"],),
        )
    return {"status": "success"}

@app.get("/signature-documents")
def list_my_signature_documents(user=Depends(require_authenticated_user)):
    with signature_db_connection() as connection:
        rows = connection.execute(
            f"""
            SELECT {SIGNATURE_DOCUMENT_COLUMNS}
            FROM signature_documents
            WHERE user_id = ?
            ORDER BY created_at DESC
            """,
            (user["id"],),
        ).fetchall()
    return [dict(row) for row in rows]

@app.get("/admin/signature-documents")
def list_all_signature_documents(admin=Depends(require_admin_user)):
    with signature_db_connection() as connection:
        rows = connection.execute(
            f"""
            SELECT {SIGNATURE_DOCUMENT_COLUMNS}
            FROM signature_documents
            ORDER BY created_at DESC
            """
        ).fetchall()
    return [dict(row) for row in rows]

@app.post("/signature-documents/{document_id}/refresh")
async def refresh_signature_document(
    document_id: str,
    user=Depends(require_authenticated_user),
):
    data = get_signature_document(document_id)
    if data is None:
        raise HTTPException(status_code=404, detail="Documento nao encontrado.")

    is_admin = user.get("role") in ["admin", "manager"]
    if data.get("user_id") != user["id"] and not is_admin:
        raise HTTPException(status_code=403, detail="Sem acesso a este documento.")

    document_token = data.get("zapsign_document_token")
    if not document_token:
        raise HTTPException(status_code=409, detail="Documento ainda nao foi criado na ZapSign.")

    result = await zapsign_request("GET", f"/docs/{document_token}/")
    previous_status = data.get("status", "")
    update_signature_document(document_id, {
        **zapsign_document_fields(result),
        "updated_at": datetime.utcnow().isoformat() + "Z",
    })
    updated_document = get_signature_document(document_id)
    create_signed_notification_if_needed(
        updated_document, previous_status, updated_document.get("status", ""),
    )
    return updated_document

@app.delete("/admin/signature-documents/{document_id}")
def delete_signature_document(
    document_id: str,
    admin=Depends(require_admin_user),
):
    data = get_signature_document(document_id)
    if data is None:
        raise HTTPException(status_code=404, detail="Documento nao encontrado.")

    with signature_db_connection() as connection:
        connection.execute(
            "DELETE FROM signature_notifications WHERE document_id = ?",
            (document_id,),
        )
        connection.execute(
            "DELETE FROM signature_documents WHERE id = ?",
            (document_id,),
        )

    return {"status": "success"}

@app.post("/zapsign/webhook")
async def zapsign_webhook(request: Request):
    # Fechado sem segredo configurado (antes ficava aberto): a assinatura da folha passou para o VDRod (17/10/2026).
    if not ZAPSIGN_WEBHOOK_SECRET:
        raise HTTPException(status_code=404, detail="Webhook desativado.")
    supplied_secret = (
        request.headers.get("X-Webhook-Secret")
        or request.query_params.get("secret")
        or ""
    )
    if not hmac.compare_digest(supplied_secret.encode(), ZAPSIGN_WEBHOOK_SECRET.encode()):
        raise HTTPException(status_code=401, detail="Webhook nao autorizado.")

    payload = await request.json()
    external_id = str(payload.get("external_id") or "")
    document_token = str(payload.get("token") or "")
    document_id = external_id if external_id and get_signature_document(external_id) else None
    if document_id is None and document_token:
        document_id = find_signature_document_id(document_token)

    if document_id is None:
        return {"status": "ignored", "reason": "document_not_found"}

    document = get_signature_document(document_id)
    previous_status = document.get("status", "") if document else ""
    update_signature_document(document_id, {
        **zapsign_document_fields(payload),
        "webhook_event": payload.get("event_type") or payload.get("event") or "",
        "updated_at": datetime.utcnow().isoformat() + "Z",
    })
    updated_document = get_signature_document(document_id)
    create_signed_notification_if_needed(
        updated_document, previous_status, updated_document.get("status", ""),
    )
    return {"status": "success"}

_DAY_KEY_RE = re.compile(r"\d{4}-\d{2}-\d{2}")
# Mesmo limite da busca de turno aberto (_user_records_sorted).
_SHIFT_DAY_MAX_AGE_DAYS = 14

def _parse_shift_day(value: Optional[str], today: date) -> Optional[date]:
    """Dia em que o turno aberto comecou, informado pelo app; None se invalido."""
    text = (value or "").strip()
    if not _DAY_KEY_RE.fullmatch(text):
        return None
    try:
        parsed = date.fromisoformat(text)
    except ValueError:
        return None
    if today - timedelta(days=_SHIFT_DAY_MAX_AGE_DAYS) <= parsed <= today:
        return parsed
    return None

@app.get("/work-schedule/effective")
def get_effective_work_schedule_endpoint(
    shift_day: Optional[str] = None,
    user=Depends(require_authenticated_user),
):
    db = get_firestore_admin()
    schedule = _resolve_effective_work_schedule(db, user)
    timezone_name = schedule["timezone"]
    now = datetime.now(ZoneInfo(timezone_name))
    day_key = now.date().isoformat()
    # O pedido de hora extra e guardado pelo dia em que o turno comecou: num
    # turno que virou a meia-noite, procurar por "hoje" nao acharia a
    # liberacao. A entrada (start_request) continua sendo a de hoje.
    overtime_day = _parse_shift_day(shift_day, now.date()) or now.date()
    overtime = _find_schedule_request(
        db,
        user["id"],
        "overtime",
        overtime_day.isoformat(),
        {"pending", "approved", "rejected"},
    )
    start_request = _find_schedule_request(
        db,
        user["id"],
        "start_exception",
        day_key,
        {"pending", "approved", "rejected"},
    )
    return {
        "schedule": schedule,
        "source": "user_override"
        if user.get("work_schedule_override_enabled") is True
        else "global",
        "server_now": now.isoformat(),
        "overtime_request": _approval_dict(overtime) if overtime else None,
        "start_request": _approval_dict(start_request) if start_request else None,
    }

@app.get("/admin/work-schedule/settings")
def get_global_work_schedule_endpoint(admin=Depends(require_admin_user)):
    db = get_firestore_admin()
    settings_doc = db.collection("work_schedule_settings").document("intern_default").get()
    return _validate_work_schedule(settings_doc.to_dict() if settings_doc.exists else None)

@app.put("/admin/work-schedule/settings")
def update_global_work_schedule_endpoint(
    payload: WorkScheduleConfigRequest,
    admin=Depends(require_admin_user),
):
    if admin.get("role") != "admin":
        raise HTTPException(status_code=403, detail="Apenas admin pode alterar o horario global.")
    schedule = _validate_work_schedule(payload.model_dump())
    db = get_firestore_admin()
    ref = db.collection("work_schedule_settings").document("intern_default")
    previous = ref.get()
    ref.set({
        **schedule,
        "updated_at": firestore.SERVER_TIMESTAMP,
        "updated_by_id": admin["id"],
        "updated_by_name": admin.get("name", ""),
    })
    db.collection("system_audits").document().set({
        "action": "update_global_intern_schedule",
        "admin_id": admin["id"],
        "admin_name": admin.get("name", ""),
        "before": previous.to_dict() if previous.exists else DEFAULT_INTERN_WORK_SCHEDULE,
        "after": schedule,
        "created_at": firestore.SERVER_TIMESTAMP,
    })
    return schedule

# Id de documento aceito do app: so caracteres seguros para o Firestore.
_CLIENT_RECORD_ID_RE = re.compile(r"[A-Za-z0-9_-]{8,64}")
_OFFLINE_MAX_AHEAD = timedelta(minutes=15)
_OFFLINE_MAX_DELAY = timedelta(days=7)

@app.post("/work-schedule/punch")
def schedule_controlled_punch_endpoint(
    payload: SchedulePunchRequest,
    user=Depends(require_authenticated_user),
):
    allowed_types = {"check_in", "check_out"}
    if payload.record_type not in allowed_types:
        raise HTTPException(status_code=400, detail="Tipo de ponto nao suportado neste fluxo.")
    client_record_id = payload.client_record_id
    if client_record_id is not None and not _CLIENT_RECORD_ID_RE.fullmatch(client_record_id):
        raise HTTPException(status_code=400, detail="Identificador do registro invalido.")

    db = get_firestore_admin()
    if client_record_id is not None:
        record_ref = db.collection("time_records").document(client_record_id)
        # Antes de qualquer regra: um reenvio da mesma batida (resposta
        # perdida, fila offline) devolve o que ja foi gravado. Reavaliar
        # recusaria a propria batida ("Ja existe um turno aberto").
        existing = record_ref.get()
        if existing.exists:
            existing_data = serialize_firestore_document(existing)
            if existing_data.get("user_id") != user["id"]:
                raise HTTPException(status_code=409, detail="Identificador do registro ja usado por outro usuario.")
            return {"status": "created", **existing_data}
    else:
        record_ref = db.collection("time_records").document()

    schedule = _resolve_effective_work_schedule(db, user)
    timezone_name = schedule["timezone"]
    attempted = _parse_schedule_datetime(payload.timestamp, timezone_name)
    punched_at = attempted
    server_now = datetime.now(ZoneInfo(timezone_name))
    if payload.close_at_scheduled_end:
        # A hora gravada sera o fim programado, conferido abaixo. So vale para a SAIDA: numa entrada pulava toda a
        # conferencia de horario (entrada num mes ja fechado, ou no futuro travando as proximas batidas).
        if payload.record_type != "check_out":
            raise HTTPException(status_code=400, detail="Fechar no horario programado vale so para a saida.")
    elif payload.offline:
        # Batida feita sem internet: vale a hora do aparelho no momento da
        # batida, que chega aqui horas ou dias depois. Futuro nao (relogio
        # adiantado) e no maximo 7 dias de atraso.
        delay = server_now - attempted
        if delay < -_OFFLINE_MAX_AHEAD or delay > _OFFLINE_MAX_DELAY:
            raise HTTPException(status_code=400, detail="O horario da batida offline esta fora do periodo aceito.")
    elif abs((server_now - attempted).total_seconds()) > 15 * 60:
        raise HTTPException(status_code=400, detail="O horario informado esta muito distante do relogio do servidor.")
    else:
        # Online vale a hora do servidor, nao a do aparelho: com o relogio do celular mexido dava ate 15 min a mais
        # por batida. A do aparelho fica em device_timestamp quando difere (17/10/2026).
        attempted = server_now

    records = _user_records_sorted(db, user["id"])
    if payload.offline:
        # O turno aberto e o do momento da batida: o que veio depois dela
        # (outras batidas ja sincronizadas) nao conta. Na ordem dos pontos,
        # nao pelo texto do horario: o ponto do lote no mesmo minuto vale
        # pelo tipo (_records_before_punch).
        records = _records_before_punch(records, {
            "user_id": user["id"],
            "record_type": payload.record_type,
            "timestamp": _local_iso(attempted),
        })
    open_shift = _open_shift_start(records)
    if payload.record_type == "check_in":
        if open_shift is not None:
            raise HTTPException(status_code=409, detail="Ja existe um turno aberto.")
        if _is_intern_profile(user):
            if not _is_start_within_schedule(attempted, schedule):
                return {
                    "status": "approval_required",
                    "request_type": "start_exception",
                    "reason": (
                        "non_working_day"
                        if attempted.weekday() > 4
                        else "outside_start_window"
                    ),
                    "attempted_at": _local_iso(attempted),
                    "schedule": schedule,
                }
    else:
        if open_shift is None:
            raise HTTPException(status_code=409, detail="Nao existe turno aberto.")
        shift_started = _parse_schedule_datetime(str(open_shift.get("timestamp")), timezone_name)
        scheduled_end = _time_on_day(shift_started.date(), schedule["shift_end"], timezone_name)
        if payload.close_at_scheduled_end:
            if scheduled_end < shift_started:
                raise HTTPException(
                    status_code=409,
                    detail="A entrada ocorreu depois do fim programado; solicite liberacao para continuar e encerre no horario real.",
                )
            # Gravar uma saida no futuro fecharia o turno antes da hora e
            # pagaria minutos nao trabalhados.
            if scheduled_end > server_now:
                raise HTTPException(
                    status_code=409,
                    detail="Ainda nao deu o fim do horario programado. Para sair agora, use Finalizar expediente.",
                )
            attempted = scheduled_end
        elif _is_intern_profile(user):
            overtime_threshold = _time_on_day(shift_started.date(), schedule["overtime_prompt_after"], timezone_name)
            if attempted >= overtime_threshold:
                approval = _find_schedule_request(
                    db,
                    user["id"],
                    "overtime",
                    shift_started.date().isoformat(),
                    {"approved"},
                )
                if approval is None:
                    return {
                        "status": "approval_required",
                        "request_type": "overtime",
                        "attempted_at": _local_iso(attempted),
                        "schedule": schedule,
                    }

    record = {
        "user_id": user["id"],
        "record_type": payload.record_type,
        "location": payload.location or "App",
        "notes": payload.notes,
        "timestamp": _local_iso(attempted),
        "latitude": payload.latitude,
        "longitude": payload.longitude,
        "schedule_controlled": _is_intern_profile(user),
        "schedule_snapshot": schedule if _is_intern_profile(user) else None,
        "created_at": firestore.SERVER_TIMESTAMP,
    }
    if payload.offline:
        record["synced_from_offline"] = True
        record["offline_delay_minutes"] = max(
            0, int((server_now - punched_at).total_seconds() // 60)
        )
    elif not payload.close_at_scheduled_end and abs((server_now - punched_at).total_seconds()) >= 60:
        record["device_timestamp"] = _local_iso(punched_at)
    record_ref.set(record)
    return {"status": "created", "id": record_ref.id, **_response_safe(record)}

class TimeRecordPunchRequest(BaseModel):
    record_type: str
    # Id gerado no aparelho: o reenvio da fila offline devolve o ponto ja
    # gravado em vez de duplicar.
    client_record_id: str
    timestamp: Optional[str] = None
    offline: bool = False
    location: Optional[str] = None
    notes: Optional[str] = None
    latitude: Optional[float] = None
    longitude: Optional[float] = None
    # "forgotten_exit": fecha o turno aberto sem horas (saida 1s depois da
    # entrada; o gestor lanca a hora real). "auto_break_close": fecha a pausa
    # aberta ha 3h+ com 1h de pausa. Nos dois a hora e o id saem do servidor,
    # nao do aparelho. ref_record_id: a entrada (ou a pausa) que a batida fecha.
    kind: Optional[str] = None
    ref_record_id: Optional[str] = None

_PUNCH_TYPES = {"check_in", "check_out", "break_start", "break_end", "entry_3", "exit_3"}
_BREAK_CLOSE_TYPE = {"break_start": "break_end", "entry_3": "exit_3"}
_FORGOTTEN_EXIT_NOTES = "Saida esquecida: o gestor precisa lancar o horario real"

def _forgotten_exit(user_id: str, open_shift: dict, location: Optional[str], notes: Optional[str]) -> tuple:
    """(id, ponto) da saida esquecida que fecha o turno [open_shift] sem horas.
    Id fixo pela entrada: "Esqueci" em dois aparelhos grava a mesma saida."""
    opened = _to_local_naive(str(open_shift.get("timestamp")))
    return f"forgot_{open_shift['id']}", {
        "user_id": user_id,
        "record_type": "check_out",
        "location": location or "App (saida esquecida)",
        "notes": notes or _FORGOTTEN_EXIT_NOTES,
        "timestamp": _local_iso(opened + timedelta(seconds=1)),
        "latitude": None,
        "longitude": None,
        "created_at": firestore.SERVER_TIMESTAMP,
    }

@app.post("/time-records/punch")
def time_record_punch_endpoint(
    payload: TimeRecordPunchRequest,
    user=Depends(require_authenticated_user),
):
    """Batida de quem nao e estagiario (o estagiario usa /work-schedule/punch
    para entrada e saida). Antes o app gravava direto no Firestore com a hora
    do celular, e as regras deixavam qualquer um gravar ponto com qualquer
    horario: retroativo, ou o estagiario pulando o controle de horario."""
    record_type = payload.record_type
    if record_type not in _PUNCH_TYPES:
        raise HTTPException(status_code=400, detail="Tipo de ponto invalido.")
    if not _CLIENT_RECORD_ID_RE.fullmatch(payload.client_record_id or ""):
        raise HTTPException(status_code=400, detail="Identificador do registro invalido.")
    if payload.kind not in (None, "forgotten_exit", "auto_break_close"):
        raise HTTPException(status_code=400, detail="Tipo de batida invalido.")
    if _is_intern_profile(user) and record_type in {"check_in", "check_out"} and payload.kind is None:
        raise HTTPException(status_code=400, detail="Entrada e saida do estagiario seguem o horario controlado.")

    db = get_firestore_admin()
    user_id = user["id"]

    def existing_or_none(doc_id: str) -> Optional[dict]:
        snapshot = db.collection("time_records").document(doc_id).get()
        if not snapshot.exists:
            return None
        data = serialize_firestore_document(snapshot)
        if data.get("user_id") != user_id:
            raise HTTPException(status_code=409, detail="Identificador do registro ja usado por outro usuario.")
        return {"status": "created", **data}

    # Reenvio da mesma batida (resposta perdida, fila offline): vale o gravado.
    already = existing_or_none(payload.client_record_id)
    if already:
        return already

    records = _user_records_sorted(db, user_id)
    server_now = datetime.now(ZoneInfo(_LOCAL_TZ))

    if payload.kind == "auto_break_close":
        break_id = (payload.ref_record_id or "").strip()
        if not break_id or not records or records[-1].get("id") != break_id:
            raise HTTPException(status_code=409, detail="A pausa ja foi encerrada.")
        last = records[-1]
        if last.get("record_type") not in _BREAK_CLOSE_TYPE:
            raise HTTPException(status_code=409, detail="A pausa ja foi encerrada.")
        started = _to_local_naive(str(last.get("timestamp")))
        if started is None or server_now.replace(tzinfo=None) - started < _AUTO_CLOSE_AFTER:
            raise HTTPException(status_code=409, detail="A pausa ainda nao passou de 3 horas.")
        doc_id = f"autoclose_{break_id}"
        # Mesmo id do job do backend que fecha pausas: os dois gravam o mesmo ponto.
        return existing_or_none(doc_id) or _save_punch(db, doc_id, {
            "user_id": user_id,
            "record_type": _BREAK_CLOSE_TYPE[last["record_type"]],
            "timestamp": _local_iso(started + _AUTO_CLOSE_DURATION),
            "location": "Sistema (Auto)",
            "notes": "Retorno automatico (pausa excedeu 3h; ajustado para 1h)",
            "auto_closed": True,
            "created_at": firestore.SERVER_TIMESTAMP,
        })

    if payload.kind == "forgotten_exit":
        if record_type != "check_out":
            raise HTTPException(status_code=400, detail="Saida esquecida vale so para a saida.")
        ref = (payload.ref_record_id or "").strip()
        # "Esqueci" em outro aparelho ja fechou este turno: vale aquela saida.
        if ref and _CLIENT_RECORD_ID_RE.fullmatch(ref):
            done = existing_or_none(f"forgot_{ref}")
            if done:
                return done
        open_shift = _open_shift_start(records)
        if open_shift is None:
            raise HTTPException(status_code=409, detail="Nao existe turno aberto.")
        doc_id, record = _forgotten_exit(user_id, open_shift, payload.location, payload.notes)
        return existing_or_none(doc_id) or _save_punch(db, doc_id, record)

    attempted = _parse_schedule_datetime(payload.timestamp, _LOCAL_TZ)
    punched_at = attempted
    if payload.offline:
        # Sem internet vale a hora do aparelho no momento da batida, como no
        # estagiario: nada no futuro e no maximo 7 dias de atraso.
        delay = server_now - attempted
        if delay < -_OFFLINE_MAX_AHEAD or delay > _OFFLINE_MAX_DELAY:
            raise HTTPException(status_code=400, detail="O horario da batida offline esta fora do periodo aceito.")
        records = _records_before_punch(records, {
            "user_id": user_id, "record_type": record_type, "timestamp": _local_iso(attempted),
        })
    elif abs((server_now - attempted).total_seconds()) > 15 * 60:
        raise HTTPException(status_code=400, detail="O horario informado esta muito distante do relogio do servidor.")
    else:
        # Online vale a hora do servidor, nao a do celular.
        attempted = server_now

    open_shift = _open_shift_start(records)
    if record_type == "check_in" and open_shift is not None:
        if not payload.offline:
            raise HTTPException(status_code=409, detail="Ja existe um turno aberto.")
        # Entrada que estava na fila com um turno velho ainda aberto antes
        # dela: fecha o velho sem horas (era o que o app fazia na sincronizacao),
        # senao o dia pagava as horas entre os dois turnos.
        forgot_id, forgot = _forgotten_exit(
            user_id, open_shift, None,
            "Saida esquecida (fechada na sincronizacao): o gestor precisa lancar o horario real",
        )
        if not existing_or_none(forgot_id):
            _save_punch(db, forgot_id, forgot)
    if record_type == "check_out" and open_shift is None:
        raise HTTPException(status_code=409, detail="Nao existe turno aberto.")

    record = {
        "user_id": user_id,
        "record_type": record_type,
        "location": payload.location or "App",
        "notes": payload.notes,
        "timestamp": _local_iso(attempted),
        "latitude": payload.latitude,
        "longitude": payload.longitude,
        "created_at": firestore.SERVER_TIMESTAMP,
    }
    if payload.offline:
        record["synced_from_offline"] = True
        record["offline_delay_minutes"] = max(0, int((server_now - punched_at).total_seconds() // 60))
    elif abs((server_now - punched_at).total_seconds()) >= 60:
        record["device_timestamp"] = _local_iso(punched_at)
    return _save_punch(db, payload.client_record_id, record)

def _save_punch(db, doc_id: str, record: dict) -> dict:
    db.collection("time_records").document(doc_id).set(record)
    return {"status": "created", "id": doc_id, **_response_safe(record)}

@app.post("/work-schedule/approval-requests")
def create_schedule_approval_request_endpoint(
    payload: ScheduleApprovalCreateRequest,
    user=Depends(require_authenticated_user),
):
    if not _is_intern_profile(user):
        raise HTTPException(status_code=400, detail="Esta autorizacao e exclusiva para estagiarios.")
    if payload.request_type not in {"start_exception", "overtime"}:
        raise HTTPException(status_code=400, detail="Tipo de solicitacao invalido.")
    observation = (payload.notes or "").strip()
    if not observation:
        raise HTTPException(
            status_code=400,
            detail="Informe uma observacao explicando o motivo da solicitacao.",
        )
    if len(observation) > 500:
        raise HTTPException(
            status_code=400,
            detail="A observacao deve ter no maximo 500 caracteres.",
        )

    db = get_firestore_admin()
    schedule = _resolve_effective_work_schedule(db, user)
    timezone_name = schedule["timezone"]
    attempted = _parse_schedule_datetime(payload.attempted_at, timezone_name)
    server_now = datetime.now(ZoneInfo(timezone_name))
    if abs((server_now - attempted).total_seconds()) > 15 * 60:
        raise HTTPException(
            status_code=400,
            detail="O horario da solicitacao esta muito distante do relogio do servidor.",
        )
    day_key = attempted.date().isoformat()
    shift_start_at = payload.shift_start_at
    records: Optional[List[dict]] = None
    open_shift = None
    if payload.request_type == "overtime":
        records = _user_records_sorted(db, user["id"])
        open_shift = _open_shift_start(records)
        if open_shift is not None:
            # Chave = dia em que o turno comecou, o mesmo que a saida consulta.
            # Num turno que vira a meia-noite o dia da tentativa ja e outro, e
            # a liberacao dada pelo gestor nunca seria encontrada.
            shift_started = _parse_schedule_datetime(str(open_shift.get("timestamp")), timezone_name)
            day_key = shift_started.date().isoformat()
            shift_start_at = str(open_shift.get("timestamp"))

    # Pendente do mesmo dia: o novo pedido e repeticao (retry apos timeout,
    # toque duplo) e criaria um irmao eternamente pendente na tela do gestor.
    # Na entrada, so se for da mesma tentativa (_is_start_request_retry): o
    # pedido das 08:00 sem resposta engolia o das 15:00, e liberado as 15:05
    # abria o turno as 08:00 (7h pagas a mais). O antigo vira "superseded".
    # Aprovado so conta enquanto ainda vale para o turno atual: uma segunda
    # entrada fora do horario no mesmo dia, depois de encerrar o primeiro
    # turno, precisa de pedido novo.
    candidates = _find_schedule_requests(
        db, user["id"], payload.request_type, day_key, {"pending", "approved"}
    )
    existing = None
    stale = []
    for item in candidates:
        item_data = item.to_dict() or {}
        if item_data.get("status") != "pending":
            continue
        if payload.request_type == "start_exception" and not _is_start_request_retry(
            _to_local_naive(item_data.get("attempted_at")), attempted.replace(tzinfo=None)
        ):
            stale.append(item)
            continue
        existing = item
        break
    approved = [item for item in candidates if (item.to_dict() or {}).get("status") == "approved"]
    if existing is None and approved:
        if records is None:
            records = _user_records_sorted(db, user["id"])
            open_shift = _open_shift_start(records)
        for item in approved:
            item_data = item.to_dict() or {}
            if payload.request_type == "start_exception":
                still_valid = (
                    open_shift is not None
                    and item_data.get("linked_time_record_id") == open_shift.get("id")
                )
            else:
                # day_key ja e o do turno aberto: mesmo dia = mesmo turno.
                still_valid = open_shift is not None
            if still_valid:
                existing = item
                break
    if existing is not None:
        return {"status": "existing", "request": _approval_dict(existing)}

    if payload.request_type == "start_exception":
        if _is_start_within_schedule(attempted, schedule):
            raise HTTPException(status_code=400, detail="Este horario nao precisa de autorizacao.")

    for item in stale:
        # Sai da lista de pendentes e nao pode mais ser liberado (approve so
        # aceita "pending").
        item.reference.update({
            "status": "superseded",
            "superseded_at": firestore.SERVER_TIMESTAMP,
            "updated_at": firestore.SERVER_TIMESTAMP,
        })

    request_ref = db.collection("work_schedule_approval_requests").document()
    request_data = {
        "user_id": user["id"],
        "user_name": user.get("name") or user.get("email") or user["id"],
        "user_email": user.get("email", ""),
        "request_type": payload.request_type,
        "status": "pending",
        "attempted_at": _local_iso(attempted),
        "shift_start_at": shift_start_at,
        "day_key": day_key,
        "location": payload.location or "App",
        "notes": observation,
        "latitude": payload.latitude,
        "longitude": payload.longitude,
        "schedule_snapshot": schedule,
        "created_at": firestore.SERVER_TIMESTAMP,
        "updated_at": firestore.SERVER_TIMESTAMP,
    }
    # Hora do primeiro pedido substituido, para o gestor ver as duas: se o
    # estagiario pediu de novo enquanto esperava, a chegada real foi a
    # primeira, e o gestor corrige pelo lote.
    previous_attempts = [
        str(data.get("previous_attempted_at") or data.get("attempted_at") or "")
        for data in ((item.to_dict() or {}) for item in stale)
    ]
    previous_attempts = [value for value in previous_attempts if value]
    if previous_attempts:
        request_data["previous_attempted_at"] = min(previous_attempts)
    request_ref.set(request_data)

    title = "Liberacao de horario solicitada"
    kind_label = "entrada fora do horario" if payload.request_type == "start_exception" else "continuacao apos o horario"
    body = (
        f"{request_data['user_name']} solicitou {kind_label} as "
        f"{attempted.strftime('%H:%M:%S')}. Motivo: {observation}"
    )
    managers = db.collection("users").stream()
    for manager in managers:
        manager_data = manager.to_dict() or {}
        if manager_data.get("role") not in {"admin", "manager"}:
            continue
        _create_user_notification(db, manager.id, title, body, "schedule_approval", request_ref.id)
        _send_user_push(manager.id, title, body, {
            "type": "schedule_approval",
            "request_id": request_ref.id,
        })
    return {"status": "created", "request": {"id": request_ref.id, **_response_safe(request_data)}}

@app.get("/admin/work-schedule/approval-requests")
def list_schedule_approval_requests_endpoint(
    status: Optional[str] = None,
    admin=Depends(require_admin_user),
):
    db = get_firestore_admin()
    collection = db.collection("work_schedule_approval_requests")
    # Filtra no Firestore, nao em memoria. A tela de liberacoes e o sininho
    # chamam isto de 15 em 15 / 30 em 30 segundos: ler a colecao inteira a cada
    # chamada, so para descartar quase tudo, era o que torrava a cota diaria de
    # leituras. Com o filtro, "pendentes" costuma custar 0 ou 1 documento.
    query = collection.where("status", "==", status) if status else collection
    requests = []
    for item in query.stream():
        requests.append(_approval_dict(item))
    requests.sort(key=lambda item: str(item.get("created_at") or ""), reverse=True)
    return requests

@app.get("/notifications")
def list_user_notifications_endpoint(user=Depends(require_authenticated_user)):
    db = get_firestore_admin()
    # So as nao lidas: e o unico que o sininho exibe, e a colecao so cresce.
    # Ler o historico inteiro a cada 30s por aba aberta era leitura jogada fora.
    minhas = db.collection("user_notifications").where("user_id", "==", user["id"])
    try:
        snapshots = list(minhas.where("is_read", "==", False).stream())
    except Exception as exc:  # indice ausente: nao vale quebrar o sininho
        print(f"[notifications] filtro de nao lidas indisponivel, lendo tudo: {exc}")
        snapshots = [
            item for item in minhas.stream()
            if (item.to_dict() or {}).get("is_read") is not True
        ]
    notifications = [_approval_dict(item) for item in snapshots]
    notifications.sort(key=lambda item: str(item.get("created_at") or ""), reverse=True)
    return notifications[:100]

@app.post("/notifications/read")
def mark_user_notifications_read_endpoint(user=Depends(require_authenticated_user)):
    db = get_firestore_admin()
    # Le so o que precisa mudar, em vez da caixa inteira do usuario.
    minhas = db.collection("user_notifications").where("user_id", "==", user["id"])
    try:
        snapshots = list(minhas.where("is_read", "==", False).stream())
    except Exception as exc:
        print(f"[notifications] filtro de nao lidas indisponivel, lendo tudo: {exc}")
        snapshots = [
            item for item in minhas.stream()
            if (item.to_dict() or {}).get("is_read") is not True
        ]
    batch = db.batch()
    count = 0
    for item in snapshots:
        batch.update(item.reference, {"is_read": True, "read_at": firestore.SERVER_TIMESTAMP})
        count += 1
    if count:
        batch.commit()
    return {"status": "success", "updated": count}

@app.post("/admin/work-schedule/approval-requests/{request_id}/approve")
def approve_schedule_request_endpoint(
    request_id: str,
    payload: ScheduleApprovalDecisionRequest,
    admin=Depends(require_admin_user),
):
    db = get_firestore_admin()
    request_ref = db.collection("work_schedule_approval_requests").document(request_id)
    snapshot = request_ref.get()
    if not snapshot.exists:
        raise HTTPException(status_code=404, detail="Solicitacao nao encontrada.")
    data = snapshot.to_dict() or {}
    if data.get("status") == "approved":
        return {"status": "approved", "request": _approval_dict(snapshot)}
    if data.get("status") != "pending":
        raise HTTPException(status_code=409, detail="Esta solicitacao ja foi decidida.")

    linked_record_id = data.get("linked_time_record_id")
    if data.get("request_type") == "start_exception":
        records = _user_records_sorted(db, data["user_id"])
        open_shift = _open_shift_start(records)
        # Procura pelo vinculo, nao pelo turno aberto: o ponto pode ter sido
        # gravado por uma tentativa anterior e o turno ja ter sido encerrado.
        existing = _reusable_approval_check_in(records, request_id, data, open_shift)
        timezone_name = (data.get("schedule_snapshot") or {}).get("timezone") or _LOCAL_TZ
        try:
            attempted = _parse_schedule_datetime(data.get("attempted_at") or "", timezone_name)
            now = datetime.now(ZoneInfo(timezone_name))
        except Exception:
            attempted = now = None
        if existing is not None:
            # Reaproveita o ponto que ja existe e so conclui a decisao; criar
            # outro duplicaria a entrada.
            linked_record_id = existing["id"]
        elif now is not None and _start_request_expired(attempted, now):
            # Liberar agora um pedido de muitas horas atras gravaria a entrada
            # na hora dele, abrindo um turno que ja passou; o ponto real
            # desse dia deve ser lancado pelo lote.
            raise HTTPException(
                status_code=409,
                detail="Pedido antigo: a entrada nao foi criada. Rejeite e lance o ponto pelo lote se for o caso.",
            )
        elif _newer_start_attempt(db, request_id, data) is not None:
            # Pedido feito pelo app antigo ou pelo modo compativel, que nao
            # marca o pedido anterior como substituido.
            raise HTTPException(
                status_code=409,
                detail="O estagiario pediu a entrada de novo mais tarde neste dia: libere o pedido mais recente.",
            )
        elif open_shift is not None:
            raise HTTPException(status_code=409, detail="O usuario ja possui um turno aberto.")
        else:
            # Id deterministico: se a liberacao for reenviada, o set() regrava o
            # MESMO documento em vez de criar uma segunda entrada.
            record_ref = db.collection("time_records").document(f"approval_{request_id}")
            record_ref.set({
                "user_id": data["user_id"],
                "record_type": "check_in",
                "location": data.get("location") or "App (aprovado)",
                "notes": data.get("notes") or "Entrada fora do horario aprovada pelo gestor",
                "timestamp": data["attempted_at"],
                "latitude": data.get("latitude"),
                "longitude": data.get("longitude"),
                "schedule_controlled": True,
                "schedule_approval_request_id": request_id,
                "approved_by_id": admin["id"],
                "approved_by_name": admin.get("name", ""),
                "schedule_snapshot": data.get("schedule_snapshot"),
                "created_at": firestore.SERVER_TIMESTAMP,
            })
            linked_record_id = record_ref.id

    request_ref.update({
        "status": "approved",
        "decision_reason": (payload.reason or "").strip(),
        "decided_by_id": admin["id"],
        "decided_by_name": admin.get("name") or admin.get("email") or "Gestor",
        "decided_at": firestore.SERVER_TIMESTAMP,
        "linked_time_record_id": linked_record_id,
        "updated_at": firestore.SERVER_TIMESTAMP,
    })
    title = "Horario liberado"
    body = "Sua entrada foi liberada pelo gestor." if data.get("request_type") == "start_exception" else "A continuacao do expediente foi liberada pelo gestor."
    _create_user_notification(db, data["user_id"], title, body, "schedule_decision", request_id)
    _send_user_push(data["user_id"], title, body, {
        "type": "schedule_decision",
        "request_id": request_id,
        "status": "approved",
    })
    return {"status": "approved", "linked_time_record_id": linked_record_id}

@app.post("/admin/work-schedule/approval-requests/{request_id}/reject")
def reject_schedule_request_endpoint(
    request_id: str,
    payload: ScheduleApprovalDecisionRequest,
    admin=Depends(require_admin_user),
):
    db = get_firestore_admin()
    request_ref = db.collection("work_schedule_approval_requests").document(request_id)
    snapshot = request_ref.get()
    if not snapshot.exists:
        raise HTTPException(status_code=404, detail="Solicitacao nao encontrada.")
    data = snapshot.to_dict() or {}
    if data.get("status") == "rejected":
        return {"status": "rejected", "request": _approval_dict(snapshot)}
    if data.get("status") != "pending":
        raise HTTPException(status_code=409, detail="Esta solicitacao ja foi decidida.")
    request_ref.update({
        "status": "rejected",
        "decision_reason": (payload.reason or "").strip(),
        "decided_by_id": admin["id"],
        "decided_by_name": admin.get("name") or admin.get("email") or "Gestor",
        "decided_at": firestore.SERVER_TIMESTAMP,
        "updated_at": firestore.SERVER_TIMESTAMP,
    })
    title = "Horario nao liberado"
    body = "O gestor nao liberou esta solicitacao de horario."
    _create_user_notification(db, data["user_id"], title, body, "schedule_decision", request_id)
    _send_user_push(data["user_id"], title, body, {
        "type": "schedule_decision",
        "request_id": request_id,
        "status": "rejected",
    })
    return {"status": "rejected"}

# --- MODO DIARIA ---
# Quem esta no modo diaria (users.daily_mode) nao bate entrada e saida: so
# marca que trabalhou no dia. Uma diaria por pessoa por dia: o documento de
# daily_entries tem o id "<uid>_<yyyy-mm-dd>" e e gravado com create(), que
# falha se ele ja existe. Passa so por aqui (Admin SDK): as regras do
# Firestore nao abrem a colecao para o app.

class DailyEntryRequest(BaseModel):
    # Diaria marcada sem internet e enviada depois: vale o dia do aparelho
    # no momento do toque (timestamp), na mesma janela da batida offline.
    timestamp: Optional[str] = None
    offline: bool = False

# Periodo maximo de uma consulta de diarias (um ano e folga).
_DAILY_ENTRIES_MAX_RANGE = timedelta(days=400)

def _daily_entry_id(user_id: str, day: date) -> str:
    return f"{user_id}_{day.isoformat()}"

def _daily_entry_moment(payload: DailyEntryRequest, now: datetime) -> datetime:
    """Hora local da diaria: agora, pelo relogio do servidor; a marcada
    offline vale a hora do toque, de ate 7 dias atras e nao do futuro."""
    if not payload.offline:
        return now
    attempted = _to_local_naive(payload.timestamp)
    if attempted is None:
        raise HTTPException(status_code=400, detail="Informe a hora da diaria offline.")
    delay = now - attempted
    if delay < -_OFFLINE_MAX_AHEAD or delay > _OFFLINE_MAX_DELAY:
        raise HTTPException(status_code=400, detail="A diaria offline esta fora do periodo aceito.")
    return attempted

def _daily_entries_between(db, user_id: str, start: date, end: date) -> List[dict]:
    """Diarias de user_id de start a end (inclusive), em ordem de data. Le
    pelo id do documento ("<uid>_<data>", que ja ordena por data): so o
    periodo, sem indice composto para publicar no Firestore."""
    collection = db.collection("daily_entries")
    query = collection.where(
        "__name__", ">=", collection.document(_daily_entry_id(user_id, start))
    ).where(
        "__name__", "<=", collection.document(_daily_entry_id(user_id, end))
    )
    entries = [serialize_firestore_document(item) for item in query.stream()]
    entries = [entry for entry in entries if entry.get("user_id") == user_id]
    entries.sort(key=lambda entry: str(entry.get("date") or ""))
    return entries

def _parse_day_param(value: str, name: str) -> date:
    try:
        return date.fromisoformat((value or "").strip()[:10])
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=f"Data invalida em {name}.") from exc

@app.post("/daily-entries")
def create_daily_entry_endpoint(
    payload: DailyEntryRequest,
    user=Depends(require_authenticated_user),
):
    if user.get("daily_mode") is not True:
        raise HTTPException(status_code=403, detail="Seu cadastro nao esta no modo diaria.")
    now = _local_now()
    moment = _daily_entry_moment(payload, now)
    day = moment.date()

    db = get_firestore_admin()
    ref = db.collection("daily_entries").document(_daily_entry_id(user["id"], day))
    entry = {
        "user_id": user["id"],
        "user_name": user.get("name", ""),
        "date": day.isoformat(),
        "registered_at": moment.isoformat(),
        "created_by_id": user["id"],
    }
    if payload.offline:
        entry["synced_from_offline"] = True
    try:
        ref.create({**entry, "created_at": firestore.SERVER_TIMESTAMP})
    except AlreadyExists:
        # Segundo toque no dia, outro aparelho ou reenvio da fila offline:
        # a diaria do dia ja esta la e vale a primeira.
        return {"status": "existing", **serialize_firestore_document(ref.get())}
    return {"status": "created", "id": ref.id, **entry}

@app.get("/daily-entries")
def list_daily_entries_endpoint(
    start: str,
    end: str,
    user_id: Optional[str] = None,
    user=Depends(require_authenticated_user),
):
    target_id = (user_id or user["id"]).strip()
    if target_id != user["id"] and user.get("role") not in ("admin", "manager"):
        raise HTTPException(status_code=403, detail="Apenas admin ou manager pode ver diarias de outra pessoa.")
    start_day = _parse_day_param(start, "start")
    end_day = _parse_day_param(end, "end")
    if end_day < start_day or end_day - start_day > _DAILY_ENTRIES_MAX_RANGE:
        raise HTTPException(status_code=400, detail="Periodo de diarias invalido.")
    db = get_firestore_admin()
    return {"entries": _daily_entries_between(db, target_id, start_day, end_day)}

class AdminDailyEntryCreateRequest(BaseModel):
    user_id: str
    date: str
    reason: str

class AdminDailyEntryDeleteRequest(BaseModel):
    reason: str

def _require_reason(value: str) -> str:
    reason = (value or "").strip()
    if not reason:
        raise HTTPException(status_code=400, detail="Informe o motivo.")
    return reason[:500]

def _daily_entry_audit(db, action: str, admin: dict, entry: dict, reason: str) -> None:
    db.collection("system_audits").document().set({
        "action": action,
        "target_user_id": entry.get("user_id"),
        "date": entry.get("date"),
        "reason": reason,
        "entry": entry,
        "admin_id": admin["id"],
        "admin_name": admin.get("name", ""),
        "admin_email": admin.get("email", ""),
        "created_at": firestore.SERVER_TIMESTAMP,
    })

@app.post("/admin/daily-entries")
def admin_create_daily_entry_endpoint(
    payload: AdminDailyEntryCreateRequest,
    admin=Depends(require_admin_user),
):
    """Admin lanca a diaria de um dia (a pessoa esqueceu de marcar). Uma por
    dia, como a da propria pessoa; dia futuro nao."""
    if admin.get("role") != "admin":
        raise HTTPException(status_code=403, detail="Apenas admin pode lancar diarias.")
    reason = _require_reason(payload.reason)
    day = _parse_day_param(payload.date, "date")
    now = _local_now()
    if day > now.date():
        raise HTTPException(status_code=400, detail="Nao da para lancar diaria em dia futuro.")

    db = get_firestore_admin()
    target = db.collection("users").document(payload.user_id.strip()).get()
    if not target.exists:
        raise HTTPException(status_code=404, detail="Usuario nao encontrado.")
    ref = db.collection("daily_entries").document(_daily_entry_id(target.id, day))
    entry = {
        "user_id": target.id,
        "user_name": (target.to_dict() or {}).get("name", ""),
        "date": day.isoformat(),
        "registered_at": now.isoformat(),
        "created_by_id": admin["id"],
        "created_by_name": admin.get("name", ""),
        "created_by_admin": True,
        "admin_reason": reason,
    }
    try:
        ref.create({**entry, "created_at": firestore.SERVER_TIMESTAMP})
    except AlreadyExists:
        raise HTTPException(status_code=409, detail="Ja existe diaria nesse dia.")
    _daily_entry_audit(db, "admin_add_daily_entry", admin, {"id": ref.id, **entry}, reason)
    return {"status": "created", "id": ref.id, **entry}

@app.delete("/admin/daily-entries/{entry_id}")
def admin_delete_daily_entry_endpoint(
    entry_id: str,
    payload: AdminDailyEntryDeleteRequest,
    admin=Depends(require_admin_user),
):
    """Admin apaga uma diaria (marcada por engano). A copia fica na
    auditoria (system_audits)."""
    if admin.get("role") != "admin":
        raise HTTPException(status_code=403, detail="Apenas admin pode apagar diarias.")
    reason = _require_reason(payload.reason)
    db = get_firestore_admin()
    ref = db.collection("daily_entries").document(entry_id)
    snapshot = ref.get()
    if not snapshot.exists:
        raise HTTPException(status_code=404, detail="Diaria nao encontrada.")
    entry = serialize_firestore_document(snapshot)
    ref.delete()
    _daily_entry_audit(db, "admin_delete_daily_entry", admin, entry, reason)
    return {"status": "deleted", "id": entry_id}

# --- ACESSO POR CPF ---
# Quem cadastra e o admin (nao ha mais cadastro pelo app): a pessoa entra com
# o CPF e a senha padrao e, no primeiro acesso, cria a propria senha
# (users.must_change_password). O Firebase Auth exige e-mail: sem um e-mail
# de verdade, a conta usa um interno tirado do CPF (cpf_login_email), que
# nunca recebe mensagem. O login por CPF (/auth/cpf-login) confere a senha e
# devolve o e-mail da conta; o app entra com ele como antes.

# Senha com que as contas eram criadas ate 28/10/2026. Quem sabia o CPF da
# pessoa entrava como ela ate o primeiro acesso. Nao vale mais como senha nova.
LEGACY_DEFAULT_PASSWORD = "123456"

def _temporary_password() -> str:
    """Senha do primeiro acesso: 8 digitos aleatorios, mostrados uma vez ao
    admin para entregar a pessoa, que troca no primeiro acesso
    (must_change_password). Digitos porque e digitada no celular; o limite de
    tentativas por CPF segura a adivinhacao."""
    while True:
        password = f"{secrets.randbelow(10 ** 8):08d}"
        if len(set(password)) > 2:  # nada de 00000000, 11112111...
            return password
CPF_LOGIN_EMAIL_DOMAIN = os.getenv("CPF_LOGIN_EMAIL_DOMAIN", "cpf.ponto.vmacengenharia.com")

def cpf_digits(value) -> str:
    return re.sub(r"\D", "", str(value or ""))

def is_valid_cpf(digits: str) -> bool:
    """CPF de 11 digitos com os dois digitos verificadores certos."""
    if len(digits) != 11 or not digits.isdigit() or digits == digits[0] * 11:
        return False
    for size in (9, 10):
        total = sum(int(digits[i]) * (size + 1 - i) for i in range(size))
        if (total * 10) % 11 % 10 != int(digits[size]):
            return False
    return True

def format_cpf(digits: str) -> str:
    return f"{digits[:3]}.{digits[3:6]}.{digits[6:9]}-{digits[9:]}"

def cpf_login_email(digits: str) -> str:
    return f"{digits}@{CPF_LOGIN_EMAIL_DOMAIN}"

def _login_emails(email: Optional[str], digits: str) -> tuple:
    """(e-mail do cadastro, e-mail da conta no Firebase Auth). Sem e-mail, o
    cadastro fica sem ("") e a conta usa o interno do CPF."""
    email = (email or "").strip().lower()
    if email:
        if "@" not in email:
            raise HTTPException(status_code=400, detail="E-mail invalido.")
        return email, email
    if len(digits) != 11:
        raise HTTPException(status_code=400, detail="Informe o e-mail ou um CPF valido.")
    return "", cpf_login_email(digits)

# Bancos (um so em producao) em que todo cadastro ja tem cpf_digits.
_cpf_digits_backfilled: set = set()

def _backfill_cpf_digits(db) -> None:
    """Uma vez por processo: grava cpf_digits em quem nao tem ou tem velho.
    Sem isso, um CPF repetido num cadastro antigo nao apareceria na busca
    pelo campo e o login nao recusaria o CPF duplicado."""
    for doc in db.collection("users").stream():
        data = doc.to_dict() or {}
        digits = cpf_digits(data.get("cpf"))
        if digits and data.get("cpf_digits") != digits:
            try:
                doc.reference.update({"cpf_digits": digits})
            except Exception as exc:
                logger.warning("Nao deu para gravar cpf_digits de %s: %s", doc.id, exc)
                return  # tenta de novo no proximo login
    _cpf_digits_backfilled.add(id(db))

def _users_with_cpf(db, digits: str, thorough: bool = True) -> List[Any]:
    """Cadastros com este CPF, em qualquer formato gravado (123.456.789-00,
    o 123.456.789.00 do cadastro antigo ou so digitos).

    thorough=False (login): procura pelo campo cpf_digits, uma leitura so.
    Ler a colecao toda a cada login custava uma leitura por pessoa
    cadastrada. O cadastro antigo nao tem o campo: na primeira vez, todos
    ganham (_backfill_cpf_digits). Vale o "cpf" de cada achado (o campo pode
    estar velho) e, sem achado, le a colecao toda como antes.
    thorough=True (cadastro/edicao pelo admin): sempre a colecao toda, para
    nao deixar passar CPF repetido num cadastro sem cpf_digits.
    """
    if not thorough:
        if id(db) not in _cpf_digits_backfilled:
            _backfill_cpf_digits(db)
        indexed = [
            doc for doc in db.collection("users").where("cpf_digits", "==", digits).stream()
            if cpf_digits((doc.to_dict() or {}).get("cpf")) == digits
        ]
        if indexed:
            return indexed
    matches = []
    for doc in db.collection("users").stream():
        data = doc.to_dict() or {}
        if cpf_digits(data.get("cpf")) != digits:
            continue
        matches.append(doc)
        if data.get("cpf_digits") != digits:
            # Acerta o campo para o proximo login achar numa leitura so.
            try:
                doc.reference.update({"cpf_digits": digits})
            except Exception as exc:
                logger.warning("Nao deu para gravar cpf_digits de %s: %s", doc.id, exc)
    return matches

# Tentativas erradas de login por CPF: no maximo 10 em 15 min por CPF e 30
# por IP. O /api/ nao passa pela palavra-chave da empresa. O limite do IP e
# maior porque o Wi-Fi do escritorio sai por um IP so: com 10, um colega
# errando a senha travava o login da equipe toda.
_LOGIN_FAILURE_WINDOW = timedelta(minutes=15)
_LOGIN_MAX_FAILURES = 10
_LOGIN_MAX_FAILURES_PER_IP = 30
_login_failures: Dict[str, List[datetime]] = {}

def _recent_login_failures(key: str, now: datetime) -> List[datetime]:
    recent = [at for at in _login_failures.get(key, []) if now - at < _LOGIN_FAILURE_WINDOW]
    if recent:
        _login_failures[key] = recent
    else:
        _login_failures.pop(key, None)
    return recent

def _login_blocked(keys: List[str], now: datetime) -> bool:
    return any(
        len(_recent_login_failures(key, now))
        >= (_LOGIN_MAX_FAILURES_PER_IP if key.startswith("ip:") else _LOGIN_MAX_FAILURES)
        for key in keys
    )

def _client_ip(request: Request) -> str:
    """IP de quem fez o pedido. Atras do tunel da Cloudflare o nginx so ve o
    cloudflared (127.0.0.1/gateway do Docker): o X-Real-IP era o mesmo para
    todo mundo e 10 senhas erradas de uma pessoa travavam o login de todos.
    O CF-Connecting-IP e o IP real; o backend so escuta no 127.0.0.1 do VPS,
    entao o cabecalho chega da Cloudflare, nao do aparelho."""
    return (
        request.headers.get("cf-connecting-ip")
        or request.headers.get("x-real-ip")
        or (request.client.host if request.client else "")
    )

def _register_login_failure(keys: List[str], now: datetime) -> None:
    for key in keys:
        _login_failures.setdefault(key, []).append(now)

async def _check_firebase_password(email: str, password: str) -> str:
    """Confere a senha da conta no Firebase Auth: 'ok', 'invalid',
    'disabled' ou 'throttled'."""
    if not FIREBASE_WEB_API_KEY:
        raise HTTPException(
            status_code=503,
            detail="Login por CPF indisponivel: configure FIREBASE_WEB_API_KEY no backend.",
        )
    try:
        response = await _http_client().post(
            _google_api("identitytoolkit.googleapis.com", "v1/accounts:signInWithPassword"),
            params={"key": FIREBASE_WEB_API_KEY},
            json={"email": email, "password": password, "returnSecureToken": False},
        )
    except httpx.RequestError as exc:
        raise HTTPException(status_code=502, detail="Falha ao validar o acesso. Tente novamente.") from exc
    if response.is_success:
        return "ok"
    try:
        message = str(response.json().get("error", {}).get("message", ""))
    except ValueError:
        message = ""
    if message.startswith("USER_DISABLED"):
        return "disabled"
    if message.startswith("TOO_MANY_ATTEMPTS"):
        return "throttled"
    return "invalid"

class CpfLoginRequest(BaseModel):
    cpf: str
    password: str

@app.post("/auth/cpf-login")
async def cpf_login_endpoint(payload: CpfLoginRequest, request: Request):
    """Login por CPF: com a senha certa, devolve o e-mail da conta para o app
    entrar no Firebase. CPF desconhecido e senha errada dao a mesma resposta."""
    digits = cpf_digits(payload.cpf)
    client_ip = _client_ip(request)
    keys = [f"ip:{client_ip}", f"cpf:{digits}"]
    now = _local_now()
    if _login_blocked(keys, now):
        raise HTTPException(status_code=429, detail="Muitas tentativas. Aguarde 15 minutos e tente de novo.")
    invalid = HTTPException(status_code=401, detail="CPF ou senha incorretos.")
    if len(digits) != 11 or not payload.password:
        _register_login_failure(keys, now)
        raise invalid

    db = get_firestore_admin()
    matches = await asyncio.to_thread(_users_with_cpf, db, digits, False)
    if len(matches) > 1:
        raise HTTPException(status_code=409, detail="Mais de um cadastro com este CPF. Procure o administrador.")
    if not matches:
        _register_login_failure(keys, now)
        raise invalid
    try:
        email = (await asyncio.to_thread(firebase_auth.get_user, matches[0].id)).email
    except firebase_auth.UserNotFoundError:
        email = None
    if not email:
        _register_login_failure(keys, now)
        raise invalid

    result = await _check_firebase_password(email, payload.password)
    if result == "disabled":
        raise HTTPException(status_code=403, detail="Esta conta foi desativada.")
    if result == "throttled":
        raise HTTPException(status_code=429, detail="Muitas tentativas. Aguarde um pouco e tente de novo.")
    if result != "ok":
        _register_login_failure(keys, now)
        raise invalid
    _login_failures.pop(f"cpf:{digits}", None)
    return {"email": email}

class AdminUserCreateRequest(BaseModel):
    name: str
    cpf: str
    email: Optional[str] = None
    role: str = "employee"
    job_title: Optional[str] = None
    daily_hours: float = 8.0
    daily_mode: bool = False

@app.post("/admin/users")
def create_user_admin_endpoint(
    payload: AdminUserCreateRequest,
    admin=Depends(require_admin_user),
):
    """Admin cadastra a pessoa com a senha padrao; no primeiro acesso ela
    cria a propria (must_change_password)."""
    if admin.get("role") != "admin":
        raise HTTPException(status_code=403, detail="Apenas admin pode cadastrar usuarios.")
    name = payload.name.strip()
    if not name:
        raise HTTPException(status_code=400, detail="Informe o nome.")
    digits = cpf_digits(payload.cpf)
    if not is_valid_cpf(digits):
        raise HTTPException(status_code=400, detail="CPF invalido.")
    role = payload.role.strip()
    if role not in {"admin", "manager", "employee", "intern"}:
        raise HTTPException(status_code=400, detail="Cargo invalido.")
    email, auth_email = _login_emails(payload.email, digits)

    db = get_firestore_admin()
    if _users_with_cpf(db, digits):
        raise HTTPException(status_code=409, detail="Ja existe um cadastro com este CPF.")
    temporary_password = _temporary_password()
    try:
        account = firebase_auth.create_user(
            email=auth_email, password=temporary_password, display_name=name,
        )
    except firebase_auth.EmailAlreadyExistsError as exc:
        raise HTTPException(status_code=409, detail="Este e-mail ja esta em uso.") from exc
    except Exception as exc:
        raise HTTPException(status_code=500, detail=f"Falha ao criar a conta: {exc}") from exc

    is_intern = role == "intern"
    profile = {
        "uid": account.uid,
        "email": email,
        "name": name,
        "cpf": format_cpf(digits),
        "cpf_digits": digits,
        "role": role,
        "job_title": (payload.job_title or "").strip() or ("Estagiario" if is_intern else "Aux. Geral"),
        "daily_hours": payload.daily_hours,
        "daily_mode": payload.daily_mode and role == "employee",
        "disabled": False,
        "must_change_password": True,
        "created_at": firestore.SERVER_TIMESTAMP,
        "created_by_id": admin["id"],
        "created_by_name": admin.get("name", ""),
    }
    try:
        db.collection("users").document(account.uid).set(profile)
    except Exception as exc:
        # Sem o cadastro a conta nao serve: desfaz para o CPF poder ser usado de novo.
        try:
            firebase_auth.delete_user(account.uid)
        except Exception:
            pass
        raise HTTPException(status_code=500, detail=f"Falha ao gravar o cadastro: {exc}") from exc
    db.collection("system_audits").document().set({
        "action": "create_user_admin",
        "target_user_id": account.uid,
        "admin_id": admin["id"],
        "admin_name": admin.get("name", ""),
        "admin_email": admin.get("email", ""),
        "created_at": firestore.SERVER_TIMESTAMP,
    })
    return {
        "status": "created",
        "id": account.uid,
        "cpf": profile["cpf"],
        # "default_password" para o app antigo, que mostrava a senha por esse nome.
        "default_password": temporary_password,
        "temporary_password": temporary_password,
    }

class OwnPasswordChangeRequest(BaseModel):
    new_password: str

@app.post("/me/password")
def change_own_password_endpoint(
    payload: OwnPasswordChangeRequest,
    user=Depends(require_authenticated_user),
):
    """A pessoa troca a propria senha (no primeiro acesso, obrigatorio).
    Pelo Admin SDK: vale mesmo com a sessao antiga, que o updatePassword do
    app recusaria ("login recente")."""
    password = payload.new_password
    if len(password) < 6:
        raise HTTPException(status_code=400, detail="A senha precisa de pelo menos 6 caracteres.")
    if password == LEGACY_DEFAULT_PASSWORD:
        raise HTTPException(status_code=400, detail="Escolha uma senha diferente da senha padrao.")
    cpf = cpf_digits(user.get("cpf"))
    if cpf and password == cpf:
        raise HTTPException(status_code=400, detail="Nao use o CPF como senha.")

    db = get_firestore_admin()
    try:
        firebase_auth.update_user(user["id"], password=password)
    except Exception as exc:
        raise HTTPException(status_code=500, detail=f"Falha ao trocar a senha: {exc}") from exc
    db.collection("users").document(user["id"]).update({
        "must_change_password": False,
        "password_changed_at": firestore.SERVER_TIMESTAMP,
    })
    db.collection("system_audits").document().set({
        "action": "user_changed_password",
        "target_user_id": user["id"],
        "created_at": firestore.SERVER_TIMESTAMP,
    })
    return {"status": "success"}

@app.put("/admin/users/{user_id}")
def update_user_admin_endpoint(
    user_id: str,
    payload: AdminUserUpdateRequest,
    admin=Depends(require_admin_user),
):
    if admin.get("role") != "admin":
        raise HTTPException(status_code=403, detail="Apenas admin pode atualizar usuarios.")

    target_id = user_id.strip()
    if not target_id:
        raise HTTPException(status_code=400, detail="Usuario invalido.")

    allowed_roles = {"admin", "manager", "employee", "intern", "estagiario"}
    role = payload.role.strip()
    if role not in allowed_roles:
        raise HTTPException(status_code=400, detail="Cargo invalido.")

    db = get_firestore_admin()
    user_ref = db.collection("users").document(target_id)
    target_doc = user_ref.get()
    if not target_doc.exists:
        raise HTTPException(status_code=404, detail="Usuario nao encontrado.")

    override = None
    if payload.work_schedule_override_enabled:
        if not payload.work_schedule_override:
            raise HTTPException(status_code=400, detail="Informe o horario individual completo.")
        override = _validate_work_schedule(payload.work_schedule_override)

    new_cpf = cpf_digits(payload.cpf)
    # CPF antigo fora do padrao continua valendo; o novo precisa ser valido e
    # unico, porque e o login.
    if new_cpf and new_cpf != cpf_digits((target_doc.to_dict() or {}).get("cpf")):
        if not is_valid_cpf(new_cpf):
            raise HTTPException(status_code=400, detail="CPF invalido.")
        if any(doc.id != target_id for doc in _users_with_cpf(db, new_cpf)):
            raise HTTPException(status_code=409, detail="Ja existe outro cadastro com este CPF.")
    new_email, auth_email = _login_emails(payload.email, new_cpf)
    new_password = (payload.new_password or "").strip()
    temporary_password = None
    if payload.reset_password:
        # "Gerar senha temporaria" no painel: a pessoa troca no proximo acesso.
        new_password = temporary_password = _temporary_password()
    if new_password == LEGACY_DEFAULT_PASSWORD:
        raise HTTPException(status_code=400, detail="Use \"Gerar senha temporaria\" em vez da senha padrao antiga.")
    if new_password and len(new_password) < 6:
        raise HTTPException(status_code=400, detail="A nova senha deve ter pelo menos 6 caracteres.")

    try:
        auth_update = {
            "email": auth_email,
            "disabled": payload.disabled,
        }
        if new_password:
            auth_update["password"] = new_password
        firebase_auth.update_user(target_id, **auth_update)
    except firebase_auth.EmailAlreadyExistsError as exc:
        raise HTTPException(status_code=409, detail="Este e-mail ja esta em uso.") from exc
    except firebase_auth.UserNotFoundError as exc:
        raise HTTPException(status_code=404, detail="Conta nao encontrada no Firebase Authentication.") from exc
    except Exception as exc:
        raise HTTPException(status_code=500, detail=f"Falha ao atualizar a conta: {str(exc)}") from exc

    update_data = {
        "name": payload.name.strip(),
        "email": new_email,
        "role": role,
        "job_title": payload.job_title.strip(),
        "daily_hours": payload.daily_hours,
        "cpf": format_cpf(new_cpf) if len(new_cpf) == 11 else payload.cpf.strip(),
        "cpf_digits": new_cpf,
        "disabled": payload.disabled,
        "work_schedule_override_enabled": payload.work_schedule_override_enabled,
        "work_schedule_override": override,
        "updated_at": firestore.SERVER_TIMESTAMP,
        "last_admin_update_by_id": admin["id"],
        "last_admin_update_by_name": admin.get("name", ""),
        "last_admin_update_by_email": admin.get("email", ""),
    }
    if new_password:
        # Senha definida pelo admin (a padrao ou outra): no proximo acesso a
        # pessoa cria a propria.
        update_data["must_change_password"] = True
    if payload.daily_mode is not None:
        # Estagiario segue o horario controlado; nao entra no modo diaria.
        update_data["daily_mode"] = payload.daily_mode and role not in {"intern", "estagiario"}
    user_ref.update(update_data)
    if payload.disabled or new_password:
        # Conta desativada ou senha trocada: o token guardado deixa de valer ja.
        _forget_user_tokens(target_id)
    db.collection("system_audits").document().set({
        "action": "update_user_admin",
        "target_user_id": target_id,
        "admin_id": admin["id"],
        "admin_name": admin.get("name", ""),
        "admin_email": admin.get("email", ""),
        "updated_fields": [
            "name", "email", "role", "job_title", "daily_hours", "cpf",
            "disabled", "work_schedule_override_enabled", "work_schedule_override",
            *( ["daily_mode"] if payload.daily_mode is not None else [] ),
            *( ["password"] if new_password else [] ),
        ],
        "password_was_reset": bool(new_password),
        "created_at": firestore.SERVER_TIMESTAMP,
    })
    return {
        "status": "success",
        "id": target_id,
        **({"temporary_password": temporary_password} if temporary_password else {}),
    }

@app.patch("/admin/time-records/{record_id}")
def update_time_record_admin_endpoint(
    record_id: str,
    payload: AdminTimeRecordUpdateRequest,
    admin=Depends(require_admin_user),
):
    if admin.get("role") != "admin":
        raise HTTPException(status_code=403, detail="Apenas admin pode editar registros de ponto.")
    if not payload.reason.strip():
        raise HTTPException(status_code=400, detail="Informe o motivo da edicao.")
    # Mesmo formato dos outros pontos (hora local, sem fuso): um texto qualquer
    # aqui embaralhava a ordem dos pontos e os filtros por periodo, que
    # comparam o texto.
    if not (payload.new_timestamp or "").strip():
        raise HTTPException(status_code=400, detail="Informe o novo horario.")
    new_timestamp = _local_iso(_parse_schedule_datetime(payload.new_timestamp.strip(), _LOCAL_TZ))

    db = get_firestore_admin()
    record_ref = db.collection("time_records").document(record_id)
    audit_ref = db.collection("time_record_audits").document()

    transaction = db.transaction()

    @firestore.transactional
    def update_in_transaction(transaction):
        snapshot = record_ref.get(transaction=transaction)
        if not snapshot.exists:
            raise HTTPException(status_code=404, detail="Registro de ponto nao encontrado.")

        old_data = snapshot.to_dict() or {}
        transaction.update(record_ref, {
            "timestamp": new_timestamp,
            "notes": payload.notes or "",
            "updated_at": firestore.SERVER_TIMESTAMP,
            "edited_by_admin": True,
            "admin_edit_message": "Editado pelo admin",
            "last_admin_edit_reason": payload.reason,
            "last_admin_edit_by_id": admin["id"],
            "last_admin_edit_by_name": admin.get("name") or admin.get("email") or "Admin",
            "last_admin_edit_at": firestore.SERVER_TIMESTAMP,
        })
        transaction.set(audit_ref, {
            "record_id": record_id,
            "record_user_id": old_data.get("user_id"),
            "record_type": old_data.get("record_type"),
            "old_timestamp": old_data.get("timestamp"),
            "new_timestamp": new_timestamp,
            "old_notes": old_data.get("notes"),
            "new_notes": payload.notes or "",
            "reason": payload.reason,
            "admin_id": admin["id"],
            "admin_name": admin.get("name", ""),
            "admin_email": admin.get("email", ""),
            "edited_at": firestore.SERVER_TIMESTAMP,
            "created_at": firestore.SERVER_TIMESTAMP,
        })

    update_in_transaction(transaction)
    return {"status": "success", "id": record_id}

@app.delete("/admin/users/{user_id}")
def delete_user_admin_endpoint(
    user_id: str,
    admin=Depends(require_admin_user),
):
    # require_admin_user aceita gerente; excluir e so do admin, como editar (PUT/PATCH).
    if admin.get("role") != "admin":
        raise HTTPException(status_code=403, detail="Apenas admin pode excluir usuarios.")
    if admin["id"] == user_id:
        raise HTTPException(status_code=400, detail="Voce nao pode excluir a propria conta.")

    db = get_firestore_admin()
    target_doc = db.collection("users").document(user_id).get()
    target_data = target_doc.to_dict() if target_doc.exists else {}

    try:
        firebase_auth.delete_user(user_id)
        _forget_user_tokens(user_id)
        auth_deleted = True
    except firebase_auth.UserNotFoundError:
        auth_deleted = False
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Erro ao excluir usuario do Authentication: {str(e)}")

    try:
        deleted_counts = delete_user_cascade(db, user_id)
        db.collection("system_audits").document().set({
            "action": "delete_user_cascade",
            "deleted_user_id": user_id,
            "deleted_user_email": target_data.get("email"),
            "deleted_user_name": target_data.get("name"),
            "admin_id": admin["id"],
            "admin_name": admin.get("name", ""),
            "admin_email": admin.get("email", ""),
            "auth_deleted": auth_deleted,
            "deleted_counts": deleted_counts,
            "created_at": firestore.SERVER_TIMESTAMP,
        })
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Auth excluido, mas houve erro ao limpar Firestore: {str(e)}")

    return {
        "status": "success",
        "auth_deleted": auth_deleted,
        "deleted_counts": deleted_counts,
    }

if __name__ == "__main__":
    import uvicorn
    # Mesma porta do Docker e do README.
    uvicorn.run("main:app", host="0.0.0.0", port=8000, reload=True)
