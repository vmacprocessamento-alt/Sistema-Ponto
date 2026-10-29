"""Versao do app informada ao abrir (29/10/2026): a Gestao mostra quem ficou numa versao antiga.

    python -m unittest test_versao_app
"""
import asyncio
import types
import unittest
from unittest import mock

from test_work_schedule import _FakeDb, main, needs_main


@needs_main
class VersaoDoAppTest(unittest.TestCase):
    def setUp(self):
        self.db = _FakeDb()
        self.db.store["users"] = {"u1": {"name": "Fulano", "role": "employee", "fcm_tokens": ["t"]}}
        self.user = {"id": "u1", "role": "employee", "name": "Fulano"}
        for patcher in (mock.patch.object(main, "get_firestore_admin", return_value=self.db),
                        mock.patch.object(main, "firestore", types.SimpleNamespace(SERVER_TIMESTAMP="ts"))):
            patcher.start()
            self.addCleanup(patcher.stop)

    def _enviar(self, version, device=None):
        payload = main.AppVersionReport(version=version, device=device)
        return asyncio.run(main.report_app_version_endpoint(payload, self.user))

    def test_grava_versao_aparelho_e_hora_sem_mexer_no_resto(self):
        self._enviar("0.4", "  iPhone ·   app instalado ")
        cadastro = self.db.store["users"]["u1"]
        self.assertEqual(cadastro["app_version"], "0.4")
        self.assertEqual(cadastro["app_device"], "iPhone · app instalado")
        self.assertEqual(cadastro["app_opened_at"], "ts")
        self.assertEqual(cadastro["name"], "Fulano")
        self.assertEqual(cadastro["role"], "employee")
        self.assertEqual(cadastro["fcm_tokens"], ["t"])

    def test_build_de_teste_e_aparelho_vazio(self):
        self._enviar("teste")
        self.assertEqual(self.db.store["users"]["u1"]["app_version"], "teste")
        self.assertEqual(self.db.store["users"]["u1"]["app_device"], "")

    def test_aparelho_longo_e_cortado(self):
        self._enviar("1.12", "x" * 500)
        self.assertEqual(len(self.db.store["users"]["u1"]["app_device"]), 60)

    def test_versao_invalida_nao_grava(self):
        for ruim in ("", "0.4; drop", "versao 0.4", "1", "0.4.1", "<script>"):
            with self.subTest(ruim=ruim):
                with self.assertRaises(main.HTTPException) as erro:
                    self._enviar(ruim)
                self.assertEqual(erro.exception.status_code, 400)
        self.assertNotIn("app_version", self.db.store["users"]["u1"])


if __name__ == "__main__":
    unittest.main()
