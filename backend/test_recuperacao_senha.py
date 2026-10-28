"""Recuperacao de senha por e-mail (POST /auth/password-reset): o link vai para o e-mail real do cadastro, pelo Gmail
do RH. Antes o app pedia direto ao Firebase, que respondia "enviado" mesmo para conta por CPF (e-mail interno, que
ninguem recebe).

    python -m unittest test_recuperacao_senha
"""
import asyncio
import types
import unittest
from unittest import mock

from test_work_schedule import _FakeDb, _FakeQuery, main, needs_main


def _rodar(coro):
    return asyncio.run(coro)


@needs_main
class RecuperacaoDeSenhaTest(unittest.TestCase):
    CPF = "52998224725"

    def setUp(self):
        self.db = _FakeDb()
        self.db.store["users"] = {
            "com_email": {"name": "Ana Souza", "cpf": "529.982.247-25", "email": "ana@gmail.com"},
            "so_cpf": {"name": "Bruno", "cpf": "111.444.777-35", "email": ""},
        }
        nao_achou = type("UserNotFoundError", (Exception,), {})
        self.contas = {
            "com_email": types.SimpleNamespace(uid="com_email", email="ana@gmail.com", disabled=False,
                                               display_name="Ana"),
            "so_cpf": types.SimpleNamespace(uid="so_cpf", email="11144477735@" + main.CPF_LOGIN_EMAIL_DOMAIN,
                                            disabled=False, display_name="Bruno"),
        }

        def get_user(uid):
            if uid not in self.contas:
                raise nao_achou(uid)
            return self.contas[uid]

        def get_user_by_email(email):
            for conta in self.contas.values():
                if conta.email == email:
                    return conta
            raise nao_achou(email)

        self.links = []
        auth = types.SimpleNamespace(
            get_user=get_user,
            get_user_by_email=get_user_by_email,
            generate_password_reset_link=lambda email: self.links.append(email) or f"https://link/{email}",
            UserNotFoundError=nao_achou,
        )
        self.enviados = []
        enviados = self.enviados

        class FastMailFalso:
            def __init__(self, _conf):
                pass

            async def send_message(self, message):
                enviados.append(message)

        main._login_failures.clear()
        self.addCleanup(main._login_failures.clear)
        for patcher in (mock.patch.object(main, "get_firestore_admin", return_value=self.db),
                        mock.patch.object(main, "firebase_auth", auth),
                        mock.patch.object(main, "firestore", types.SimpleNamespace(SERVER_TIMESTAMP="ts")),
                        mock.patch.object(main, "FastMail", FastMailFalso),
                        mock.patch.object(main, "MAIL_PASSWORD", "senha-de-app"),
                        mock.patch.object(_FakeQuery, "limit", lambda self, _n: self, create=True)):
            patcher.start()
            self.addCleanup(patcher.stop)

    def _pedir(self, login):
        return _rodar(main.password_reset_endpoint(main.PasswordResetRequest(login=login)))

    def test_por_cpf_vai_para_o_email_do_cadastro(self):
        r = self._pedir("529.982.247-25")
        self.assertEqual(r["status"], "ok")
        self.assertEqual(len(self.enviados), 1)
        self.assertEqual([str(r) for r in self.enviados[0].recipients], ["ana@gmail.com"])
        self.assertEqual(self.links, ["ana@gmail.com"])
        self.assertIn("https://link/ana@gmail.com", self.enviados[0].body)
        auditorias = list(self.db.store.get("system_audits", {}).values())
        self.assertEqual([a["action"] for a in auditorias], ["password_reset_email"])

    def test_por_email_tambem_acha(self):
        self._pedir("  Ana@Gmail.com ")
        self.assertEqual(len(self.enviados), 1)

    def test_conta_so_com_cpf_nao_manda_para_o_email_interno(self):
        r = self._pedir("11144477735")
        self.assertEqual(r, main._PASSWORD_RESET_REPLY)
        self.assertEqual(self.enviados, [])
        self.assertEqual(self.links, [])

    def test_cpf_desconhecido_responde_igual(self):
        self.assertEqual(self._pedir("39053344705"), main._PASSWORD_RESET_REPLY)
        self.assertEqual(self.enviados, [])

    def test_conta_desativada_nao_recebe(self):
        self.contas["com_email"].disabled = True
        self._pedir(self.CPF)
        self.assertEqual(self.enviados, [])

    def test_sem_smtp_configurado_avisa(self):
        with mock.patch.object(main, "MAIL_PASSWORD", "mude-me"):
            with self.assertRaises(main.HTTPException) as erro:
                self._pedir(self.CPF)
        self.assertEqual(erro.exception.status_code, 503)

    def test_limite_de_pedidos_por_login(self):
        for _ in range(main._LOGIN_MAX_FAILURES):
            self._pedir(self.CPF)
        with self.assertRaises(main.HTTPException) as erro:
            self._pedir(self.CPF)
        self.assertEqual(erro.exception.status_code, 429)
        # Outra pessoa continua podendo pedir.
        self._pedir("ana@gmail.com")


if __name__ == "__main__":
    unittest.main()
