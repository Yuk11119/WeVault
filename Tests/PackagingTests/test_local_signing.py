import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class LocalSigningTests(unittest.TestCase):
    def test_local_identity_and_explicit_override(self):
        for override in (None, '-', 'Explicit Certificate'):
            with self.subTest(override=override), tempfile.TemporaryDirectory() as directory:
                base = Path(directory)
                (base / 'Scripts').mkdir()
                shutil.copyfile(ROOT / 'Scripts/build-app.sh', base / 'Scripts/build-app.sh')
                (base / 'Scripts/configure-bundle.py').write_text('')
                (base / 'Packaging').mkdir()
                (base / 'Packaging/Info.plist').write_text('fixture')
                (base / 'bin').mkdir()
                (base / 'bin/WeVault').write_text('fixture executable')
                fake_home = base / 'user'
                config = fake_home / '.config/wevault'
                config.mkdir(parents=True)
                fingerprint = 'A' * 40
                (config / 'signing-identity').write_text(fingerprint + '\n')
                commands = {
                    'swift': 'if [[ "$*" == *--show-bin-path* ]]; then echo "$PWD/bin"; fi\n',
                    'plutil': 'exit 0\n',
                    'codesign': 'if [[ "$1" == --force ]]; then printf "%s\\n" "$3" > "$PWD/signed-with"; fi\n',
                }
                for name, contents in commands.items():
                    path = base / 'bin' / name
                    path.write_text('#!/bin/bash\n' + contents)
                    path.chmod(0o755)
                env = {**os.environ, 'HOME': str(fake_home),
                       'PATH': str(base / 'bin') + os.pathsep + os.environ['PATH']}
                for name in ('WEVAULT_SIGN_IDENTITY', 'WEVAULT_APP_OUTPUT', 'WEVAULT_ARCHS'):
                    env.pop(name, None)
                if override is not None:
                    env['WEVAULT_SIGN_IDENTITY'] = override
                result = subprocess.run(['bash', str(base / 'Scripts/build-app.sh')],
                                        env=env, capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual((base / 'signed-with').read_text().strip(),
                                 fingerprint if override is None else override)


if __name__ == '__main__':
    unittest.main()
