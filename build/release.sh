#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# =============================================================================
#  Veröffentlicht ein Release (nur in GitHub Actions: Tag v* gepusht oder manueller Start mit Version): signiert das DMG für Sparkle,
#  schreibt appcast.xml und legt das GitHub-Release mit DMG, Feed und Lizenzhinweisen an. Die Quellarchive der
#  Copyleft-Komponenten (Licenses/sources.json der App) kommen ins dauerhafte Release „third-party-sources“.
#
#  Umgebung: RELEASE_TAG (manueller Start) oder GITHUB_REF_NAME (gepushtes Tag), GITHUB_SHA, GITHUB_REPOSITORY, GH_TOKEN, SPARKLE_PRIVATE_KEY (Repository-Secret)
# =============================================================================
set -Eeuo pipefail
trap 'echo "[FEHLER] ${BASH_SOURCE[0]##*/} Zeile $LINENO: $BASH_COMMAND (Exit $?)" >&2' ERR
cd "$(dirname "$0")/.."

die() { printf '[FEHLER] %s\n' "$*" >&2; exit 1; }

TAG="${RELEASE_TAG:-${GITHUB_REF_NAME:?Tag fehlt}}"
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
previous="$(git describe --tags --abbrev=0 --match 'v*' "$TAG^" 2>/dev/null || true)"
git log --no-merges --format='- %s' "${previous:+$previous..}$TAG" | head -n 40 > dist/notes.md

python3 build/appcast.py --version "$VERSION" --build "$build_number" \
  --url "https://github.com/$GITHUB_REPOSITORY/releases/download/$TAG/PDF-MRC.dmg" \
  --signature "$signature" --notes-file dist/notes.md --out dist/appcast.xml

# Quellcode der Copyleft-Komponenten (AGPL-3.0 §6, MPL-2.0 §3.2): genau die Archive, aus denen diese App gebaut
# ist, geprüft gegen die Prüfsummen in der App. Eigenes Release, nie „latest“ (Sparkle-Feed und Download-Link
# zeigen auf …/releases/latest); Archive werden nie gelöscht, auch nicht für ältere Versionen.
LICENSES="$APP/Contents/Resources/Licenses"
[[ -s "$LICENSES/sources.json" && -s "$LICENSES/THIRD-PARTY-NOTICES.txt" ]] || die "Lizenzhinweise fehlen in der App."
SOURCES_TAG="third-party-sources"
if ! gh release view "$SOURCES_TAG" >/dev/null 2>&1; then
  gh release create "$SOURCES_TAG" --target "$GITHUB_SHA" --latest=false --title "Third-party source code" \
    --notes "Source code of the components under copyleft licenses (AGPL-3.0, MPL-2.0 and others) bundled in PDF MRC, exactly as used for the builds. Which archive belongs to which app version: Contents/Resources/Licenses/THIRD-PARTY-NOTICES.txt and sources.json in the app (with SHA-256 checksums).

Quellcode der in PDF MRC enthaltenen Komponenten unter Copyleft-Lizenzen (AGPL-3.0, MPL-2.0 u. a.), genau wie für die Builds verwendet. Zuordnung zu den App-Versionen: THIRD-PARTY-NOTICES.txt und sources.json im App-Paket."
fi
existing="$(gh release view "$SOURCES_TAG" --json assets --jq '.assets[].name')"
python3 -c 'import json, sys; [print(s["url"], s["sha256"], s["filename"], sep="\t") for s in json.load(open(sys.argv[1]))]' \
  "$LICENSES/sources.json" > dist/sources.tsv
mkdir -p dist/sources
while IFS=$'\t' read -r url sum name; do
  if grep -qxF "$name" <<<"$existing"; then
    echo "Quelle vorhanden: $name"
    continue
  fi
  curl -fsSL --retry 3 -o "dist/sources/$name" "$url" || die "Quellarchiv nicht ladbar: $url"
  [[ "$(shasum -a 256 "dist/sources/$name" | cut -d' ' -f1)" == "$sum" ]] || die "Prüfsumme falsch: $name"
  gh release upload "$SOURCES_TAG" "dist/sources/$name" || die "Hochladen fehlgeschlagen: $name"
  echo "Quelle hochgeladen: $name"
done < dist/sources.tsv
cp "$LICENSES/THIRD-PARTY-NOTICES.txt" dist/THIRD-PARTY-NOTICES.txt

{
  echo "**Installation:** \`PDF-MRC.dmg\` laden, öffnen, „PDF MRC“ in „Programme“ ziehen. Beim ersten Start:"
  echo "Systemeinstellungen → Datenschutz & Sicherheit → „Dennoch öffnen“ (die App ist nicht notarisiert)."
  echo "Bestehende Installationen aktualisieren sich automatisch."
  echo
  echo "**Install:** download \`PDF-MRC.dmg\`, open it, drag “PDF MRC” to Applications. On first launch: System"
  echo "Settings → Privacy & Security → “Open Anyway” (the app is not notarized). Existing installations update themselves."
  echo
  echo "### Änderungen / Changes"
  cat dist/notes.md
  echo
  echo "☕ PDF MRC ist kostenlos. Wer die Entwicklung unterstützen möchte: / PDF MRC is free. To support its development:"
  echo "https://ko-fi.com/Philoneous"
  echo
  echo "**Lizenzen / Licenses:** PDF MRC © Philoneous, AGPL-3.0-or-later; Quellcode: Quellcode-Archiv dieses Releases."
  echo "Enthaltene Komponenten und ihre Lizenzen: \`THIRD-PARTY-NOTICES.txt\` (auch in der App: Info → Hinweise zu Drittkomponenten)."
  echo "Quellcode der Copyleft-Komponenten: Release [$SOURCES_TAG](https://github.com/$GITHUB_REPOSITORY/releases/tag/$SOURCES_TAG)."
  echo "PDF MRC © Philoneous, AGPL-3.0-or-later; source: this release's source archive. Bundled components and their"
  echo "licenses: \`THIRD-PARTY-NOTICES.txt\` (also in the app: About → Third-party notices). Source code of the copyleft"
  echo "components: release [$SOURCES_TAG](https://github.com/$GITHUB_REPOSITORY/releases/tag/$SOURCES_TAG)."
} > dist/release.md

gh release create "$TAG" --target "$GITHUB_SHA" --latest "$DMG" dist/appcast.xml dist/THIRD-PARTY-NOTICES.txt \
  --title "PDF MRC $VERSION" --notes-file dist/release.md
echo "[OK] Release $TAG veröffentlicht (Build $build_number)"
