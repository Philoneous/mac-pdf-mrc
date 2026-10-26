#!/usr/bin/env bash
# CI: App starten und je Reiter ein Bildschirmfoto aufnehmen (shots/*.png).
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
  pkill -f "PDF MRC.app/Contents/MacOS/pdf-mrc" || true
  sleep 3
}

shot umwandeln
shot kontextmenue
