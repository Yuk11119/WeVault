import importlib.util
import json
import os
import shutil
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("bundle_config", ROOT / "Scripts/configure-bundle.py")
config = importlib.util.module_from_spec(spec)
spec.loader.exec_module(config)


class ReleaseTests(unittest.TestCase):
    values = {"WEVAULT_VERSION": "0.7.0", "WEVAULT_BUILD": "7",
              "WEVAULT_FEEDBACK_EMAIL": "support@example.test",
              "WEVAULT_UPDATE_FEED_URL": "https://updates.example.test/beta.json"}

    def test_distribution_requires_every_setting(self):
        for missing in self.values:
            with self.subTest(missing=missing), patch.dict(os.environ, {k: v for k, v in self.values.items() if k != missing}, clear=True):
                with self.assertRaises(ValueError):
                    config.settings(True)

    def test_valid_settings(self):
        with patch.dict(os.environ, self.values, clear=True):
            self.assertEqual(config.settings(True)["CFBundleVersion"], "7")

    def test_bad_urls_email_and_version(self):
        for key, value in [("WEVAULT_BUILD", "0"), ("WEVAULT_VERSION", "preview"),
                           ("WEVAULT_FEEDBACK_EMAIL", "support@example.test\nBcc:other@example.test"),
                           ("WEVAULT_UPDATE_FEED_URL", "http://unsafe.example.test"),
                           ("WEVAULT_UPDATE_FEED_URL", "https://user:password@example.test")]:
            with self.subTest(key=key, value=value), patch.dict(os.environ, {**self.values, key: value}, clear=True):
                with self.assertRaises(ValueError):
                    config.settings(True)

    def test_feed_matches_bundle_and_preserves_existing_output(self):
        with tempfile.TemporaryDirectory(prefix="WeVault-P7-packaging-") as directory:
            base = Path(directory)
            app = base / "WeVault.app"
            (app / "Contents").mkdir(parents=True)
            (app / "Contents/Info.plist").write_bytes((ROOT / "Packaging/Info.plist").read_bytes())
            notes = base / "notes.txt"
            notes.write_text("Beta changes\n", encoding="utf-8")
            output = base / "beta.json"
            command = ["python3", str(ROOT / "Scripts/write-update-feed.py"), "--app", str(app),
                       "--download-url", "https://downloads.example.test/beta", "--notes", str(notes), "--output", str(output)]
            subprocess.run(command, check=True, capture_output=True)
            self.assertEqual(json.loads(output.read_text())["build"], 7)
            before = output.read_bytes()
            self.assertNotEqual(subprocess.run(command, capture_output=True).returncode, 0)
            self.assertEqual(output.read_bytes(), before)

    def test_failed_packaging_invalidates_previous_release(self):
        # Isolated fake tools exercise orchestration, never signing or contacting Apple.
        for failure in ("configuration", "build", "checksum", None):
            with self.subTest(failure=failure), tempfile.TemporaryDirectory(prefix="WeVault-P7-release-") as directory:
                base = Path(directory)
                scripts = base / "Scripts"
                scripts.mkdir()
                shutil.copyfile(ROOT / "Scripts/package-beta.sh", scripts / "package-beta.sh")
                (scripts / "configure-bundle.py").write_text(
                    "import sys\nsys.exit(%d)\n" % (1 if failure == "configuration" else 0))
                build = scripts / "build-app.sh"
                build.write_text("#!/bin/bash\nexit %d\n" % (1 if failure == "build" else 0))
                build.chmod(0o755)
                fakebin = base / "bin"
                fakebin.mkdir()
                commands = {
                    "security": 'echo \'1) ABC "Developer ID Application: Fixture"\'\n',
                    "lipo": "exit 0\n", "codesign": "exit 0\n", "spctl": "exit 0\n",
                    "ditto": 'printf new-archive > "${@: -1}"\n',
                    "xcrun": 'if [[ "$1" == notarytool ]]; then echo \'{"status":"Accepted"}\'; fi\n',
                    "shasum": "exit 1\n" if failure == "checksum" else "echo fixture-checksum\n",
                }
                for name, content in commands.items():
                    tool = fakebin / name
                    tool.write_text("#!/bin/bash\n" + content)
                    tool.chmod(0o755)
                output = base / ".build/beta/notarize"
                output.mkdir(parents=True)
                (output / "WeVault.zip").write_text("previous-approved-archive")
                env = {**os.environ, "PATH": str(fakebin) + os.pathsep + os.environ["PATH"],
                       "WEVAULT_SIGN_IDENTITY": "Developer ID Application: Fixture",
                       "WEVAULT_NOTARY_PROFILE": "fixture"}
                result = subprocess.run(["/bin/bash", str(scripts / "package-beta.sh"), "notarize"],
                                        env=env, capture_output=True, text=True)
                marker = output / "NOT-FOR-DISTRIBUTION.txt"
                if failure:
                    self.assertNotEqual(result.returncode, 0)
                    self.assertTrue(marker.exists())
                else:
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertFalse(marker.exists())
                    self.assertTrue((output / "WeVault.zip.sha256").exists())


if __name__ == "__main__":
    unittest.main()
