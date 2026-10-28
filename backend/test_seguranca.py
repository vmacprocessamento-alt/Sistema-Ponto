"""Correcoes de seguranca de 17/10/2026: hora da batida online, fechar no horario programado so na saida, exclusao de
usuario so pelo admin (sem apagar auditorias) e webhook da ZapSign fechado sem segredo.

    python -m unittest test_seguranca
"""
import asyncio
import types
import unittest
from datetime import datetime, timedelta
from unittest import mock
from zoneinfo import ZoneInfo

from test_work_schedule import _FakeDb, _FakeDocument, main, needs_main

FUSO = ZoneInfo("America/Sao_Paulo")


def _rodar(coro):
    return asyncio.run(coro)


@needs_main
class HoraDaBatidaTest(unittest.TestCase):
    def setUp(self):
        self.db = _FakeDb()
        self.user = {"id": "u1", "role": "employee", "name": "Fulano", "email": "f@x"}
        for patcher in (mock.patch.object(main, "get_firestore_admin", return_value=self.db),
                        mock.patch.object(main, "firestore", types.SimpleNamespace(SERVER_TIMESTAMP="ts"))):
            patcher.start()
            self.addCleanup(patcher.stop)

    def test_online_grava_a_hora_do_servidor_e_guarda_a_do_aparelho(self):
        aparelho = datetime.now(FUSO) - timedelta(minutes=10)          # relogio do celular 10 min atrasado
        payload = main.SchedulePunchRequest(record_type="check_in", timestamp=aparelho.isoformat())
        r = _rodar(main.schedule_controlled_punch_endpoint(payload, self.user))
        gravada = datetime.fromisoformat(r["timestamp"]).replace(tzinfo=FUSO)
        self.assertLess(abs((gravada - datetime.now(FUSO)).total_seconds()), 60)
        self.assertEqual(r["device_timestamp"][:16], aparelho.replace(tzinfo=None).isoformat()[:16])

    def test_fechar_no_horario_programado_nao_vale_na_entrada(self):
        futuro = datetime.now(FUSO) + timedelta(days=3)
        payload = main.SchedulePunchRequest(record_type="check_in", timestamp=futuro.isoformat(),
                                            close_at_scheduled_end=True)
        with self.assertRaises(main.HTTPException) as erro:
            _rodar(main.schedule_controlled_punch_endpoint(payload, self.user))
        self.assertEqual(erro.exception.status_code, 400)
        self.assertEqual(self.db.store.get("time_records", {}), {})


@needs_main
@unittest.skipIf(main is None or main.firestore is None, "firebase-admin ausente")
class RespostaViraJsonTest(unittest.TestCase):
    """Com o SERVER_TIMESTAMP de verdade (sem trocar o firestore por um texto, como os testes acima): a resposta
    precisa virar JSON. Antes a batida e o pedido de liberacao gravavam e devolviam 500 (28/10/2026)."""

    def setUp(self):
        self.db = _FakeDb()
        self.intern = {"id": "e1", "role": "intern", "name": "Estagiaria"}
        patcher = mock.patch.object(main, "get_firestore_admin", return_value=self.db)
        patcher.start()
        self.addCleanup(patcher.stop)

    def _json(self, resposta):
        from fastapi.encoders import jsonable_encoder
        return jsonable_encoder(resposta)

    def test_batida_do_estagiario(self):
        payload = main.SchedulePunchRequest(record_type="check_out", close_at_scheduled_end=False,
                                            timestamp=datetime.now(FUSO).isoformat())
        self.db.store["time_records"] = {"in": {"user_id": "u1", "record_type": "check_in",
                                                "timestamp": main._local_iso(datetime.now(FUSO) - timedelta(hours=1))}}
        r = _rodar(main.schedule_controlled_punch_endpoint(payload, {"id": "u1", "role": "employee"}))
        self.assertEqual(self._json(r)["status"], "created")
        self.assertIs(self.db.store["time_records"][r["id"]]["created_at"], main.firestore.SERVER_TIMESTAMP)

    def test_pedido_de_liberacao(self):
        self.db.store["time_records"] = {"in": {"user_id": "e1", "record_type": "check_in",
                                                "timestamp": main._local_iso(datetime.now(FUSO) - timedelta(hours=1))}}
        payload = main.ScheduleApprovalCreateRequest(request_type="overtime", notes="Fechamento da obra",
                                                     attempted_at=datetime.now(FUSO).isoformat())
        r = _rodar(main.create_schedule_approval_request_endpoint(payload, self.intern))
        self.assertEqual(self._json(r)["status"], "created")


@needs_main
class BloqueioDeLoginTest(unittest.TestCase):
    """Atras do tunel da Cloudflare todo pedido chega com o mesmo X-Real-IP: a senha errada de uma pessoa nao
    pode travar o login das outras (28/10/2026)."""
    TUNEL = "172.18.0.1"

    def setUp(self):
        self.db = _FakeDb()
        self.db.store["users"] = {"ana": {"cpf": "529.982.247-25"}, "bruno": {"cpf": "111.444.777-35"}}
        auth = types.SimpleNamespace(get_user=lambda uid: types.SimpleNamespace(email=f"{uid}@x"),
                                     UserNotFoundError=type("NF", (Exception,), {}))

        async def senha(email, password):
            return "ok" if password == "certa" else "invalid"

        main._login_failures.clear()
        for patcher in (mock.patch.object(main, "get_firestore_admin", return_value=self.db),
                        mock.patch.object(main, "firebase_auth", auth),
                        mock.patch.object(main, "_check_firebase_password", senha)):
            patcher.start()
            self.addCleanup(patcher.stop)
        self.addCleanup(main._login_failures.clear)

    def _login(self, cpf, senha, ip_real):
        pedido = types.SimpleNamespace(headers={"x-real-ip": self.TUNEL, "cf-connecting-ip": ip_real}, client=None)
        return _rodar(main.cpf_login_endpoint(main.CpfLoginRequest(cpf=cpf, password=senha), pedido))

    def _errar(self, vezes, ip_real):
        for _ in range(vezes):
            with self.assertRaises(main.HTTPException):
                self._login("52998224725", "errada", ip_real)

    def test_senha_errada_de_uma_pessoa_nao_trava_outra_em_outro_aparelho(self):
        self._errar(10, "200.1.1.1")
        self.assertEqual(self._login("11144477735", "certa", "200.2.2.2"), {"email": "bruno@x"})

    def test_mesmo_wifi_do_escritorio(self):
        self._errar(10, "200.1.1.1")
        self.assertEqual(self._login("11144477735", "certa", "200.1.1.1"), {"email": "bruno@x"})

    def test_cpf_continua_travando_apos_10_erros(self):
        self._errar(10, "200.1.1.1")
        with self.assertRaises(main.HTTPException) as erro:
            self._login("52998224725", "certa", "200.9.9.9")
        self.assertEqual(erro.exception.status_code, 429)


@needs_main
class ExcluirUsuarioTest(unittest.TestCase):
    def setUp(self):
        self.db = _FakeDb()
        self.db.store["users"] = {"alvo": {"name": "Alvo", "role": "employee"}}
        self.db.store["time_record_audits"] = {"a1": {"record_user_id": "alvo"}}
        self.db.store["user_audits"] = {"a2": {"deleted_user_id": "alvo"}}
        auth = types.SimpleNamespace(delete_user=lambda uid: None, UserNotFoundError=type("NF", (Exception,), {}))
        # O documento simulado nem sempre tem delete(): este teste não depende disso.
        apagar_doc = lambda doc: doc._store.setdefault(doc._collection, {}).pop(doc.id, None)  # noqa: E731
        for patcher in (mock.patch.object(_FakeDocument, "delete", apagar_doc, create=True),
                        mock.patch.object(main, "get_firestore_admin", return_value=self.db),
                        mock.patch.object(main, "firebase_auth", auth),
                        mock.patch.object(main, "firestore", types.SimpleNamespace(SERVER_TIMESTAMP="ts"))):
            patcher.start()
            self.addCleanup(patcher.stop)

    def test_gerente_nao_exclui(self):
        with self.assertRaises(main.HTTPException) as erro:
            _rodar(main.delete_user_admin_endpoint("alvo", {"id": "g1", "role": "manager"}))
        self.assertEqual(erro.exception.status_code, 403)
        self.assertIn("alvo", self.db.store["users"])

    def test_cascata_mantem_as_auditorias(self):
        def apagar(_db, consulta):           # o simulado nao tem limit/batch: apaga direto o que a consulta acha
            achados = list(consulta.stream())
            for doc in achados:
                doc.reference.delete()
            return len(achados)
        with mock.patch.object(main, "delete_query_in_batches", apagar):
            main.delete_user_cascade(self.db, "alvo")
        self.assertNotIn("alvo", self.db.store["users"])
        self.assertIn("a1", self.db.store["time_record_audits"])
        self.assertIn("a2", self.db.store["user_audits"])


@needs_main
class WebhookZapSignTest(unittest.TestCase):
    def _pedido(self, cabecalho=""):
        return types.SimpleNamespace(headers={"X-Webhook-Secret": cabecalho} if cabecalho else {},
                                     query_params={}, json=None)

    def test_sem_segredo_configurado_fica_fechado(self):
        with mock.patch.object(main, "ZAPSIGN_WEBHOOK_SECRET", ""):
            with self.assertRaises(main.HTTPException) as erro:
                _rodar(main.zapsign_webhook(self._pedido()))
        self.assertEqual(erro.exception.status_code, 404)

    def test_segredo_errado_recusado(self):
        with mock.patch.object(main, "ZAPSIGN_WEBHOOK_SECRET", "certo"):
            with self.assertRaises(main.HTTPException) as erro:
                _rodar(main.zapsign_webhook(self._pedido("errado")))
        self.assertEqual(erro.exception.status_code, 401)


if __name__ == "__main__":
    unittest.main()
