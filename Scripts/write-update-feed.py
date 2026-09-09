#!/usr/bin/env python3
"""Create a static version feed for manual installation, without publishing it."""
import argparse
import json
import plistlib
from pathlib import Path
from urllib.parse import urlsplit

parser = argparse.ArgumentParser()
parser.add_argument("--app", type=Path, required=True)
parser.add_argument("--download-url", required=True)
parser.add_argument("--notes", type=Path, required=True)
parser.add_argument("--output", type=Path, required=True)
args = parser.parse_args()
url = urlsplit(args.download_url)
if url.scheme != "https" or not url.hostname or url.username or url.password:
    parser.error("Download page must use HTTPS without credentials")
with (args.app / "Contents/Info.plist").open("rb") as source:
    info = plistlib.load(source)
notes = args.notes.read_text(encoding="utf-8")
if len(notes) > 12000:
    parser.error("Release notes exceed 12000 characters")
record = {"version": info["CFBundleShortVersionString"], "build": int(info["CFBundleVersion"]),
          "minimumSystemVersion": info["LSMinimumSystemVersion"], "downloadURL": args.download_url,
          "releaseNotes": notes}
encoded = json.dumps(record, ensure_ascii=False, indent=2).encode("utf-8")
if len(encoded) > 65536:
    parser.error("Feed exceeds 64 KiB")
with args.output.open("xb") as target:
    target.write(encoded + b"\n")
