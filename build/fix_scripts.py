# SPDX-License-Identifier: AGPL-3.0-or-later
"""Startskripte in python/bin (recode_pdf, pdf-to-hocr …) auf das Python der App umstellen (über PATH, python/bin
steht dort vorn), damit sie nach dem Verschieben des App-Pakets laufen.

pip/uv schreiben zwei Formen:
  1. erste Zeile „#!/…/python3“
  2. bei Leerzeichen im Pfad (der Build-Ordner heißt „PDF MRC.app“) eine Shell-Hülle:
       #!/bin/sh
       '''exec' '/…/python3' "$0" "$@"
       ' '''
     Die drei Zeilen werden durch „#!/usr/bin/env python3“ ersetzt.

    python3 build/fix_scripts.py <python/bin>
"""

import sys
from pathlib import Path

SHEBANG = b"#!/usr/bin/env python3"


def fix(path: Path) -> bool:
    data = path.read_bytes()
    if not data.startswith(b"#!"):
        return False
    lines = data.split(b"\n")
    if lines[0].startswith(b"#!/bin/sh") and len(lines) > 2 and lines[1].startswith(b"'''exec'"):
        lines = [SHEBANG] + lines[3:]
    elif b"python" in lines[0] and lines[0] != SHEBANG:
        lines[0] = SHEBANG
    else:
        return False
    path.write_bytes(b"\n".join(lines))
    return True


def main() -> None:
    changed = [f.name for f in sorted(Path(sys.argv[1]).iterdir())
               if f.is_file() and not f.is_symlink() and fix(f)]
    print(f"[OK] {len(changed)} Skripte umgestellt: {', '.join(changed)}")


if __name__ == "__main__":
    main()
