#!/usr/bin/env python3
"""Check payload layout, bundle metadata, CPU and deployment target without Xcode."""
import json
import plistlib
import struct
import sys
import zipfile
from pathlib import Path

def main():
    path = Path(sys.argv[1])
    with zipfile.ZipFile(path) as archive:
        assert archive.testzip() is None
        info = plistlib.loads(archive.read('Payload/Live.app/Info.plist'))
        executable = archive.read('Payload/Live.app/' + info['CFBundleExecutable'])
        magic, cpu = struct.unpack_from('<II', executable)
        assert magic == 0xFEEDFACF, f'Expected thin 64-bit Mach-O: {magic:#x}'
        assert cpu == 0x0100000C, f'Expected ARM64, got {cpu:#x}'
        assert info['CFBundleIdentifier'] == 'app.personal.zb.live'
        assert info['MinimumOSVersion'] == '17.0'
        assert info['CFBundleDisplayName'] == '直播'
        assert info['CFBundleSupportedPlatforms'] == ['iPhoneOS']
        assert 'Assets.car' in {Path(name).name for name in archive.namelist()}
        assert not any(name.endswith(('.apk', '.dex', '.so')) for name in archive.namelist())
        summary = {'file': path.name, 'bundle': info['CFBundleIdentifier'], 'version': info['CFBundleShortVersionString'], 'build': info['CFBundleVersion'], 'minimum_ios': info['MinimumOSVersion'], 'cpu': 'arm64', 'bytes': path.stat().st_size}
        print(json.dumps(summary, indent=2, ensure_ascii=False))
        (path.parent / 'build-info.json').write_text(json.dumps(summary, indent=2, ensure_ascii=False) + '\n')

if __name__ == '__main__':
    main()
