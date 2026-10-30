# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Philoneous
"""Prüft das App-Paket: Jede Mach-O-Datei (Programme, Bibliotheken, Python-Erweiterungen) muss alle Bibliotheken
finden, die sie lädt – im Paket (@rpath, @loader_path, @executable_path) oder im System (/usr/lib, /System).
Fängt z. B. ein beim Ausdünnen entferntes, aber noch benötigtes Stück ab.

    python3 build/check_bundle.py <PDF MRC.app>
"""

import struct
import sys
from pathlib import Path

LC_LOAD_DYLIB, LC_LOAD_WEAK_DYLIB, LC_REEXPORT_DYLIB, LC_RPATH = 0xC, 0x80000018, 0x8000001F, 0x8000001C
SYSTEM = ("/usr/lib/", "/System/")


def load_commands(data: bytes):
    """(Abhängigkeiten, rpaths, schwach geladene) einer 64-bit-Mach-O-Datei (bei Universal: erster Teil)."""
    if data[:4] == b"\xca\xfe\xba\xbe":  # Universal: erster arm64-Teil
        count = struct.unpack_from(">I", data, 4)[0]
        for i in range(count):
            cputype, _, offset, size, _ = struct.unpack_from(">iiIII", data, 8 + 20 * i)
            if cputype == 0x0100000C:
                return load_commands(data[offset:offset + size])
        return None
    if data[:4] != b"\xcf\xfa\xed\xfe":
        return None
    ncmds = struct.unpack_from("<I", data, 16)[0]
    off, deps, rpaths, weak = 32, [], [], set()
    for _ in range(ncmds):
        cmd, size = struct.unpack_from("<II", data, off)
        if cmd in (LC_LOAD_DYLIB, LC_LOAD_WEAK_DYLIB, LC_REEXPORT_DYLIB, LC_RPATH):
            name_off = struct.unpack_from("<I", data, off + 8)[0]
            name = data[off + name_off: off + size].split(b"\0")[0].decode()
            if cmd == LC_RPATH:
                rpaths.append(name)
            else:
                deps.append(name)
                if cmd == LC_LOAD_WEAK_DYLIB:
                    weak.add(name)
        off += size
    return deps, rpaths, weak


def main() -> None:
    app = Path(sys.argv[1]).resolve()
    executable = app / "Contents" / "MacOS"
    problems, checked = [], 0
    for f in sorted(app.rglob("*")):
        if f.is_symlink() or not f.is_file() or f.stat().st_size < 4096:
            continue
        with open(f, "rb") as fh:
            head = fh.read(4)
        if head not in (b"\xcf\xfa\xed\xfe", b"\xca\xfe\xba\xbe"):
            continue
        parsed = load_commands(f.read_bytes())
        if parsed is None:
            continue
        checked += 1
        deps, rpaths, weak = parsed

        def expand(path: str) -> Path:
            return Path(path.replace("@loader_path", str(f.parent)).replace("@executable_path", str(executable)))

        for dep in deps:
            if dep.startswith(SYSTEM) or dep in weak:
                continue
            if dep.startswith("@rpath/"):
                rest = dep[len("@rpath/"):]
                found = any((expand(rp) / rest).exists() for rp in rpaths)
            elif dep.startswith(("@loader_path", "@executable_path")):
                found = expand(dep).exists()
            else:
                found = False  # absoluter Pfad außerhalb des Systems (z. B. Homebrew) – im Paket nicht erlaubt
            if not found:
                problems.append(f"{f.relative_to(app)} → {dep}")
    if problems:
        print("[FEHLER] Fehlende oder externe Bibliotheken:\n  " + "\n  ".join(problems), file=sys.stderr)
        sys.exit(1)
    print(f"[OK] {checked} Mach-O-Dateien, alle Bibliotheken auflösbar")


if __name__ == "__main__":
    main()
