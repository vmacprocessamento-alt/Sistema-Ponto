"""Manutencao do backend (28/10/2026): credencial ausente falha na hora,
token esquecido ao desativar a conta, horario da edicao de ponto validado e
subida/descida do servidor pelo lifespan.

    python -m unittest test_manutencao
"""
import os
import time
import unittest
from unittest import mock

from test_work_schedule import main, needs_main


@needs_main
class CredencialAusenteTest(unittest.TestCase):
    def test_sem_credencial_recusa_na_hora(self):
        sem = {k: v for k, v in os.environ.items() if k not in {
            "FIREBASE_SERVICE_ACCOUNT_PATH", "FIREBASE_SERVICE_ACCOUNT_JSON",
            "GOOGLE_APPLICATION_CREDENTIALS", "FIRESTORE_EMULATOR_HOST"}}
        with mock.patch.dict(os.environ, sem, clear=True), \
                mock.patch.object(main.firebase_admin, "_apps", {}):
            inicio = time.perf_counter()
            with self.assertRaises(main.HTTPException) as erro:
                main.get_firestore_admin()
        self.assertEqual(erro.exception.status_code, 503)
        self.assertLess(time.perf_counter() - inicio, 1)


@needs_main
class EmuladorTest(unittest.TestCase):
    """Com as variaveis do emulador, o backend fala com ele sozinho (testes de ponta a ponta)."""

    def test_urls_do_google_ou_do_emulador(self):
        with mock.patch.dict(os.environ, {}, clear=False):
            for var in ("FIRESTORE_EMULATOR_HOST", "FIREBASE_AUTH_EMULATOR_HOST"):
                os.environ.pop(var, None)
            self.assertEqual(main._google_api("identitytoolkit.googleapis.com", "v1/accounts:lookup"),
                             "https://identitytoolkit.googleapis.com/v1/accounts:lookup")
        with mock.patch.dict(os.environ, {"FIRESTORE_EMULATOR_HOST": "127.0.0.1:8085",
                                          "FIREBASE_AUTH_EMULATOR_HOST": "127.0.0.1:9099"}):
            self.assertEqual(main._google_api("firestore.googleapis.com", "v1/projects/p"),
                             "http://127.0.0.1:8085/v1/projects/p")
            self.assertEqual(main._google_api("identitytoolkit.googleapis.com", "v1/accounts:lookup"),
                             "http://127.0.0.1:9099/identitytoolkit.googleapis.com/v1/accounts:lookup")


@needs_main
class TokenEsquecidoTest(unittest.TestCase):
    def setUp(self):
        main._verified_tokens.clear()
        self.addCleanup(main._verified_tokens.clear)

    def test_desativar_conta_esquece_os_tokens_dela(self):
        main._remember_token("tok-a", "u1")
        main._remember_token("tok-b", "u1")
        main._remember_token("tok-c", "u2")
        main._forget_user_tokens("u1")
        self.assertIsNone(main._cached_token_uid("tok-a"))
        self.assertIsNone(main._cached_token_uid("tok-b"))
        self.assertEqual(main._cached_token_uid("tok-c"), "u2")


@needs_main
class EdicaoDePontoTest(unittest.TestCase):
    admin = {"id": "a1", "role": "admin", "name": "Admin"}

    def _editar(self, horario):
        payload = main.AdminTimeRecordUpdateRequest(new_timestamp=horario, reason="Esqueceu de bater")
        return main.update_time_record_admin_endpoint("r1", payload, self.admin)

    def test_horario_invalido_recusado(self):
        for ruim in ("", "ontem as 8", "2026-13-45T99:00"):
            with self.assertRaises(main.HTTPException) as erro:
                self._editar(ruim)
            self.assertEqual(erro.exception.status_code, 400, ruim)

    def test_horario_valido_passa_e_vira_hora_local(self):
        with mock.patch.object(main, "get_firestore_admin", side_effect=RuntimeError("passou da validacao")):
            with self.assertRaisesRegex(RuntimeError, "passou da validacao"):
                self._editar("2026-10-20T08:00:00")
        utc = main._local_iso(main._parse_schedule_datetime("2026-10-20T11:00:00Z", main._LOCAL_TZ))
        self.assertEqual(utc, "2026-10-20T08:00:00")


@needs_main
class LifespanTest(unittest.TestCase):
    def test_sobe_os_jobs_e_desce_fechando_tudo(self):
        from fastapi.testclient import TestClient
        chamadas = []

        async def job():
            chamadas.append("job")

        with mock.patch.object(main, "init_signature_documents_table", lambda: chamadas.append("tabela")), \
                mock.patch.object(main, "_auto_close_breaks_loop", job), \
                mock.patch.object(main, "_backup_loop", job):
            with TestClient(main.app) as cliente:
                self.assertEqual(cliente.get("/health").json(), {"status": "ok"})
        self.assertEqual(chamadas.count("tabela"), 1)
        self.assertEqual(chamadas.count("job"), 2)
        self.assertEqual(main._http_clients, {})


if __name__ == "__main__":
    unittest.main()
