# SPDX-License-Identifier: AGPL-3.0-or-later
"""Prüft die Übersetzungen: Die Texte im Code sind englisch (Grundsprache). Jeder Text in L("…") und jeder
Oberflächentext aus App/Sources braucht einen Eintrag in App/Resources/de.lproj/Localizable.strings mit denselben
Platzhaltern (%@, %lld, …); keine verwaisten Einträge; im Code keine deutschen Texte (Umlaute, „…“).

    python3 ci/check_strings.py
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
STRINGS = ROOT / "App/Resources/de.lproj/Localizable.strings"
SPEC = re.compile(r"%(?:\d+\$)?[-+ #0]*\d*(?:\.\d+)?(?:ll|l|h)?[@dDuUxXoOfeEgGcCsSpaAF%]")
LITERAL = r'"((?:[^"\\]|\\.)*)"'


def parse_strings(path: Path) -> dict[str, str]:
    text = path.read_text(encoding="utf-8")
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    pairs = re.findall(LITERAL + r"\s*=\s*" + LITERAL + r"\s*;", text)
    return {k.encode().decode("unicode_escape").encode("latin-1").decode("utf-8"):
            v.encode().decode("unicode_escape").encode("latin-1").decode("utf-8") for k, v in pairs}


def swift_keys() -> set[str]:
    keys = set()
    for source in (ROOT / "App/Sources").glob("*.swift"):
        text = source.read_text(encoding="utf-8")
        keys.update(re.findall(r'\bL\(' + LITERAL, text))
        # SwiftUI-Initialisierer mit LocalizedStringKey (ohne Interpolation)
        keys.update(re.findall(r'\b(?:Text|Toggle|Button|Section|Picker|TextField|SecureField|LabeledContent|'
                               r'Stepper|Link)\(' + LITERAL, text))
        keys.update(re.findall(r'\.help\(' + LITERAL, text))
        # Namen der Schnellaktionen (QuickAction(name: …), Menütitel per L(name))
        keys.update(re.findall(r'QuickAction\(name: ' + LITERAL, text))
    return {k.replace('\\"', '"') for k in keys if "\\(" not in k}


def main() -> int:
    table = parse_strings(STRINGS)
    keys = swift_keys()
    errors = []
    for key in sorted(keys):
        if key not in table:
            errors.append(f"fehlt in de.lproj: {key!r}")
        elif sorted(SPEC.findall(key)) != sorted(SPEC.findall(table[key])):
            errors.append(f"Platzhalter passen nicht: {key!r} -> {table[key]!r}")
    for key in sorted(set(table) - keys):
        errors.append(f"nicht verwendet: {key!r}")
    for key in sorted(keys):
        if any(c in key for c in "äöüÄÖÜß„"):
            errors.append(f"deutscher Text im Code (Grundsprache ist Englisch): {key!r}")
    print("\n".join(errors) or f"ok: {len(keys)} Texte übersetzt")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
