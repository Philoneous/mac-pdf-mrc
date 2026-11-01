# SPDX-License-Identifier: AGPL-3.0-or-later
"""CHANGELOG.md: the release notes (GitHub release and Sparkle update window) come from it, in English only.

    python3 ci/check_changelog.py              check: structure, no German text
    python3 ci/check_changelog.py --notes      print the "Unreleased" entries; fails if there are none
    python3 ci/check_changelog.py --rollover 1.2.0 2026-11-01 notes.md
                                               move the published entries (notes.md) from "Unreleased" to a new
                                               section "1.2.0 – 2026-11-01"; entries added in the meantime stay
"""

import re
import sys
from pathlib import Path

PATH = Path(__file__).resolve().parent.parent / "CHANGELOG.md"
UNRELEASED = "## Unreleased"
# Umlauts, German quotes and frequent German words (case-sensitive, so "MIT" or "Die" in English stay allowed)
GERMAN = re.compile(r"[äöüÄÖÜß„]|\b(?:und|der|das|nicht|für|mit|wird|werden|oder|bei|auf|eine[nmrs]?|jetzt|"
                    r"bleibt|statt|beim|Datei|Seiten?|Einstellung(?:en)?|Fehler|neu)\b")


def unreleased_entries(text: str) -> list[str]:
    match = re.search(rf"^{UNRELEASED}\s*$(.*?)(?=^## |\Z)", text, flags=re.M | re.S)
    if not match:
        raise SystemExit(f"CHANGELOG.md: section '{UNRELEASED}' is missing")
    return [line for line in match.group(1).splitlines() if line.startswith("- ")]


def rollover(text: str, version: str, date: str, published: list[str]) -> str:
    head, _, rest = text.partition(UNRELEASED)
    following = re.search(r"^## ", rest, flags=re.M)
    section, rest = (rest[:following.start()], rest[following.start():]) if following else (rest, "")
    kept = [line for line in section.splitlines() if line.strip() and line not in published]
    blocks = [UNRELEASED, *(["\n".join(kept)] if kept else []), f"## {version} – {date}", "\n".join(published)]
    return head + "\n\n".join(blocks) + "\n" + ("\n" + rest if rest else "")


def check(text: str) -> list[str]:
    errors = []
    unreleased_entries(text)
    for number, line in enumerate(text.splitlines(), 1):
        if line.startswith("## ") and line != UNRELEASED and not re.fullmatch(r"## \d+\.\d+\.\d+ – \d{4}-\d{2}-\d{2}", line):
            errors.append(f"CHANGELOG.md:{number}: heading must be '{UNRELEASED}' or '## 1.2.3 – YYYY-MM-DD': {line}")
        if found := GERMAN.search(line):
            errors.append(f"CHANGELOG.md:{number}: German text ({found.group(0)!r}) – the changelog is English only: {line}")
    return errors


def main(argv: list[str]) -> int:
    text = PATH.read_text(encoding="utf-8")
    errors = check(text)
    if errors:
        print("\n".join(errors), file=sys.stderr)
        return 1
    if argv[:1] == ["--notes"]:
        entries = unreleased_entries(text)
        if not entries:
            print(f"CHANGELOG.md: no entries under '{UNRELEASED}' – describe the changes of this release there "
                  "(English, one line per change, for users)", file=sys.stderr)
            return 1
        print("\n".join(entries))
    elif argv[:1] == ["--rollover"] and len(argv) == 4:
        PATH.write_text(rollover(text, argv[1], argv[2], Path(argv[3]).read_text(encoding="utf-8").splitlines()),
                        encoding="utf-8")
    elif argv:
        print(__doc__, file=sys.stderr)
        return 2
    else:
        print(f"ok: CHANGELOG.md ({len(unreleased_entries(text))} unreleased entries)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
