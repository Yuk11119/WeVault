import hashlib
import importlib.util
import json
import plistlib
import tempfile
import unittest
import zipfile
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('site_builder', ROOT / 'Website/build.py')
site = importlib.util.module_from_spec(spec)
spec.loader.exec_module(site)


class Links(HTMLParser):
    def __init__(self):
        super().__init__()
        self.urls = []
    def handle_starttag(self, tag, attrs):
        self.urls += [value for key, value in attrs if key in ('href', 'src')]


class WebsiteTests(unittest.TestCase):
    def fixture(self, base):
        source = base / 'release'
        contents = source / 'WeVault.app/Contents'
        contents.mkdir(parents=True)
        info = {'CFBundleIdentifier': 'online.wevault.mac', 'WeVaultDistributionChannel': 'public-unnotarized-beta',
                'CFBundleShortVersionString': '0.7.1', 'CFBundleVersion': '8', 'LSMinimumSystemVersion': '14.0',
                'WeVaultFeedbackEmail': 'support@example.test', 'WeVaultUpdateFeedURL': 'https://wevault.online/updates/beta.json'}
        data = plistlib.dumps(info)
        (contents / 'Info.plist').write_bytes(data)
        archive = source / 'WeVault-0.7.1-8-macos-universal.zip'
        with zipfile.ZipFile(archive, 'w') as zipped:
            zipped.writestr('WeVault.app/Contents/Info.plist', data)
        digest = hashlib.sha256(archive.read_bytes()).hexdigest()
        archive.with_suffix('.zip.sha256').write_text(f'{digest}  {archive.name}\n')
        (source / 'UNNOTARIZED-BETA.txt').write_text('Fixture')
        return source

    def test_links_disclosure_and_feed_match_verified_artifact(self):
        with tempfile.TemporaryDirectory() as temp:
            base = Path(temp)
            source = self.fixture(base)
            output = site.build(source, base / 'site')
            for page in output.rglob('*.html'):
                parser = Links()
                parser.feed(page.read_text())
                for value in parser.urls:
                    if value.startswith('/'):
                        path = output / urlsplit(value).path.lstrip('/')
                        if value.split('#')[0].endswith('/'):
                            path = path / 'index.html'
                        self.assertTrue(path.is_file(), value)
            feed = json.loads((output / 'updates/beta.json').read_text())
            self.assertEqual(feed['build'], 8)
            self.assertEqual(feed['downloadURL'], 'https://wevault.online/download/')
            download = (output / 'download/index.html').read_text()
            self.assertIn('未公证', download)
            self.assertIn('需邀请', download)
            self.assertIn('support@example.test', download)
            with self.assertRaises(FileExistsError):
                site.build(source, output)

    def test_incomplete_or_engineering_build_is_rejected(self):
        with tempfile.TemporaryDirectory() as temp:
            base = Path(temp)
            source = self.fixture(base)
            (source / 'BUILD-INCOMPLETE.txt').touch()
            with self.assertRaises(ValueError):
                site.build(source, base / 'site')
            self.assertFalse((base / 'site').exists())

    def test_tampered_archive_is_rejected_before_output(self):
        with tempfile.TemporaryDirectory() as temp:
            base = Path(temp)
            source = self.fixture(base)
            next(source.glob('*.zip')).write_bytes(b'corrupted')
            with self.assertRaises(ValueError):
                site.build(source, base / 'site')
            self.assertFalse((base / 'site').exists())
