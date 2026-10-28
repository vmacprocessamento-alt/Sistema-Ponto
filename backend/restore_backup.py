#!/usr/bin/env python3
"""Ferramentas de restauracao dos backups.

Descriptografar o backup do email semanal:
    python restore_backup.py backup-YYYYMMDD-HHMMSS.zip.enc [saida.zip]
A senha vem de BACKUP_ZIP_PASSWORD (env) ou e pedida interativamente.
Gera de volta o .zip com firestore.json + ponto.db.

Juntar o completo da semana com os incrementais dos dias seguintes:
    python restore_backup.py juntar backup-...zip backup-...-inc.zip [...] [-o firestore.json]
O completo primeiro, depois os incrementais em ordem. Nas colecoes que o
incremental traz inteiras (manifest.json: complete_collections), vale a do
incremental; nas que crescem, cada documento do incremental substitui o de
mesmo id. Documento apagado depois do completo continua no resultado.
"""
import base64
import getpass
import hashlib
import json
import os
import sys
import zipfile


def merge_backups(zip_paths):
    """firestore.json combinado do completo (primeiro) e dos incrementais."""
    merged = {}
    for index, path in enumerate(zip_paths):
        with zipfile.ZipFile(path) as archive:
            dump = json.loads(archive.read("firestore.json"))
            names = archive.namelist()
            manifest = json.loads(archive.read("manifest.json")) if "manifest.json" in names else {"type": "full"}
        if index == 0 and manifest.get("type") != "full":
            raise SystemExit(f"{path}: o primeiro arquivo precisa ser um backup completo.")
        if index > 0 and manifest.get("type") != "incremental":
            raise SystemExit(f"{path}: depois do completo, so incrementais.")
        complete = set(manifest.get("complete_collections") or dump.keys())
        for collection, docs in dump.items():
            if index == 0 or collection in complete:
                merged[collection] = {doc["id"]: doc for doc in docs}
            else:
                merged.setdefault(collection, {}).update({doc["id"]: doc for doc in docs})
    return {collection: list(docs.values()) for collection, docs in merged.items()}


def juntar(args):
    out = "firestore.json"
    if "-o" in args:
        at = args.index("-o")
        out = args[at + 1]
        args = args[:at] + args[at + 2:]
    if not args:
        sys.exit(__doc__)
    merged = merge_backups(args)
    with open(out, "w", encoding="utf-8") as handle:
        json.dump(merged, handle, ensure_ascii=False)
    counts = {name: len(docs) for name, docs in merged.items()}
    print(f"OK: {out} {counts}")


def main() -> None:
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    if sys.argv[1] == "juntar":
        juntar(sys.argv[2:])
        return
    try:
        from cryptography.fernet import Fernet
    except ImportError:
        sys.exit("Instale a lib: pip install cryptography")

    enc_path = sys.argv[1]
    if not os.path.exists(enc_path):
        sys.exit(f"Arquivo nao encontrado: {enc_path}")

    out_path = sys.argv[2] if len(sys.argv) > 2 else (
        enc_path[:-4] if enc_path.endswith(".enc") else enc_path + ".zip"
    )

    password = os.getenv("BACKUP_ZIP_PASSWORD") or getpass.getpass(
        "Senha do backup (BACKUP_ZIP_PASSWORD): "
    )
    key = base64.urlsafe_b64encode(hashlib.sha256(password.encode("utf-8")).digest())

    with open(enc_path, "rb") as handle:
        token = handle.read()
    try:
        data = Fernet(key).decrypt(token)
    except Exception:
        sys.exit("Falha ao descriptografar: senha incorreta ou arquivo corrompido.")

    with open(out_path, "wb") as handle:
        handle.write(data)
    print(f"OK: {out_path} ({len(data)} bytes). Descompacte para firestore.json + ponto.db.")


if __name__ == "__main__":
    main()
