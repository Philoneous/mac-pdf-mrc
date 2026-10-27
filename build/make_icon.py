# SPDX-License-Identifier: AGPL-3.0-or-later
"""Erzeugt App/Icon/AppIcon.icns aus App/Icon/icon.svg (nach Änderungen am Logo einmal ausführen und einchecken).

Gerendert wird mit Chromium (Playwright), weil es den Schatten (feDropShadow) korrekt darstellt; die .icns-Datei
wird direkt geschrieben (PNG-Einträge), damit das ohne iconutil auch unter Linux geht.

    python3 build/make_icon.py
"""

import struct
from pathlib import Path

from playwright.sync_api import sync_playwright

ROOT = Path(__file__).resolve().parent.parent
SVG = ROOT / "App/Icon/icon.svg"
OUT = ROOT / "App/Icon/AppIcon.icns"

# Eintragstyp → Kantenlänge in Pixeln (alle Typen enthalten PNG-Daten)
TYPES = [(b"icp4", 16), (b"ic11", 32), (b"icp5", 32), (b"ic12", 64), (b"ic07", 128), (b"ic13", 256),
         (b"ic08", 256), (b"ic14", 512), (b"ic09", 512), (b"ic10", 1024)]


def render(sizes: set[int]) -> dict[int, bytes]:
    svg = SVG.read_text(encoding="utf-8")
    pngs = {}
    with sync_playwright() as p:
        browser = p.chromium.launch()
        for size in sorted(sizes):
            page = browser.new_page(viewport={"width": size, "height": size})
            page.set_content(f'<html><body style="margin:0;background:transparent">'
                             f'<div style="width:{size}px;height:{size}px">'
                             f'{svg.replace("<svg ", f"<svg style=\"width:{size}px;height:{size}px;display:block\" ", 1)}'
                             f"</div></body></html>")
            pngs[size] = page.screenshot(omit_background=True, clip={"x": 0, "y": 0, "width": size, "height": size})
            page.close()
        browser.close()
    return pngs


def main() -> None:
    pngs = render({size for _, size in TYPES})
    body = b"".join(kind + struct.pack(">I", 8 + len(pngs[size])) + pngs[size] for kind, size in TYPES)
    OUT.write_bytes(b"icns" + struct.pack(">I", 8 + len(body)) + body)
    print(f"{OUT.relative_to(ROOT)}: {OUT.stat().st_size // 1024} KB")


if __name__ == "__main__":
    main()
