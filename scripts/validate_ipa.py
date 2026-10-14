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
        count = struct.unpack_from('<I', executable, 16)[0]
        offset = 32
        deployment = None
        signed = False
        for _ in range(count):
            command, size = struct.unpack_from('<II', executable, offset)
            assert size >= 8 and offset + size <= len(executable)
            if command == 0x32:  # LC_BUILD_VERSION
                platform, minimum, sdk = struct.unpack_from('<III', executable, offset + 8)
                assert platform == 2, f'Expected device iOS platform, got {platform}'
                assert minimum == 17 << 16, f'Unexpected Mach-O deployment version: {minimum:#x}'
                deployment = '17.0'
            if command == 0x1D:  # LC_CODE_SIGNATURE
                signature_offset, signature_size = struct.unpack_from('<II', executable, offset + 8)
                signed = signature_size > 0 and signature_offset + signature_size <= len(executable)
            offset += size
        assert deployment == '17.0' and signed, 'Missing iOS deployment metadata or ad-hoc signature'
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
