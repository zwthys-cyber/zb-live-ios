#!/usr/bin/env python3
"""Reproduce the static unpacking of the supplied, hash-identified APK.

The output is Android bytecode and Android ELF, not an iOS project or Dart source.
No APK code is executed and no network requests are made.
"""

from __future__ import annotations

import argparse
import hashlib
import hmac
import io
import json
from pathlib import Path
import re
import struct
import zipfile
import zlib

from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
from cryptography.hazmat.primitives.padding import PKCS7
from elftools.elf.elffile import ELFFile


EXPECTED_SHA256 = "467b1edee1dc658e9ed52a099a69f2969195350431c2a4ff0a01b46c111b7e73"
SHELL_LIBRARY = "assets/irn/arm64/lib8012d9ae47c7f010.so"
PACKAGE = "com.qingning.boy"


def rc4(key: bytes, data: bytes) -> bytes:
    state = list(range(256))
    j = 0
    for i in range(256):
        j = (j + state[i] + key[i % len(key)]) % 256
        state[i], state[j] = state[j], state[i]
    output = bytearray(len(data))
    i = j = 0
    for position, value in enumerate(data):
        i = (i + 1) % 256
        j = (j + state[i]) % 256
        state[i], state[j] = state[j], state[i]
        output[position] = value ^ state[(state[i] + state[j]) % 256]
    return bytes(output)


def xor(data: bytes, mask: bytes) -> bytes:
    return bytes(value ^ mask[i % len(mask)] for i, value in enumerate(data))


def derive(key: bytes, material: bytes) -> bytes:
    return hmac.new(key, material, hashlib.sha256).digest()


def aes_decrypt(data: bytes, key: bytes, iv: bytes) -> bytes:
    decryptor = Cipher(algorithms.AES(key), modes.CBC(iv)).decryptor()
    padded = decryptor.update(data) + decryptor.finalize()
    unpadder = PKCS7(128).unpadder()
    return unpadder.update(padded) + unpadder.finalize()


class ELF:
    def __init__(self, data: bytes):
        self.stream = io.BytesIO(data)
        self.elf = ELFFile(self.stream)

    def read(self, address: int, size: int) -> bytes:
        for segment in self.elf.iter_segments():
            start = segment["p_vaddr"]
            if segment["p_type"] == "PT_LOAD" and start <= address and address + size <= start + segment["p_filesz"]:
                self.stream.seek(segment["p_offset"] + address - start)
                return self.stream.read(size)
        raise ValueError(f"Unmapped ELF address: {address:#x}+{size}")

    def symbol_bytes(self, name: str) -> bytes:
        symbols = self.elf.get_section_by_name(".dynsym").get_symbol_by_name(name)
        if not symbols:
            raise ValueError(f"Missing ELF symbol: {name}")
        symbol = symbols[0]
        return self.read(symbol["st_value"], symbol["st_size"])


def write_json(path: Path, value: object) -> None:
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def repair_dex_hashes(data: bytearray) -> bytes:
    data[12:32] = hashlib.sha1(data[32:]).digest()
    struct.pack_into("<I", data, 8, zlib.adler32(data[12:]) & 0xFFFFFFFF)
    return bytes(data)


def restore_dex(data: bytes, pool: bytes, pool_offset: int, config_key: bytes) -> tuple[bytes, int]:
    from androguard.core.dex import DEX

    method_count = struct.unpack_from("<H", pool, pool_offset)[0]
    cursor = pool_offset + 2
    instructions = {}
    for _ in range(method_count):
        method_index, size = struct.unpack_from("<II", pool, cursor)
        cursor += 8
        if cursor + size > len(pool):
            raise ValueError("Instruction pool overrun")
        instructions[method_index] = pool[cursor:cursor + size]
        cursor += size
    dex = DEX(data)
    output = bytearray(data)
    restored = 0
    for cls in dex.get_classes():
        for method in cls.get_methods():
            index = method.get_method_idx()
            code_offset = method.get_code_off()
            if not code_offset or index not in instructions:
                continue
            payload = rc4(config_key + struct.pack("<I", index), instructions[index])
            offset = code_offset + 16
            expected_size = method.get_code().get_insns_size() * 2
            if len(payload) != expected_size or offset + len(payload) > len(output):
                raise ValueError(f"Invalid method size for {index}")
            output[offset:offset + len(payload)] = payload
            restored += 1
    return repair_dex_hashes(output), restored


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("apk", type=Path)
    parser.add_argument("--out", type=Path, default=Path("reverse-output"))
    args = parser.parse_args()
    digest = hashlib.sha256(args.apk.read_bytes()).hexdigest()
    if digest != EXPECTED_SHA256:
        raise SystemExit("APK SHA-256 does not match; offsets are specific to the supplied APK.")
    from loguru import logger
    logger.remove()
    from androguard.core.apk import APK

    destination = args.out
    destination.mkdir(parents=True, exist_ok=True)
    apk = APK(str(args.apk))
    (destination / "AndroidManifest.xml").write_bytes(apk.get_android_manifest_axml().get_xml())
    with zipfile.ZipFile(args.apk) as archive:
        library_data = archive.read(SHELL_LIBRARY)
        shell = ELF(library_data)
        shards = b"".join(shell.symbol_bytes(f"IS_KEY_SHARD{i}") for i in range(1, 4))
        encrypted_section = shell.elf.get_section_by_name(".7548966773801c00")
        decrypted = bytearray(library_data)
        offset = encrypted_section["sh_offset"]
        decrypted[offset:offset + encrypted_section["sh_size"]] = rc4(shards, encrypted_section.data())
        shell = ELF(bytes(decrypted))
        build_key = xor(shell.read(0x190DD, 16), shell.read(0x15450, 16))
        config_key = derive(shards, PACKAGE.encode() + b"_" + build_key)
        config_iv = derive(shards, b"irn-cfg-iv")[:16]
        shell_config = json.loads(aes_decrypt(archive.read("assets/.meta"), config_key, config_iv))
        write_json(destination / "shell-config.json", shell_config)
        (destination / "shell-decrypted.so").write_bytes(decrypted)
        full_key = shards + bytes.fromhex(shell_config["key_shard4"])
        shell_dex = archive.read("classes.dex")
        length = struct.unpack(">I", shell_dex[-4:])[0] ^ int(shell_config["tail_salt"], 16)
        offset = len(shell_dex) - length - shell_config["tail_pad"] - 8
        if offset < 112 or length <= 0:
            raise ValueError("Invalid encrypted DEX trailer")
        dex_zip = zlib.decompress(rc4(derive(full_key, b"irn-dexzip")[:16], shell_dex[offset:offset + length]))
        pool = aes_decrypt(archive.read("assets/" + shell_config["insns_store"]),
                           derive(full_key, b"irn-pool-key"), derive(full_key, b"irn-pool-iv")[:16])
        version, count = struct.unpack_from("<HH", pool)
        if version != 2:
            raise ValueError(f"Unexpected instruction pool version: {version}")
        indices = struct.unpack_from("<" + "I" * count, pool, 4)
        dex_stats = []
        dex_dir = destination / "dex"
        dex_dir.mkdir(exist_ok=True)
        with zipfile.ZipFile(io.BytesIO(dex_zip)) as nested:
            for name in nested.namelist():
                if not re.fullmatch(r"classes\d*\.dex", name):
                    raise ValueError(f"Unexpected DEX ZIP entry: {name}")
                number = int(name[7:-4] or "1") - 1
                data = nested.read(name)
                restored = 0
                if number < count:
                    data, restored = restore_dex(data, pool, indices[number], config_key)
                (dex_dir / name).write_bytes(data)
                dex_stats.append({"name": name, "bytes": len(data), "restored_methods": restored})

        packed_app = archive.read("assets/res/app.dat")
        if packed_app[:4] != b"QN1\0":
            raise ValueError("Unexpected Flutter library header")
        secret = b"dnQn9bX7Lp2mW4aRu8hE3nBqK1zT6cYf"
        flutter_app = xor(packed_app[24:], hashlib.sha256(secret + packed_app[8:24]).digest())
        if len(flutter_app) != struct.unpack_from("<I", packed_app, 4)[0] or flutter_app[:4] != b"\x7fELF":
            raise ValueError("Flutter library recovery failed")
        (destination / "libapp.so").write_bytes(flutter_app)
        strings = [match.group().decode("ascii") for match in re.finditer(rb"[\x20-\x7e]{4,}", flutter_app)]
        (destination / "flutter-ascii-strings.txt").write_text("\n".join(strings) + "\n", encoding="utf-8")
        api_candidates = sorted({s for s in strings if re.fullmatch(r"/?(?:api/|live/|platform/|room/|video/)[a-z0-9_/-]+", s)})
        write_json(destination / "api-path-candidates.json", api_candidates)

    write_json(destination / "summary.json", {
        "input_sha256": digest,
        "package": apk.get_package(),
        "application_name": apk.get_app_name(),
        "version_name": apk.get_androidversion_name(),
        "version_code": apk.get_androidversion_code(),
        "dex_files": dex_stats,
        "flutter_library_bytes": len(flutter_app),
        "flutter_library_sha256": hashlib.sha256(flutter_app).hexdigest(),
        "flutter_symbols": [s.name for s in ELF(flutter_app).elf.get_section_by_name(".dynsym").iter_symbols() if s.name],
        "result": "Restored Android DEX and ELF; Dart source and iOS binaries are not recovered.",
    })
    print(f"Recovered Android artifacts: {destination.resolve()}")
    for stat in dex_stats:
        print(f"  {stat['name']}: restored {stat['restored_methods']} methods")
    print("No Dart source or IPA was produced.")


if __name__ == "__main__":
    main()
