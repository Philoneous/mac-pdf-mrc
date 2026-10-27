# SPDX-License-Identifier: AGPL-3.0-or-later
"""Kopiert Programme nach Contents/Helpers und alle ihre nicht-systemeigenen Bibliotheken nach Contents/Frameworks und
biegt die Verweise auf @rpath um, damit die App ohne Homebrew läuft.

    python3 build/bundle_dylibs.py <Contents/Helpers> <Contents/Frameworks> <Programm> …

Löst @rpath, @loader_path und @executable_path anhand der Originaldateien auf. Bricht mit einer Meldung ab, wenn eine
Bibliothek nicht gefunden wird (statt wie dylibbundler interaktiv nachzufragen).
"""

import os
import shutil
import subprocess
import sys
from pathlib import Path

SYSTEM = ("/usr/lib/", "/System/")


def run(*cmd: str) -> str:
    return subprocess.run(cmd, check=True, capture_output=True, text=True).stdout


def is_macho(path: Path) -> bool:
    return path.is_file() and "Mach-O" in run("file", "-b", str(path))


def dependencies(path: Path) -> list[str]:
    lines = run("otool", "-L", str(path)).splitlines()[1:]
    deps = [line.strip().split(" (compatibility")[0] for line in lines if line.strip()]
    own_id = run("otool", "-D", str(path)).splitlines()[1:]  # Bibliothek: erste Zeile von -L ist die eigene ID
    return [d for d in deps if not own_id or d != own_id[0].strip()]


def rpaths(path: Path) -> list[str]:
    out, result = run("otool", "-l", str(path)).splitlines(), []
    for i, line in enumerate(out):
        if line.strip() == "cmd LC_RPATH":
            result.append(out[i + 2].strip().split(" ")[1])
    return result


def resolve(dep: str, original: Path, executable: Path) -> Path:
    def expand(prefix_path: str) -> Path:
        return Path(prefix_path.replace("@loader_path", str(original.parent))
                    .replace("@executable_path", str(executable.parent)))

    if dep.startswith("@rpath/"):
        rest = dep[len("@rpath/"):]
        for rp in rpaths(original) + rpaths(executable):
            candidate = expand(rp) / rest
            if candidate.exists():
                return candidate.resolve()
        raise SystemExit(f"[FEHLER] {dep} aus {original} nicht gefunden (rpaths: {rpaths(original)})")
    candidate = expand(dep)
    if not candidate.exists():
        raise SystemExit(f"[FEHLER] {dep} aus {original} nicht gefunden")
    return candidate.resolve()


def main() -> None:
    helpers, frameworks = Path(sys.argv[1]), Path(sys.argv[2])
    helpers.mkdir(parents=True, exist_ok=True)
    frameworks.mkdir(parents=True, exist_ok=True)
    # Warteschlange: (Datei im Paket, ihre Originaldatei, Originaldatei des Programms, zu dem sie gehört)
    queue = []
    for program in sys.argv[3:]:
        original = Path(program).resolve()
        bundled = helpers / Path(program).name
        shutil.copy2(original, bundled)
        bundled.chmod(0o755)
        queue.append((bundled, original, original))
    originals = {}  # Name in Frameworks -> Originaldatei
    for bundled, original, executable in queue:
        for dep in dependencies(bundled):
            if dep.startswith(SYSTEM):
                continue
            source = resolve(dep, original, executable)
            name = Path(dep).name
            if name in originals and originals[name] != source:
                raise SystemExit(f"[FEHLER] Namenskonflikt {name}: {originals[name]} und {source}")
            target = frameworks / name
            if name not in originals:
                originals[name] = source
                shutil.copy2(source, target)
                target.chmod(0o755)
                run("install_name_tool", "-id", f"@rpath/{name}", str(target))
                queue.append((target, source, executable))
            run("install_name_tool", "-change", dep, f"@rpath/{name}", str(bundled))
        for rp in rpaths(bundled):
            run("install_name_tool", "-delete_rpath", rp, str(bundled))
        own_rpath = "@loader_path" if bundled.parent == frameworks else "@executable_path/../Frameworks"
        run("install_name_tool", "-add_rpath", own_rpath, str(bundled))
        print(f"  {bundled.name}")
    print(f"[OK] {len(originals)} Bibliotheken nach {frameworks}")


if __name__ == "__main__":
    main()
