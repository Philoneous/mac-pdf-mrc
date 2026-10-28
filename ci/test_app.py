# SPDX-License-Identifier: AGPL-3.0-or-later
"""CI-Test der installierten App im Kontextmenü-Modus (so, wie die Finder-Schnellaktion sie aufruft).

Aufruf mit dem Python von paperless-mrc (hat pymupdf, numpy, Pillow):
    "$(uv tool dir)/paperless-mrc/bin/python" ci/test_app.py <Arbeitsordner>
"""

import hashlib
import io
import json
import os
import plistlib
import shutil
import subprocess
import sys
from pathlib import Path

import numpy as np
import pymupdf
from PIL import Image

HOME = Path.home()
APP = Path(os.environ.get("MRC_APP", HOME / "Applications/PDF MRC.app"))  # DMG-Test: /Applications
BIN = APP / "Contents/MacOS/pdf-mrc"
SETTINGS = HOME / "Library/Application Support/mac-pdf-mrc/settings.json"
WORKFLOW = HOME / "Library/Services/Compress PDF (MRC).workflow"
LETTER = ["Stadtwerke Musterstadt GmbH", "Jahresabrechnung 2025 fuer Wasser und Waerme",
          "Sehr geehrte Damen und Herren,", "der Betrag von 1.284,50 EUR wird zum 1. Dezember faellig."]
PAPER = np.array([248, 246, 240], np.float32)


def scan_image(rng, lines=LETTER) -> Image.Image:
    """Seite mit farbigem Logo und Text, gerendert mit 200 dpi, auf getöntem, verrauschtem Papier."""
    doc = pymupdf.open()
    page = doc.new_page(width=595, height=842)
    page.draw_circle((100, 90), 30, color=None, fill=(0, 0.4, 0.7))
    for i, line in enumerate(lines):
        page.insert_text((72, 200 + i * 26), line, fontsize=14)
    pix = page.get_pixmap(dpi=200)
    a = np.frombuffer(pix.samples, np.uint8).reshape(pix.height, pix.width, 3).astype(np.float32)
    a = a * PAPER / 255 + rng.normal(0, 3, a.shape[:2])[..., None]
    return Image.fromarray(np.clip(a, 0, 255).astype(np.uint8))


def blank_image(rng) -> Image.Image:
    a = np.ones((2339, 1654, 3), np.float32) * PAPER + rng.normal(0, 3, (2339, 1654, 1))
    return Image.fromarray(np.clip(a, 0, 255).astype(np.uint8))


def write_scan(path: Path, images) -> Path:
    doc = pymupdf.open()
    for img in images:
        page = doc.new_page(width=595.28, height=841.89)
        buf = io.BytesIO()
        img.save(buf, "JPEG", quality=92, dpi=(200, 200))
        page.insert_image(page.rect, stream=buf.getvalue())
    doc.save(path)
    return path


def profile(**changes) -> dict:
    p = {"languages": "deu+eng", "rotate": True, "deskew": True, "removeBlank": True,
         "blankInkPercent": 0.005, "bgDownsample": 2, "bgRate": 200.0, "fitA4": True,
         "output": "copy", "suffix": " (komprimiert)"}
    p.update(changes)
    return p


def run_app(*files: Path, quick: dict) -> str:
    SETTINGS.parent.mkdir(parents=True, exist_ok=True)
    SETTINGS.write_text(json.dumps({"manual": profile(), "quickAction": quick}))
    res = subprocess.run([str(BIN), "--kontextmenue", *map(str, files)], capture_output=True, text=True,
                         timeout=900)
    print(res.stdout, res.stderr, sep="\n")
    assert res.returncode == 0, res.returncode
    return res.stdout


def sha(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main() -> None:
    tmp = Path(sys.argv[1])
    tmp.mkdir(parents=True, exist_ok=True)
    rng = np.random.default_rng(1)

    # Schnellaktion ist eingerichtet und ruft die App auf
    with open(WORKFLOW / "Contents/document.wflow", "rb") as f:
        cmd = plistlib.load(f)["actions"][0]["action"]["ActionParameters"]["COMMAND_STRING"]
    assert f'"{BIN}" --kontextmenue "$@"' == cmd, cmd
    with open(WORKFLOW / "Contents/Info.plist", "rb") as f:
        title = plistlib.load(f)["NSServices"][0]["NSMenuItem"]["default"]
    assert title == "Compress PDF (MRC)", title  # Runner: Systemsprache Englisch
    print("ok: Schnellaktion eingerichtet")

    # Update von ≤ 1.0.1: deutsch benannte Schnellaktion wird durch die englisch benannte ersetzt (Zustand bleibt)
    legacy = WORKFLOW.parent / "PDF komprimieren (MRC).workflow"
    shutil.copytree(WORKFLOW, legacy)
    shutil.rmtree(WORKFLOW)
    subprocess.run([str(BIN), "--schnellaktionen-einrichten"], check=True, timeout=60)
    assert WORKFLOW.exists() and not legacy.exists(), sorted(p.name for p in WORKFLOW.parent.iterdir())
    print("ok: alte Schnellaktion ersetzt")

    # Deutsche Systemsprache: Menütitel deutsch, Dateiname bleibt englisch
    subprocess.run(["defaults", "write", "io.github.philoneous.mac-pdf-mrc", "AppleLanguages", "-array", "de"], check=True)
    try:
        subprocess.run([str(BIN), "--schnellaktionen-einrichten"], check=True, timeout=60)
        with open(WORKFLOW / "Contents/Info.plist", "rb") as f:
            title = plistlib.load(f)["NSServices"][0]["NSMenuItem"]["default"]
        assert title == "PDF komprimieren (MRC)", title
    finally:
        subprocess.run(["defaults", "delete", "io.github.philoneous.mac-pdf-mrc", "AppleLanguages"], check=False)
        subprocess.run([str(BIN), "--schnellaktionen-einrichten"], check=True, timeout=60)
    print("ok: Menütitel deutsch")

    # Kopie: Scan wird komprimiert, leere Seite entfernt, Original unverändert; digitale PDF ohne Ergebnis
    scan = write_scan(tmp / "Brief ä.pdf", [scan_image(rng), blank_image(rng)])
    digital = tmp / "digital.pdf"
    doc = pymupdf.open()
    doc.new_page().insert_text((72, 72), "Digitales Dokument")
    doc.save(digital)
    before = sha(scan)
    out = run_app(scan, digital, quick=profile())
    result = tmp / "Brief ä (komprimiert).pdf"
    assert result.exists(), out
    assert result.stat().st_size < scan.stat().st_size / 3, (result.stat().st_size, scan.stat().st_size)
    assert sha(scan) == before
    with pymupdf.open(result) as d:
        assert d.page_count == 1, d.page_count
        assert "Jahresabrechnung" in d[0].get_text(), d[0].get_text()
    assert not (tmp / "digital (komprimiert).pdf").exists()
    assert "no scanned pages – unchanged" in out, out
    print("ok: Kopie")

    # Vorhandenes Ergebnis wird nicht überschrieben
    assert "already exists – skipped" in run_app(scan, quick=profile())
    print("ok: übersprungen")

    # Original ersetzen, leere Seiten behalten (prüft, dass Einstellungen bei paperless-mrc ankommen)
    replace = write_scan(tmp / "ersetzen.pdf", [scan_image(rng), blank_image(rng)])
    size = replace.stat().st_size
    run_app(replace, quick=profile(output="replace", removeBlank=False))
    assert replace.stat().st_size < size / 3, (replace.stat().st_size, size)
    with pymupdf.open(replace) as d:
        assert d.page_count == 2, d.page_count
    assert not list(tmp.glob(".*mrc-neu")), "Zwischendatei übrig"
    try:
        assert any(p.name.startswith("ersetzen") for p in (HOME / ".Trash").iterdir()), "nicht im Papierkorb"
        print("ok: Original im Papierkorb")
    except PermissionError:
        print("Hinweis: Papierkorb nicht lesbar (Datenschutz), Prüfung übersprungen")
    print("ok: ersetzen")

    # Neue Einstellungen kommen an: gemischte PDF bleibt bei abgeschalteter Option ohne Ergebnis
    mixed = write_scan(tmp / "gemischt.pdf", [scan_image(rng)])
    with pymupdf.open(mixed) as d:
        d.new_page().insert_text((72, 72), "Digitaler Anhang")
        d.saveIncr()
    out = run_app(mixed, quick=profile(mixedPdfs=False))
    assert not (tmp / "gemischt (komprimiert).pdf").exists(), out
    assert "contains digital pages" in out, out
    run_app(mixed, quick=profile())  # alte Einstellungsdatei ohne neue Schlüssel: Standard = bearbeiten
    assert (tmp / "gemischt (komprimiert).pdf").exists()
    print("ok: neue Einstellungen")

    # Eigenständige App: fehlende OCR-Sprache wird gemeldet, lässt sich nachladen und funktioniert danach
    if (APP / "Contents/Resources/tessdata").is_dir():
        french = write_scan(tmp / "francais.pdf", [scan_image(rng)])
        out = run_app(french, quick=profile(languages="deu+eng+fra"))
        assert "Language(s) not installed: fra" in out, out
        assert not (tmp / "francais (komprimiert).pdf").exists()
        res = subprocess.run([str(BIN), "--sprachen-laden", "fra"], capture_output=True, text=True, timeout=300)
        print(res.stdout, res.stderr)
        assert res.returncode == 0 and "installed" in res.stdout, res
        assert (HOME / "Library/Application Support/mac-pdf-mrc/tessdata/fra.traineddata").stat().st_size > 100_000
        out = run_app(french, quick=profile(languages="deu+eng+fra"))
        assert (tmp / "francais (komprimiert).pdf").exists(), out
        print("ok: Sprache nachgeladen")

    # Deutsche Oberfläche: Sprache nur für diese App auf Deutsch stellen
    subprocess.run(["defaults", "write", "io.github.philoneous.mac-pdf-mrc", "AppleLanguages", "-array", "de"], check=True)
    try:
        german = write_scan(tmp / "deutsch.pdf", [scan_image(rng), blank_image(rng)])
        out = run_app(german, quick=profile())
        assert "Seite(n), 1 leere Seite(n) entfernt, Text mit Tesseract erkannt" in out, out
    finally:
        subprocess.run(["defaults", "delete", "io.github.philoneous.mac-pdf-mrc", "AppleLanguages"], check=False)
    print("ok: deutsche Meldungen")


if __name__ == "__main__":
    main()
