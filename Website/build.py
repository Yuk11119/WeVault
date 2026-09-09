#!/usr/bin/env python3
"""Build an offline static site from a verified, versioned public-beta artifact."""
import argparse
import hashlib
import html
import json
import plistlib
import re
import shutil
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent


def build(source: Path, output: Path):
    if (source / 'BUILD-INCOMPLETE.txt').exists() or not (source / 'UNNOTARIZED-BETA.txt').is_file():
        raise ValueError('Only a completed explicitly unnotarized public-beta build may be published')
    info = plistlib.loads((source / 'WeVault.app/Contents/Info.plist').read_bytes())
    if info.get('CFBundleIdentifier') != 'online.wevault.mac' or info.get('WeVaultDistributionChannel') != 'public-unnotarized-beta' or 'WeVaultDevelopmentFixtureDirectory' in info:
        raise ValueError('Wrong application or isolation build')
    version, number = info['CFBundleShortVersionString'], str(info['CFBundleVersion'])
    if not re.fullmatch(r'\d+\.\d+\.\d+', version) or not re.fullmatch(r'[1-9]\d*', number):
        raise ValueError('Invalid version')
    email = info['WeVaultFeedbackEmail']
    if not re.fullmatch(r"[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+", email):
        raise ValueError('Invalid email')
    if info.get('WeVaultUpdateFeedURL') != 'https://wevault.online/updates/beta.json':
        raise ValueError('App update feed does not match website')
    name = f'WeVault-{version}-{number}-macos-universal.zip'
    archive = source / name
    with archive.open('rb') as payload:
        digest = hashlib.file_digest(payload, 'sha256').hexdigest()
    if (source / (name + '.sha256')).read_text().split() != [digest, name]:
        raise ValueError('Archive checksum mismatch')
    with zipfile.ZipFile(archive) as zipped:
        if zipped.testzip() or plistlib.loads(zipped.read('WeVault.app/Contents/Info.plist')) != info:
            raise ValueError('Archive contents differ from application metadata')
    notes = (ROOT / 'release-notes.txt').read_text()
    if len(notes) > 12000:
        raise ValueError('Release notes too long')
    output.mkdir(parents=True, exist_ok=False)
    (output / 'downloads').mkdir()
    shutil.copy2(archive, output / 'downloads' / name)
    shutil.copy2(source / (name + '.sha256'), output / 'downloads' / (name + '.sha256'))
    shutil.copytree(ROOT / 'static', output / 'assets')
    values = {'VERSION': version, 'BUILD': number, 'EMAIL': email, 'SHA256': digest,
              'ARCHIVE': name, 'MIN_OS': info['LSMinimumSystemVersion'],
              'SIZE': f'{archive.stat().st_size / 1_000_000:.1f}', 'NOTES': notes}
    layout = (ROOT / 'templates/layout.html').read_text()
    for template, title, route in [('home', '给微信腾出空间', '/'), ('download', '下载与安装', '/download/'),
                                   ('privacy', '数据与隐私', '/privacy/'), ('releases', '版本记录', '/releases/')]:
        body = (ROOT / f'templates/{template}.html').read_text()
        for key, value in values.items():
            body = body.replace(f'__{key}__', html.escape(value, quote=True))
        content = layout.replace('__TITLE__', title).replace('__PATH__', route).replace('__CONTENT__', body)
        if re.search(r'__[A-Z_]+__', content):
            raise ValueError('Unresolved template value')
        destination = output / route.lstrip('/') / 'index.html'
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_text(content)
    (output / 'updates').mkdir()
    release = {'version': version, 'build': int(number), 'minimumSystemVersion': info['LSMinimumSystemVersion'],
               'downloadURL': 'https://wevault.online/download/', 'releaseNotes': notes}
    encoded = json.dumps(release, ensure_ascii=False, indent=2) + '\n'
    if len(encoded.encode()) > 65536:
        raise ValueError('Oversized feed')
    (output / 'updates/beta.json').write_text(encoded)
    (output / 'robots.txt').write_text('User-agent: *\nAllow: /\nDisallow: /downloads/\n')
    return output


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--release', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    print(build(args.release, args.output))
