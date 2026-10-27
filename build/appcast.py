# SPDX-License-Identifier: AGPL-3.0-or-later
"""Schreibt den Sparkle-Update-Feed (appcast.xml) für ein Release.

    python3 build/appcast.py --version 1.0.0 --build 42 --url https://…/PDF-MRC.dmg \\
        --signature 'sparkle:edSignature="…" length="…"' --notes-file notes.md --out dist/appcast.xml

Der Feed enthält nur die neueste Version; er liegt als Release-Datei unter …/releases/latest/download/appcast.xml.
"""

import argparse
import html
import re
from datetime import datetime, timezone
from email.utils import format_datetime


def main() -> None:
    parser = argparse.ArgumentParser()
    for name in ("version", "build", "url", "signature", "notes-file", "out"):
        parser.add_argument(f"--{name}", required=True)
    parser.add_argument("--minimum-system", default="13.0.0")
    args = parser.parse_args()

    attributes = dict(re.findall(r'([\w:]+)="([^"]*)"', args.signature))
    if "sparkle:edSignature" not in attributes or "length" not in attributes:
        raise SystemExit(f"Signatur unvollständig: {args.signature!r}")

    lines = [line.strip() for line in open(args.notes_file, encoding="utf-8") if line.strip()]
    items = "".join(f"<li>{html.escape(line.lstrip('-* ').strip())}</li>" for line in lines)
    notes = f"<ul>{items}</ul>" if items else ""

    feed = f"""<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>PDF MRC</title>
    <item>
      <title>{html.escape(args.version)}</title>
      <pubDate>{format_datetime(datetime.now(timezone.utc))}</pubDate>
      <sparkle:version>{html.escape(args.build)}</sparkle:version>
      <sparkle:shortVersionString>{html.escape(args.version)}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>{html.escape(args.minimum_system)}</sparkle:minimumSystemVersion>
      <description><![CDATA[{notes}]]></description>
      <enclosure url="{html.escape(args.url)}" type="application/octet-stream"
                 sparkle:edSignature="{attributes['sparkle:edSignature']}" length="{attributes['length']}"/>
    </item>
  </channel>
</rss>
"""
    with open(args.out, "w", encoding="utf-8") as f:
        f.write(feed)


if __name__ == "__main__":
    main()
