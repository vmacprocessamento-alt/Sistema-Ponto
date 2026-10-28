"""Correcoes de seguranca de 17/10/2026: hora da batida online, fechar no horario programado so na saida, exclusao de
usuario so pelo admin (sem apagar auditorias) e webhook da ZapSign fechado sem segredo.

    python -m unittest test_seguranca
"""
import asyncio
import os
import types
import unittest
from datetime import datetime, timedelta
from unittest import mock
from zoneinfo import ZoneInfo

from test_work_schedule import _FakeDb, _FakeDocument, _FakeQuery, main, needs_main

FUSO = ZoneInfo("America/Sao_Paulo")


def _rodar(resultado):
    # Endpoint `def` ja devolve o resultado; `async def` devolve a corrotina.
    return asyncio.run(resultado) if asyncio.iscoroutine(resultado) else resultado


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


class _ContaLeituras:
    """Conta documentos lidos do Firestore simulado (o que entra na cota do plano gratuito)."""

    def __init__(self, test):
        self.lidos = 0
        original = _FakeQuery.stream

        def stream(consulta):
            for snap in original(consulta):
                self.lidos += 1
                yield snap

        patcher = mock.patch.object(_FakeQuery, "stream", stream)
        patcher.start()
        test.addCleanup(patcher.stop)


@needs_main
class MenosLeiturasTest(unittest.TestCase):
    def setUp(self):
        self.db = _FakeDb()
        self.db.store["users"] = {f"u{i}": {"cpf": f"{i:011d}", "cpf_digits": f"{i:011d}"} for i in range(200)}
        main._backfill_cpf_digits(self.db)  # feito uma vez quando o servidor sobe
        self.addCleanup(main._cpf_digits_backfilled.clear)
        self.leituras = _ContaLeituras(self)

    def test_login_le_um_cadastro_nao_todos(self):
        achados = main._users_with_cpf(self.db, "00000000007", thorough=False)
        self.assertEqual([d.id for d in achados], ["u7"])
        self.assertEqual(self.leituras.lidos, 1)

    def test_cadastro_antigo_sem_cpf_digits_e_achado_e_corrigido(self):
        self.db.store["users"]["velho"] = {"cpf": "529.982.247-25"}
        self.assertEqual([d.id for d in main._users_with_cpf(self.db, "52998224725", thorough=False)], ["velho"])
        self.assertEqual(self.db.store["users"]["velho"]["cpf_digits"], "52998224725")
        self.leituras.lidos = 0
        main._users_with_cpf(self.db, "52998224725", thorough=False)
        self.assertEqual(self.leituras.lidos, 1)

    def test_cpf_digits_velho_nao_engana(self):
        # CPF trocado pelo plano B do app: "cpf" novo, cpf_digits ainda o antigo.
        self.db.store["users"]["u7"]["cpf"] = "529.982.247-25"
        self.assertEqual(main._users_with_cpf(self.db, "00000000007", thorough=False), [])
        self.assertEqual([d.id for d in main._users_with_cpf(self.db, "52998224725", thorough=False)], ["u7"])

    def test_admin_ainda_ve_cpf_repetido_em_cadastro_antigo(self):
        self.db.store["users"]["velho"] = {"cpf": "000.000.000-07"}
        self.assertEqual(sorted(d.id for d in main._users_with_cpf(self.db, "00000000007")), ["u7", "velho"])

    def test_horario_efetivo_le_so_os_pedidos_do_dia(self):
        self.db.store["work_schedule_approval_requests"] = {
            f"a{i}": {"user_id": "e1", "request_type": "overtime", "day_key": f"2026-09-{i % 28 + 1:02d}",
                      "status": "approved"} for i in range(80)}
        with mock.patch.object(main, "get_firestore_admin", return_value=self.db):
            _rodar(main.get_effective_work_schedule_endpoint(None, {"id": "e1", "role": "intern"}))
        self.assertLessEqual(self.leituras.lidos, 2)


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
class DesempenhoTest(unittest.TestCase):
    """O Firestore do Admin SDK e bloqueante: nos endpoints `async def` uma batida travava o servidor inteiro e
    as do pico entravam em fila (30 juntas: a ultima esperava ~10 s). E o token era conferido no Google em toda
    requisicao, com cliente HTTP novo (28/10/2026)."""

    def test_batidas_simultaneas_nao_esperam_umas_pelas_outras(self):
        import time
        import httpx

        lento = 0.2
        original_get = _FakeDocument.get

        def get_lento(doc):
            time.sleep(lento)  # o SDK real bloqueia assim enquanto espera o Google
            return original_get(doc)

        async def usuario():
            return {"id": "u1", "role": "employee"}

        async def disparar(n):
            transporte = httpx.ASGITransport(app=main.app)
            async with httpx.AsyncClient(transport=transporte, base_url="http://t") as cliente:
                pedido = lambda: cliente.post("/work-schedule/punch", json={"record_type": "check_in"})  # noqa: E731
                inicio = time.perf_counter()
                respostas = await asyncio.gather(*(pedido() for _ in range(n)))
                return time.perf_counter() - inicio, respostas

        main.app.dependency_overrides[main.require_authenticated_user] = usuario
        self.addCleanup(main.app.dependency_overrides.clear)
        with mock.patch.object(main, "get_firestore_admin", return_value=_FakeDb()), \
                mock.patch.object(main, "firestore", types.SimpleNamespace(SERVER_TIMESTAMP="ts")), \
                mock.patch.object(_FakeDocument, "get", get_lento):
            gasto, respostas = asyncio.run(disparar(10))
        self.assertTrue(all(r.status_code in (200, 409) for r in respostas), [r.status_code for r in respostas])
        # Em fila: 10 leituras lentas uma apos a outra = 2 s. Em paralelo, perto de uma so.
        self.assertLess(gasto, 10 * lento / 3)

    def test_token_conferido_uma_vez_e_cliente_reaproveitado(self):
        chamadas = []

        class Resposta:
            is_success = True

            def json(self):
                return {"users": [{"localId": "u1"}]}

        class Cliente:
            is_closed = False

            async def post(self, *args, **kwargs):
                chamadas.append(args)
                return Resposta()

        async def duas_vezes():
            return [await main.verify_firebase_user_token("tok-abc"), await main.verify_firebase_user_token("tok-abc")]

        main._verified_tokens.clear()
        self.addCleanup(main._verified_tokens.clear)
        with mock.patch.object(main, "FIREBASE_WEB_API_KEY", "k"), \
                mock.patch.object(main, "_http_client", lambda: Cliente()):
            self.assertEqual(asyncio.run(duas_vezes()), ["u1", "u1"])
        self.assertEqual(len(chamadas), 1)

    def test_um_cliente_http_por_event_loop(self):
        async def dois():
            return main._http_client() is main._http_client()

        self.assertTrue(asyncio.run(dois()))


@needs_main
class ArquivoExportadoApagadoTest(unittest.TestCase):
    """Folha, lote e relatorio exportados ficavam no /tmp do servidor para sempre (28/10/2026)."""

    def setUp(self):
        from fastapi.testclient import TestClient

        async def usuario():
            return {"id": "a1", "role": "admin"}

        main.app.dependency_overrides[main.require_authenticated_user] = usuario
        self.addCleanup(main.app.dependency_overrides.clear)
        self.cliente = TestClient(main.app)
        self.dados = {"employee_name": "Fulano", "employee_role": "Aux", "cpf": "1", "month": "10", "year": "2026",
                      "is_campo": False, "daily_records": []}
        self.gerados = []
        for nome in ("generate_excel_file", "generate_batch_html_file"):
            original = getattr(main, nome)

            def anotar(*args, _original=original, **kwargs):
                caminho = _original(*args, **kwargs)
                self.gerados.append(caminho)
                return caminho

            patcher = mock.patch.object(main, nome, anotar)
            patcher.start()
            self.addCleanup(patcher.stop)

    def _exportar(self, rota, corpo):
        try:
            resposta = self.cliente.post(rota, json=corpo)
        except FileNotFoundError as exc:  # modelo do Excel fora do lugar nesta maquina
            self.skipTest(str(exc))
        if resposta.status_code == 500 and "No such file" in resposta.text:
            self.skipTest(resposta.text)
        self.assertEqual(resposta.status_code, 200, resposta.text)
        self.assertGreater(len(resposta.content), 0)
        self.assertTrue(self.gerados)
        for caminho in self.gerados:
            self.assertFalse(os.path.exists(caminho), caminho)

    def test_folha_excel(self):
        self._exportar("/export-excel", self.dados)

    def test_lote_zip(self):
        import zipfile
        with mock.patch.object(main.zipfile, "ZipFile", wraps=zipfile.ZipFile) as zip_criado:
            self._exportar("/export-batch", [self.dados])
        self.assertFalse(os.path.exists(os.path.dirname(zip_criado.call_args[0][0])))

    def test_relatorio_html(self):
        self._exportar("/export-batch-html", [self.dados])


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
