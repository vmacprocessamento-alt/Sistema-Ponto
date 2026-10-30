"""Correcao pontual: ajusta o ponto do Guilherme em 29/10/2026 no app (Firestore).

Roda DENTRO do container do backend (que tem a service-account), reusando o endpoint ja auditado:

    cd /opt/ponto
    docker compose exec -T backend python - < corrigir_guilherme.py

Acha o Guilherme pelo nome (para sem gravar se nao achar exatamente 1), imprime o backup das batidas
de 29/10 e aplica entrada 07:30 / pausa 12:30 / volta 13:30 / saida 18:30. Pode apagar este arquivo depois.
"""
import json

import main

MOTIVO = "Ponto batido errado em 29/10; ajustado conforme o turno do Crysnamurt, mesma equipe."
DIA = "2026-10-29"

db = main.get_firestore_admin()
usuarios = [(d.id, (d.to_dict() or {}).get("name", "")) for d in db.collection("users").stream()]
cand = [u for u in usuarios if "guilherme" in u[1].lower()]
print("Candidatos:", cand)
assert len(cand) == 1, "Esperava exatamente 1 Guilherme; abortando sem gravar."
uid, nome = cand[0]

atuais = [d.to_dict() for d in db.collection("time_records").where("user_id", "==", uid).stream()]
antes = sorted([r for r in atuais if str(r.get("timestamp", "")).startswith(DIA)],
               key=lambda r: str(r.get("timestamp")))
print(f"BACKUP {DIA} (antes):")
print(json.dumps(antes, ensure_ascii=False, default=str, indent=2))

req = main.AdminSetDayRequest(
    user_id=uid,
    date=DIA,
    reason=MOTIVO,
    punches=[
        main.AdminSetDayPunch(record_type="check_in", time="07:30"),
        main.AdminSetDayPunch(record_type="break_start", time="12:30"),
        main.AdminSetDayPunch(record_type="break_end", time="13:30"),
        main.AdminSetDayPunch(record_type="check_out", time="18:30"),
    ],
)
res = main.admin_set_day_time_records_endpoint(
    req, admin={"id": "vdrod-assistente", "name": "Assistente VDRod", "email": "", "role": "admin"}
)
print("RESULTADO:", res)
