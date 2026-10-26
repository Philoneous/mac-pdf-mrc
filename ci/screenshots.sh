#!/usr/bin/env bash
# CI: App starten und je Reiter ein Bildschirmfoto aufnehmen (shots/*.png). Zusätzlich verkleinert als
# Base64 in Hinweis-Annotationen, damit es auch ohne Zugriff auf Artefakte abrufbar ist.
set -euo pipefail
APP="$HOME/Applications/PDF MRC.app"
mkdir -p shots

shot() {
  defaults write io.github.philoneous.mac-pdf-mrc tab "$1"
  open --stdout "shots/app-$1.log" --stderr "shots/app-$1.log" "$APP"
  sleep 10
  if ! pgrep -f "PDF MRC.app/Contents/MacOS/pdf-mrc" >/dev/null; then
    echo "App läuft nicht (Reiter $1)"
    cat "shots/app-$1.log" || true
    ls -t ~/Library/Logs/DiagnosticReports 2>/dev/null | head -3
    exit 1
  fi
  screencapture -x "shots/$1.png"
  sips -Z 1100 -s format jpeg -s formatOptions 60 "shots/$1.png" --out "shots/$1.jpg" >/dev/null
  base64 -i "shots/$1.jpg" | tr -d '\n' | fold -w 30000 | nl -n ln -w 1 -s ' ' | while read -r n chunk; do
    echo "::notice title=shot-$1-$n::$chunk"
  done
  pkill -f "PDF MRC.app/Contents/MacOS/pdf-mrc" || true
  sleep 3
}

shot umwandeln
shot kontextmenue
