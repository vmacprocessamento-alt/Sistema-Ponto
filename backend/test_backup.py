"""Backup completo semanal + incremental diario (28/10/2026): ler o banco
inteiro todo dia comia a cota de leituras do plano Spark.

    python -m unittest test_backup
"""
import json
import os
import shutil
import sqlite3
import tempfile
import time
import unittest
import zipfile
from datetime import datetime, timedelta
from unittest import mock
from zoneinfo import ZoneInfo

from test_work_schedule import _FakeDb, _FakeQuery, main, needs_main

import restore_backup

UTC = ZoneInfo("UTC")


class _FakeCollection(_FakeQuery):
    @property
    def id(self):
        return self._collection


class _BackupDb(_FakeDb):
    """_FakeDb com collections() e contagem de documentos lidos."""

    def __init__(self):
        super().__init__()
        self.read = 0

    def collection(self, name):
        return _FakeCollection(self.store, name)

    def collections(self):
        return [_FakeCollection(self.store, name) for name in sorted(self.store)]


@needs_main
class RotacaoTest(unittest.TestCase):
    def test_guarda_3_completos_e_os_incrementais_deles(self):
        nomes = [
            "backup-20260901-030000.zip", "backup-20260902-030000-inc.zip",
            "backup-20260908-030000.zip", "backup-20260909-030000-inc.zip",
            "backup-20260915-030000.zip", "backup-20260922-030000.zip",
            "backup-20260923-030000-inc.zip",
        ]
        self.assertEqual(main._backups_to_delete(nomes),
                         ["backup-20260901-030000.zip", "backup-20260902-030000-inc.zip"])

    def test_poucos_backups_nada_sai(self):
        self.assertEqual(main._backups_to_delete(["backup-20260901-030000.zip"]), [])
        self.assertEqual(main._backups_to_delete([]), [])


@needs_main
class BackupIncrementalTest(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.dir, ignore_errors=True)
        sqlite_path = os.path.join(self.dir, "ponto.db")
        sqlite3.connect(sqlite_path).close()
        self.db = _BackupDb()
        velho = datetime(2026, 1, 1, tzinfo=UTC)
        self.db.store["users"] = {"u1": {"name": "Ana"}, "u2": {"name": "Bia"}}
        self.db.store["time_records"] = {f"r{i}": {"user_id": "u1", "created_at": velho} for i in range(50)}
        for patcher in (mock.patch.object(main, "_BACKUP_DIR", os.path.join(self.dir, "backups")),
                        mock.patch.object(main, "DATABASE_PATH", sqlite_path),
                        mock.patch.object(main, "storage", None),
                        mock.patch.object(main, "get_firestore_admin", return_value=self.db)):
            patcher.start()
            self.addCleanup(patcher.stop)

    def _envelhecer(self, nome, dias):
        caminho = os.path.join(main._BACKUP_DIR, nome)
        quando = time.time() - dias * 86400
        os.utime(caminho, (quando, quando))

    def _abrir(self, nome):
        with zipfile.ZipFile(os.path.join(main._BACKUP_DIR, nome)) as archive:
            return json.loads(archive.read("firestore.json")), json.loads(archive.read("manifest.json"))

    def test_completo_depois_incremental_com_so_o_que_mudou(self):
        primeiro = main._run_backup()
        self.assertEqual(primeiro["type"], "full")
        self.assertEqual(primeiro["collections"]["time_records"], 50)
        self._envelhecer(primeiro["file"], 1)

        self.db.store["time_records"]["novo"] = {"user_id": "u1", "created_at": datetime.now(UTC)}
        self.db.store["time_records"]["r3"]["updated_at"] = datetime.now(UTC)  # editado pelo admin
        self.db.store["users"]["u3"] = {"name": "Caio"}
        segundo = main._run_backup()
        self.assertEqual(segundo["type"], "incremental")
        self.assertTrue(segundo["file"].endswith("-inc.zip"))
        dump, manifest = self._abrir(segundo["file"])
        self.assertEqual(sorted(d["id"] for d in dump["time_records"]), ["novo", "r3"])
        self.assertEqual(len(dump["users"]), 3)  # pequena: inteira
        self.assertEqual(manifest["base"], primeiro["file"])
        self.assertIn("users", manifest["complete_collections"])
        self.assertNotIn("time_records", manifest["complete_collections"])

        # Juntando os dois volta o banco inteiro.
        caminhos = [os.path.join(main._BACKUP_DIR, n) for n in (primeiro["file"], segundo["file"])]
        junto = restore_backup.merge_backups(caminhos)
        self.assertEqual(len(junto["time_records"]), 51)
        self.assertEqual(len(junto["users"]), 3)

    def test_uma_semana_depois_volta_o_completo(self):
        primeiro = main._run_backup()
        self._envelhecer(primeiro["file"], 8)
        self.assertEqual(main._run_backup()["type"], "full")

    def test_email_manda_o_completo(self):
        primeiro = main._run_backup()
        self._envelhecer(primeiro["file"], 1)
        main._run_backup()
        enviados = []
        with mock.patch.object(main, "_BACKUP_ZIP_PASSWORD", "x"), \
                mock.patch.object(main, "MAIL_PASSWORD", "y"), \
                mock.patch.object(main, "_encrypt_backup", lambda origem, destino: enviados.append(origem) or False):
            main._send_backup_email()
        self.assertEqual([os.path.basename(p) for p in enviados], [primeiro["file"]])


if __name__ == "__main__":
    unittest.main()
