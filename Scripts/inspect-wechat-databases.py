#!/usr/bin/env python3
"""Inspect WeChat database structure without reading messages or modifying sources.

Only the checkpointed main SQLite file is inspected. WAL is deliberately not
replayed; a present WAL is reported so callers cannot mistake this for a complete
or current view. Non-SQLite headers do not by themselves prove encryption.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import sys


DEFAULT_ROOT = Path.home() / "Library/Containers/com.tencent.xinWeChat/Data/Documents/xwechat_files"
CATEGORIES = ("contact", "session", "message", "hardlink")


def inspect_database(path):
    result = {"database": path.name, "status": "unreadable"}
    try:
        result["size_bytes"] = path.stat().st_size
        with path.open("rb") as source:
            header = source.read(16)
        result["wal_present"] = path.with_name(path.name + "-wal").exists()
        if header != b"SQLite format 3\x00":
            result["status"] = "encrypted_or_unknown" if len(header) == 16 else "empty_or_truncated"
            return result
        # immutable prevents even shared-memory/lock-file writes in the source.
        connection = sqlite3.connect(path.resolve().as_uri() + "?mode=ro&immutable=1", uri=True)
        try:
            connection.execute("PRAGMA query_only=ON")
            schema = []
            for (name,) in connection.execute("SELECT name FROM sqlite_master WHERE type='table' ORDER BY name"):
                escaped = name.replace('"', '""')
                columns = [{"name": row[1], "type": row[2]} for row in connection.execute(f'PRAGMA table_info("{escaped}")')]
                # Conversation table suffixes are identifying data; keep only the pattern.
                display = "Msg_<redacted>" if name.startswith("Msg_") else "Chat_<redacted>" if name.startswith("Chat_") else name
                entry = {"table": display, "columns": columns}
                if entry not in schema:
                    schema.append(entry)
            result.update(status="sqlite_main_schema_readable", schema=schema,
                          view="checkpointed_main_only", wal_replayed=False)
        finally:
            connection.close()
    except PermissionError:
        result["status"] = "permission_denied"
    except (OSError, sqlite3.Error) as error:
        # Exception text may contain user names or paths.
        result.update(status="read_failed", error_type=type(error).__name__)
    return result


def inspect_root(root):
    root = Path(root).expanduser()
    if not root.is_dir():
        return {"status": "root_missing", "accounts": []}
    if (root / "db_storage").is_dir():
        accounts = [root]
    else:
        accounts = sorted(p for p in root.iterdir() if p.is_dir() and (p / "db_storage").is_dir())
    output = []
    for account in accounts:
        databases = []
        for category in CATEGORIES:
            directory = account / "db_storage" / category
            if not directory.is_dir():
                continue
            for path in sorted(directory.glob("*.db")):
                if path.is_symlink():
                    continue
                entry = inspect_database(path)
                entry["category"] = category
                databases.append(entry)
        output.append({"account_fingerprint": hashlib.sha256(account.name.encode()).hexdigest()[:16], "databases": databases})
    return {"status": "inspected" if output else "no_accounts", "accounts": output,
            "scope": "schema_only_no_message_or_contact_rows", "source_modified": False}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=DEFAULT_ROOT, help="xwechat_files or one account directory")
    parser.add_argument("--timeout", type=float, default=20, help="Maximum inspection time in seconds")
    parser.add_argument("--output", type=Path, help="New private JSON report (existing files are never overwritten)")
    parser.add_argument("--worker", action="store_true", help=argparse.SUPPRESS)
    args = parser.parse_args()
    if args.timeout <= 0:
        parser.error("--timeout must be positive")
    if args.worker:
        try:
            report = inspect_root(args.root)
        except PermissionError:
            report = {"status": "permission_denied", "accounts": []}
        except OSError as error:
            report = {"status": "read_failed", "error_type": type(error).__name__, "accounts": []}
        print(json.dumps(report, ensure_ascii=False))
        return
    try:
        process = subprocess.run([sys.executable, str(Path(__file__).resolve()), "--worker", "--root", str(args.root)],
                                 capture_output=True, text=True, timeout=args.timeout)
        report = json.loads(process.stdout) if process.returncode == 0 else {"status": "worker_failed", "accounts": []}
    except subprocess.TimeoutExpired:
        report = {"status": "access_timeout", "accounts": [],
                  "hint": "Directory access did not finish; check macOS access prompts. No database result is available."}
    encoded = json.dumps(report, ensure_ascii=False, indent=2) + "\n"
    if args.output:
        descriptor = os.open(args.output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(descriptor, "w") as destination:
            destination.write(encoded)
    else:
        print(encoded, end="")
    sys.exit(0 if report["status"] == "inspected" else 2)


if __name__ == "__main__":
    main()
