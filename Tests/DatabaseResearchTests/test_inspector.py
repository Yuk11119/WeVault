import importlib.util
from pathlib import Path
import sqlite3
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[2] / "Scripts/inspect-wechat-databases.py"
spec = importlib.util.spec_from_file_location("inspector", SCRIPT)
inspector = importlib.util.module_from_spec(spec)
spec.loader.exec_module(inspector)


class InspectorTests(unittest.TestCase):
    def test_schema_only_and_source_unchanged(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            db = root / "private_account/db_storage/contact/contact.db"
            db.parent.mkdir(parents=True)
            with sqlite3.connect(db) as connection:
                connection.execute("CREATE TABLE contact(username TEXT, nick_name TEXT, remark TEXT)")
                connection.execute("INSERT INTO contact VALUES('private_id','private_name','private_remark')")
                connection.execute('CREATE TABLE "Msg_private_hash"(local_id INTEGER)')
            before = db.read_bytes()
            report = inspector.inspect_root(root)
            self.assertEqual(report["status"], "inspected")
            self.assertEqual(before, db.read_bytes())
            self.assertEqual(list(db.parent.iterdir()), [db])
            self.assertNotIn("private_", str(report))
            self.assertEqual(report["accounts"][0]["databases"][0]["status"], "sqlite_main_schema_readable")

    def test_unknown_header_is_not_claimed_to_be_decrypted(self):
        with tempfile.TemporaryDirectory() as temporary:
            db = Path(temporary) / "contact.db"
            db.write_bytes(b"X" * 4096)
            self.assertEqual(inspector.inspect_database(db)["status"], "encrypted_or_unknown")
            db.write_bytes(b"")
            self.assertEqual(inspector.inspect_database(db)["status"], "empty_or_truncated")

    def test_wal_is_explicitly_incomplete_and_unchanged(self):
        with tempfile.TemporaryDirectory() as temporary:
            db = Path(temporary) / "session.db"
            connection = sqlite3.connect(db)
            try:
                connection.execute("PRAGMA journal_mode=WAL")
                connection.execute("CREATE TABLE recent_only(username TEXT)")
                connection.commit()
                before = {p.name: p.read_bytes() for p in Path(temporary).iterdir()}
                report = inspector.inspect_database(db)
                self.assertTrue(report["wal_present"])
                self.assertFalse(report["wal_replayed"])
                self.assertNotIn("recent_only", str(report["schema"]))
                self.assertEqual(before, {p.name: p.read_bytes() for p in Path(temporary).iterdir()})
            finally:
                connection.close()

    def test_missing_root(self):
        with tempfile.TemporaryDirectory() as temporary:
            self.assertEqual(inspector.inspect_root(Path(temporary) / "missing")["status"], "root_missing")


if __name__ == "__main__":
    unittest.main()
