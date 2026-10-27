#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# =============================================================================
#  Veröffentlicht ein Release (nur in GitHub Actions bei einem Tag v*): signiert das DMG für Sparkle,
#  schreibt appcast.xml und legt das GitHub-Release mit DMG und Feed an.
#
#  Umgebung: GITHUB_REF_NAME (Tag), GITHUB_REPOSITORY, GH_TOKEN, SPARKLE_PRIVATE_KEY (Repository-Secret)
# =============================================================================
set -Eeuo pipefail
trap 'echo "[FEHLER] ${BASH_SOURCE[0]##*/} Zeile $LINENO: $BASH_COMMAND (Exit $?)" >&2' ERR
cd "$(dirname "$0")/.."

die() { printf '[FEHLER] %s\n' "$*" >&2; exit 1; }

TAG="${GITHUB_REF_NAME:?Tag fehlt}"
VERSION="${TAG#v}"
DMG="dist/PDF-MRC.dmg"
APP="dist/PDF MRC.app"
[[ -n "${SPARKLE_PRIVATE_KEY:-}" ]] \
  || die "Secret SPARKLE_PRIVATE_KEY fehlt (GitHub: Settings → Secrets and variables → Actions)."
SIGN="$(ls -d build/.sparkle-*/bin/sign_update | tail -1)"
[[ -x "$SIGN" ]] || die "sign_update nicht gefunden (wird von build_app.sh geladen)."

# Version im DMG muss zum Tag passen
built="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
[[ "$built" == "$VERSION" ]] || die "App-Version $built passt nicht zum Tag $TAG."
build_number="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")"

# Signieren und Gegenprobe
signature="$(printf '%s' "$SPARKLE_PRIVATE_KEY" | "$SIGN" --ed-key-file - "$DMG")"
ed="$(sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p' <<<"$signature")"
printf '%s' "$SPARKLE_PRIVATE_KEY" | "$SIGN" --verify --ed-key-file - "$DMG" "$ed" || die "Signatur ungültig."
# Der private Schlüssel muss zum öffentlichen Schlüssel in der App passen
public_in_app="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$APP/Contents/Info.plist")"
[[ "$(python3 build/ed25519_public.py)" == "$public_in_app" ]] \
  || die "SPARKLE_PRIVATE_KEY passt nicht zu SUPublicEDKey der App."

# Änderungen seit dem letzten Tag als Release-Notizen
previous="$(git describe --tags --abbrev=0 "$TAG^" 2>/dev/null || true)"
git log --no-merges --format='- %s' "${previous:+$previous..}$TAG" | head -n 40 > dist/notes.md

python3 build/appcast.py --version "$VERSION" --build "$build_number" \
  --url "https://github.com/$GITHUB_REPOSITORY/releases/download/$TAG/PDF-MRC.dmg" \
  --signature "$signature" --notes-file dist/notes.md --out dist/appcast.xml

{
  echo "**Installation:** \`PDF-MRC.dmg\` laden, öffnen, „PDF MRC“ in „Programme“ ziehen. Beim ersten Start:"
  echo "Systemeinstellungen → Datenschutz & Sicherheit → „Dennoch öffnen“ (die App ist nicht notarisiert)."
  echo "Bestehende Installationen aktualisieren sich automatisch."
  echo
  echo "**Install:** download \`PDF-MRC.dmg\`, open it, drag “PDF MRC” to Applications. On first launch: System"
  echo "Settings → Privacy & Security → “Open Anyway” (the app is not notarised). Existing installations update themselves."
  echo
  echo "### Änderungen / Changes"
  cat dist/notes.md
} > dist/release.md

gh release create "$TAG" "$DMG" dist/appcast.xml --title "PDF MRC $VERSION" --notes-file dist/release.md
echo "[OK] Release $TAG veröffentlicht (Build $build_number)"
