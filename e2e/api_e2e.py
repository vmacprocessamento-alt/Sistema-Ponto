"""Teste de ponta a ponta da API: backend real + regras reais do Firestore, no emulador.

    python api_e2e.py   (emulador e backend no ar; ver e2e/README.md)
"""
import time
from datetime import datetime, timedelta

import httpx

import os
API = os.getenv("API_URL", "http://127.0.0.1:8766")
AUTH = "http://127.0.0.1:9099/identitytoolkit.googleapis.com/v1"
FS = "http://127.0.0.1:8085/v1/projects/demo-ponto/databases/(default)/documents"
KEY = {"key": "fake-api-key"}
OWNER = {"Authorization": "Bearer owner"}  # admin do emulador (ignora regras)
c = httpx.Client(timeout=30)
results = []


def check(name, cond, extra=""):
    results.append((name, bool(cond)))
    print(f"[{'OK ' if cond else 'FALHOU'}] {name} {extra}")


def fs_fields(d):
    out = {}
    for k, v in d.items():
        if isinstance(v, bool):
            out[k] = {"booleanValue": v}
        elif isinstance(v, (int, float)):
            out[k] = {"doubleValue": v}
        elif v is None:
            out[k] = {"nullValue": None}
        else:
            out[k] = {"stringValue": str(v)}
    return {"fields": out}


def sign_up(email, pw):
    r = c.post(f"{AUTH}/accounts:signUp", params=KEY, json={"email": email, "password": pw, "returnSecureToken": True})
    r.raise_for_status()
    return r.json()["localId"]


def sign_in(email, pw):
    r = c.post(f"{AUTH}/accounts:signInWithPassword", params=KEY,
               json={"email": email, "password": pw, "returnSecureToken": True})
    return r.json().get("idToken") if r.is_success else None


def bearer(t):
    return {"Authorization": f"Bearer {t}"}


def timed(method, path, **kw):
    t = time.perf_counter()
    r = c.request(method, API + path, **kw)
    return r, (time.perf_counter() - t) * 1000


# limpa o emulador
c.delete("http://127.0.0.1:8085/emulator/v1/projects/demo-ponto/databases/(default)/documents")
c.delete("http://127.0.0.1:9099/emulator/v1/projects/demo-ponto/accounts")

# --- admin semente ---
admin_uid = sign_up("admin@vmac.test", "admin-forte-1")
c.patch(f"{FS}/users/{admin_uid}", headers=OWNER,
        json=fs_fields({"name": "Admin", "role": "admin", "email": "admin@vmac.test", "cpf": ""}))
admin = sign_in("admin@vmac.test", "admin-forte-1")
print("\n== CADASTRO ==")
r, ms = timed("POST", "/admin/users", headers=bearer(admin),
              json={"name": "Joao Campo", "cpf": "529.982.247-25", "role": "employee"})
check("admin cadastra funcionario", r.status_code == 200, f"({ms:.0f} ms) {r.text[:80]}")
emp_uid = r.json().get("id"); emp_pw = r.json().get("temporary_password") or r.json().get("default_password")
r, _ = timed("POST", "/admin/users", headers=bearer(admin), json={"name": "Dup", "cpf": "52998224725"})
check("CPF duplicado recusado (409)", r.status_code == 409)
r, _ = timed("POST", "/admin/users", headers=bearer(admin), json={"name": "X", "cpf": "123.456.789-00"})
check("CPF invalido recusado (400)", r.status_code == 400)
r, _ = timed("POST", "/admin/users", headers=bearer(admin), json={"name": "Est", "cpf": "111.444.777-35", "role": "intern"})
check("admin cadastra estagiario", r.status_code == 200)
intern_uid = r.json().get("id"); intern_pw = r.json().get("temporary_password") or r.json().get("default_password")

print("\n== LOGIN ==")
r, ms = timed("POST", "/auth/cpf-login", json={"cpf": "529.982.247-25", "password": emp_pw})
check("senha do primeiro acesso e a padrao 123456", emp_pw == "123456", f"({emp_pw})")
check("login CPF com senha padrao", r.status_code == 200, f"({ms:.0f} ms)")
emp_email = r.json().get("email")
r, _ = timed("POST", "/auth/cpf-login", json={"cpf": "52998224725", "password": "errada"})
check("senha errada -> 401", r.status_code == 401)
r, _ = timed("POST", "/auth/cpf-login", json={"cpf": "00000000191", "password": "x"})
check("CPF inexistente -> 401 (mesma resposta)", r.status_code == 401)
emp = sign_in(emp_email, emp_pw)
r, _ = timed("GET", "/notifications", headers=bearer(emp))
check("com a senha padrao, a API recusa ate criar a senha (403)", r.status_code == 403,
      f"-> {r.status_code} {r.headers.get('x-password-change-required')}")
check("   ...com o cabecalho X-Password-Change-Required", r.headers.get("x-password-change-required") == "1")
r, _ = timed("POST", "/time-records/punch", headers=bearer(emp), json={"record_type": "check_in"})
check("nem bate ponto com a senha padrao (403)", r.status_code == 403)
r, _ = timed("POST", "/admin/users", headers=bearer(emp), json={"name": "Hack", "cpf": "39053344705"})
check("funcionario NAO cadastra usuario (403)", r.status_code == 403)

print("\n== TROCA DE SENHA (primeiro acesso) ==")
r, _ = timed("POST", "/me/password", headers=bearer(emp), json={"new_password": "123456"})
check("recusa a senha padrao", r.status_code == 400)
r, _ = timed("POST", "/me/password", headers=bearer(emp), json={"new_password": "52998224725"})
check("recusa o CPF como senha", r.status_code == 400)
r, _ = timed("POST", "/me/password", headers=bearer(emp), json={"new_password": "senha-inicial-9"})
check("troca a senha (primeiro acesso, sem pedir a atual)", r.status_code == 200)
check("senha nova entra", sign_in(emp_email, "senha-inicial-9") is not None)
check("senha antiga nao entra mais", sign_in(emp_email, emp_pw) is None)
emp = sign_in(emp_email, "senha-inicial-9")
r, _ = timed("GET", "/notifications", headers=bearer(emp))
check("depois de criar a senha, o token do funcionario e aceito", r.status_code == 200)

print("\n== TROCA DE SENHA (depois do primeiro acesso) ==")
r, _ = timed("POST", "/me/password", headers=bearer(emp), json={"new_password": "nova-senha-9"})
check("sem a senha atual -> 400", r.status_code == 400, r.text[:80])
r, _ = timed("POST", "/me/password", headers=bearer(emp),
             json={"new_password": "nova-senha-9", "current_password": "errada"})
check("senha atual errada -> 400", r.status_code == 400, r.text[:80])
r, _ = timed("POST", "/me/password", headers=bearer(emp),
             json={"new_password": "nova-senha-9", "current_password": "senha-inicial-9"})
check("com a senha atual certa, troca", r.status_code == 200, r.text[:80])
check("senha nova entra", sign_in(emp_email, "nova-senha-9") is not None)
emp = sign_in(emp_email, "nova-senha-9")

print("\n== CONTA DESATIVADA ==")
r, _ = timed("PUT", f"/admin/users/{intern_uid}", headers=bearer(admin), json={
    "name": "Est", "email": "", "role": "intern", "job_title": "Estagiario", "daily_hours": 6,
    "cpf": "111.444.777-35", "disabled": True})
check("admin desativa conta", r.status_code == 200, r.text[:80])
r, _ = timed("POST", "/auth/cpf-login", json={"cpf": "11144477735", "password": intern_pw})
check("conta desativada nao entra (403)", r.status_code == 403, f"-> {r.status_code}")
r, _ = timed("PUT", f"/admin/users/{intern_uid}", headers=bearer(admin), json={
    "name": "Est", "email": "", "role": "intern", "job_title": "Estagiario", "daily_hours": 6,
    "cpf": "111.444.777-35", "disabled": False})
intern_email = timed("POST", "/auth/cpf-login", json={"cpf": "11144477735", "password": intern_pw})[0].json()["email"]
intern = sign_in(intern_email, intern_pw)
# Estagiario tambem precisa criar a senha antes de usar a API.
r, _ = timed("POST", "/me/password", headers=bearer(intern), json={"new_password": "senha-est-9"})
check("estagiario cria a senha do primeiro acesso", r.status_code == 200, r.text[:80])
intern = sign_in(intern_email, "senha-est-9")

print("\n== PONTO DO ESTAGIARIO (backend) ==")
now = datetime.now().isoformat()
r, ms = timed("POST", "/work-schedule/punch", headers=bearer(intern), json={"record_type": "check_in", "timestamp": now})
st = r.json().get("status") if r.status_code == 200 else None
check("BACKEND: batida do estagiario responde sem erro", r.status_code == 200, f"({ms:.0f} ms) HTTP {r.status_code} status={st}")
recs = c.get(f"{FS}/time_records", headers=OWNER).json().get("documents", [])
check("   ...mas a batida FOI gravada mesmo com o erro", len(recs) == 1, f"({len(recs)} registro no banco)")
r, ms = timed("POST", "/work-schedule/approval-requests", headers=bearer(intern), json={
    "request_type": "overtime", "attempted_at": now, "notes": "Fechamento de obra"})
check("BACKEND: pedido de liberacao responde sem erro", r.status_code == 200, f"({ms:.0f} ms) HTTP {r.status_code}")
reqs = c.get(f"{FS}/work_schedule_approval_requests", headers=OWNER).json().get("documents", [])
nots = c.get(f"{FS}/user_notifications", headers=OWNER).json().get("documents", [])
check("   ...mas o pedido FOI gravado e o gestor avisado", len(reqs) == 1 and len(nots) >= 1, f"({len(reqs)} pedido, {len(nots)} aviso)")
r, ms = timed("GET", "/work-schedule/effective", headers=bearer(intern))
check("horario efetivo", r.status_code == 200, f"({ms:.0f} ms)")

print("\n== REGRAS DO FIRESTORE (gravando direto, como o app faz) ==")
def direct_record(token, uid, ts, doc_id):
    body = fs_fields({"user_id": uid, "record_type": "check_in", "timestamp": ts, "location": "App"})
    # created_at = hora do servidor (o que a regra exige)
    return c.post(f"{FS}:commit", headers=bearer(token), json={"writes": [{
        "update": {"name": f"projects/demo-ponto/databases/(default)/documents/time_records/{doc_id}", **body},
        "updateTransforms": [{"fieldPath": "created_at", "setToServerValue": "REQUEST_TIME"}],
        "currentDocument": {"exists": False}}]})

past = (datetime.now() - timedelta(days=5)).replace(hour=7).isoformat()
r = direct_record(emp, emp_uid, past, "fraude_passado")
check("SEGURANCA: funcionario grava ponto RETROATIVO de 5 dias direto no banco", r.status_code != 200,
      f"-> HTTP {r.status_code} ({'ACEITO = falha de seguranca' if r.status_code == 200 else 'bloqueado'})")
r = direct_record(intern, intern_uid, (datetime.now().replace(hour=6)).isoformat(), "fraude_estag")
check("SEGURANCA: estagiario pula o controle de horario gravando direto", r.status_code != 200,
      f"-> HTTP {r.status_code} ({'ACEITO = falha de seguranca' if r.status_code == 200 else 'bloqueado'})")
r = direct_record(emp, intern_uid, now, "fraude_outro")
check("funcionario NAO grava ponto em nome de outro", r.status_code != 200, f"-> HTTP {r.status_code}")
r = c.patch(f"{FS}/users/{emp_uid}", headers=bearer(emp), params={"updateMask.fieldPaths": "role"},
            json=fs_fields({"role": "admin"}))
check("funcionario NAO vira admin sozinho", r.status_code != 200, f"-> HTTP {r.status_code}")
r = c.get(f"{FS}/users/{admin_uid}", headers=bearer(emp))
check("funcionario NAO le cadastro de outro", r.status_code != 200, f"-> HTTP {r.status_code}")

print("\n== BATIDA DO FUNCIONARIO PELO BACKEND (/time-records/punch) ==")
def punch(token, tipo, ts=None, cid=None, **extra):
    import uuid
    body = {"record_type": tipo, "client_record_id": cid or uuid.uuid4().hex[:20],
            "timestamp": ts or datetime.now().isoformat(), **extra}
    return timed("POST", "/time-records/punch", headers=bearer(token), json=body)
r, ms = punch(emp, "check_in")
check("funcionario bate entrada pelo backend", r.status_code == 200, f"({ms:.0f} ms) {r.text[:60]}")
r, _ = punch(emp, "check_in")
check("segunda entrada com turno aberto recusada (409)", r.status_code == 409)
r, _ = punch(emp, "break_start")
check("inicio da pausa", r.status_code == 200)
r, _ = punch(emp, "break_end", ts=past)
check("batida online com hora de 5 dias atras recusada (400)", r.status_code == 400)
r, _ = punch(emp, "break_end", ts=(datetime.now() - timedelta(days=2)).isoformat(), offline=True)
check("batida offline de 2 dias aceita e marcada", r.status_code == 200 and r.json().get("synced_from_offline") is True)
r, _ = punch(emp, "check_out")
check("saida", r.status_code == 200)

print("\n== BLOQUEIO DE LOGIN (todos pelo mesmo IP do tunel) ==")
for _ in range(10):
    c.post(API + "/auth/cpf-login", json={"cpf": "11144477735", "password": "chute"}, headers={"X-Real-IP": "172.18.0.1"})
r = c.post(API + "/auth/cpf-login", json={"cpf": "52998224725", "password": "nova-senha-9"}, headers={"X-Real-IP": "172.18.0.1"})
check("outra pessoa com senha CERTA ainda entra", r.status_code == 200, f"-> HTTP {r.status_code} {r.json().get('detail', '')}")

print("\n== TEMPO SO DO CODIGO (emulador local, rede ~0) ==")
for path in ("/notifications", "/work-schedule/effective"):
    lat = sorted(timed("GET", path, headers=bearer(intern))[1] for _ in range(10))
    print(f"   {path:28} mediana {lat[5]:6.0f} ms")
lat = []
for i in range(5):
    t = time.perf_counter(); c.post(API + "/auth/cpf-login", json={"cpf": "52998224725", "password": "nova-senha-9"}, headers={"X-Real-IP": f"10.0.0.{i}"}); lat.append((time.perf_counter() - t) * 1000)
print(f"   {'/auth/cpf-login':28} mediana {sorted(lat)[2]:6.0f} ms")

ok = sum(1 for _, v in results if v)
print(f"\nRESULTADO: {ok}/{len(results)} verificacoes passaram")
