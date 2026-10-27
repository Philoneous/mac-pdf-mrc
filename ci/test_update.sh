#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# =============================================================================
#  CI: echtes Sparkle-Update der installierten App.
#  Eine Kopie der App mit höherer Build-Nummer wird als DMG über einen lokalen Feed angeboten (eigener
#  Test-Schlüssel); die App muss sie im Hintergrund laden und beim Beenden installieren.
#
#  Umgebung: MRC_APP (installierte App). Braucht build/.sparkle-*/bin/sign_update aus dem Bauschritt.
# =============================================================================
set -Eeuo pipefail
cd "$(dirname "$0")/.."

APP="${MRC_APP:?}"
ID="io.github.philoneous.mac-pdf-mrc"
PORT=8765
SIGN="$(ls -d build/.sparkle-*/bin/sign_update | tail -1)"
W="$(mktemp -d)"
mkdir -p "$W/src" "$W/srv"
plist() { /usr/libexec/PlistBuddy -c "$1" "$2"; }
sparkle_log() { log show --last 10m --style compact --predicate 'subsystem BEGINSWITH "org.sparkle-project"' | tail -40; }

# Test-Schlüssel und lokalen Feed (nur für diesen Test) in die installierte App eintragen
# (Sparkle 2 liest den Feed aus dem Info.plist, nicht aus den Benutzereinstellungen)
SPARKLE_PRIVATE_KEY="$(head -c 32 /dev/urandom | base64)"
export SPARKLE_PRIVATE_KEY
public="$(python3 build/ed25519_public.py)"
plist "Set :SUPublicEDKey $public" "$APP/Contents/Info.plist"
plist "Set :SUFeedURL http://127.0.0.1:$PORT/appcast.xml" "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
old_build="$(plist 'Print :CFBundleVersion' "$APP/Contents/Info.plist")"

# „Neue“ Version: Kopie mit höherer Build-Nummer, als signiertes DMG mit Feed
ditto "$APP" "$W/src/PDF MRC.app"
plist "Set :CFBundleVersion 999999" "$W/src/PDF MRC.app/Contents/Info.plist"
plist "Set :CFBundleShortVersionString 99.0.0" "$W/src/PDF MRC.app/Contents/Info.plist"
codesign --force --sign - "$W/src/PDF MRC.app"
/bin/bash build/make_dmg.sh "$W/src" "$W/srv/update.dmg"
signature="$(printf '%s' "$SPARKLE_PRIVATE_KEY" | "$SIGN" --ed-key-file - "$W/srv/update.dmg")"
echo "- Testupdate" > "$W/notes.md"
python3 build/appcast.py --version 99.0.0 --build 999999 --url "http://127.0.0.1:$PORT/update.dmg" \
  --signature "$signature" --notes-file "$W/notes.md" --out "$W/srv/appcast.xml"
(cd "$W/srv" && exec python3 -m http.server "$PORT" --bind 127.0.0.1) >"$W/server.log" 2>&1 &
server=$!
trap 'kill $server 2>/dev/null || true' EXIT

# Letzte Prüfung liegt lange zurück → die App prüft sofort
defaults write "$ID" SUEnableAutomaticChecks -bool true
defaults write "$ID" SUAutomaticallyUpdate -bool true
defaults write "$ID" SULastCheckTime -date "2020-01-01 00:00:00 +0000"
open "$APP"

for _ in $(seq 1 60); do grep -q "GET /update.dmg" "$W/server.log" && break; sleep 2; done
if ! grep -q "GET /update.dmg" "$W/server.log"; then
  echo "Update nicht geladen. Server:"; cat "$W/server.log"; sparkle_log; exit 1
fi
echo "ok: Update im Hintergrund geladen"
sleep 15  # entpacken und vorbereiten

# Beenden (SIGTERM → NSApp.terminate) → Sparkle installiert
pkill -TERM -f "PDF MRC.app/Contents/MacOS/pdf-mrc" || true
for _ in $(seq 1 60); do
  [[ "$(plist 'Print :CFBundleVersion' "$APP/Contents/Info.plist")" == 999999 ]] && break
  sleep 2
done
new_build="$(plist 'Print :CFBundleVersion' "$APP/Contents/Info.plist")"
if [[ "$new_build" != 999999 ]]; then
  echo "Update nicht installiert (Build $new_build)"; sparkle_log; exit 1
fi
codesign --verify --deep --strict "$APP"
echo "ok: Update von Build $old_build auf 999999 installiert, Signatur gültig"

