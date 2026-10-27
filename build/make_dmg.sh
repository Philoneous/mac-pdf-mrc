#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# DMG zum Ziehen in „Programme“: build/make_dmg.sh <Ordner mit „PDF MRC.app“> <Ziel.dmg>
set -Eeuo pipefail
trap 'echo "[FEHLER] ${BASH_SOURCE[0]##*/} Zeile $LINENO: $BASH_COMMAND (Exit $?)" >&2' ERR
SRC="${1:?Ordner fehlt}"
DMG="${2:?Ziel fehlt}"
ROOT="$(mktemp -d)/PDF MRC"
mkdir -p "$ROOT"
ditto "$SRC/PDF MRC.app" "$ROOT/PDF MRC.app"
ln -s /Applications "$ROOT/Applications"
rm -f "$DMG"
hdiutil create -quiet -volname "PDF MRC" -srcfolder "$ROOT" -fs HFS+ -format UDZO -imagekey zlib-level=9 "$DMG"
echo "[OK] $DMG ($(du -h "$DMG" | cut -f1))"
[[ -z "${GITHUB_ACTIONS:-}" ]] || echo "::notice title=DMG::$(du -h "$DMG" | cut -f1)"
