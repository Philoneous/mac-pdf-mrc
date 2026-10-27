# SPDX-License-Identifier: AGPL-3.0-or-later
"""CI-Test „An Paperless senden“ / „Komprimieren und an Paperless senden“ gegen ci/paperless_mock.py.

Aufruf mit dem Python von paperless-mrc:
    "$(uv tool dir)/paperless-mrc/bin/python" ci/test_paperless.py <Arbeitsordner>
"""

import io
import json
import plistlib
import subprocess
import sys
from pathlib import Path

import numpy as np
import pymupdf
from paperless_mock import TOKEN, Paperless
from test_app import BIN, SETTINGS, blank_image, profile, scan_image, sha, write_scan

RESOURCES = BIN.parent.parent / "Resources"


def run(args: list[str], stdin: str | None = None) -> str:
    """Startet die App; hängt sie, wird vor dem Abbruch ein Stack-Trace (sample) ausgegeben."""
    proc = subprocess.Popen([str(BIN), *args], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, text=True)
    try:
        out, _ = proc.communicate(stdin, timeout=180)
    except subprocess.TimeoutExpired:
        trace = subprocess.run(["sample", str(proc.pid), "2"], capture_output=True, text=True).stdout
        proc.kill()
        lines = [line for line in trace.splitlines() if any(k in line for k in ("Thread", "Sec", "Paperless",
                                                                                   "Semaphore", "URLSession", "main"))]
        raise AssertionError("App hängt: " + " ".join(args) + "\n" + "\n".join(lines[:60]))
    print(out)
    assert proc.returncode == 0, (proc.returncode, out)
    return out


def set_token(token: str) -> None:
    run(["--paperless-token"], stdin=token + "\n")


def run_app(flag: str, *files: Path, url: str) -> str:
    SETTINGS.parent.mkdir(parents=True, exist_ok=True)
    SETTINGS.write_text(json.dumps({"manual": profile(), "quickAction": profile(), "paperlessURL": url}))
    return run([flag, *map(str, files)])


def main() -> None:
    tmp = Path(sys.argv[1])
    tmp.mkdir(parents=True, exist_ok=True)
    rng = np.random.default_rng(2)
    server = Paperless()
    url = server.start()

    # Vorlagen der drei Schnellaktionen liegen in der App
    for name, flag in (("PDF komprimieren (MRC)", "--kontextmenue"), ("An Paperless senden", "--paperless"),
                       ("Komprimieren und an Paperless senden", "--paperless-komprimiert")):
        with open(RESOURCES / f"{name}.workflow/Contents/document.wflow", "rb") as f:
            cmd = plistlib.load(f)["actions"][0]["action"]["ActionParameters"]["COMMAND_STRING"]
        assert cmd == f'"{BIN}" {flag} "$@"', cmd
        with open(RESOURCES / f"{name}.workflow/Contents/Info.plist", "rb") as f:
            assert plistlib.load(f)["NSServices"][0]["NSMenuItem"]["default"] == name
    print("ok: Vorlagen der Schnellaktionen")

    scan = write_scan(tmp / "Brief ä.pdf", [scan_image(rng), blank_image(rng)])
    scan2 = write_scan(tmp / "Rechnung.pdf", [scan_image(rng), blank_image(rng)])
    digital = tmp / "digital.pdf"
    doc = pymupdf.open()
    doc.new_page().insert_text((72, 72), "Digitales Dokument")
    doc.save(digital)
    hashes = {p: sha(p) for p in (scan, scan2, digital)}
    files_before = sorted(p.name for p in tmp.iterdir())

    # Nicht eingerichtet
    assert "nicht eingerichtet" in run_app("--paperless", scan, url="")
    assert not server.uploads
    print("ok: nicht eingerichtet")

    set_token(TOKEN)

    # Originale senden (zwei Dateien in einem Aufruf)
    out = run_app("--paperless", scan, digital, url=url + "/")
    assert "In Paperless angelegt (Dokument #42)" in out and "In Paperless angelegt (Dokument #43)" in out, out
    assert server.uploads[0] == ("Brief ä.pdf", scan.read_bytes())
    assert server.uploads[1] == ("digital.pdf", digital.read_bytes())
    print("ok: Original senden")

    # Komprimiert senden: kleiner, leere Seite entfernt, Text vorhanden
    out = run_app("--paperless-komprimiert", scan2, url=url)
    assert "Komprimiert (" in out and "Dokument #44" in out, out
    name, data = server.uploads[-1]
    assert name == "Rechnung.pdf"
    assert len(data) < scan2.stat().st_size / 3, (len(data), scan2.stat().st_size)
    with pymupdf.open(stream=io.BytesIO(data), filetype="pdf") as d:
        assert d.page_count == 1, d.page_count
        assert "Jahresabrechnung" in d[0].get_text()
    print("ok: komprimiert senden")

    # Nicht verkleinerbar: Original wird gesendet (digital.pdf ist schon als #43 vorhanden → Duplikat)
    out = run_app("--paperless-komprimiert", digital, url=url)
    assert "Original gesendet" in out and "Duplikat von Dokument #43" in out, out
    assert server.uploads[-1][1] == digital.read_bytes()
    print("ok: nicht verkleinerbar, Duplikat")

    # Dateien auf dem Mac unverändert, nichts Neues angelegt
    assert all(sha(p) == h for p, h in hashes.items())
    assert sorted(p.name for p in tmp.iterdir()) == files_before, sorted(p.name for p in tmp.iterdir())
    print("ok: lokale Dateien unverändert")

    # Falsches Token
    set_token("falsch")
    count = len(server.uploads)
    assert "Zugriff verweigert (HTTP 401)" in run_app("--paperless", scan, url=url)
    assert len(server.uploads) == count
    print("ok: falsches Token")


if __name__ == "__main__":
    main()
