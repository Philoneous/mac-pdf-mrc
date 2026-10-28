#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# =============================================================================
#  mac-pdf-mrc installieren oder aktualisieren (macOS, Homebrew):
#  App „PDF MRC“ in ~/Applications und Finder-Schnellaktionen. Backup-Weg neben der eigenständigen App (DMG).
#
#  Aufruf als normaler Benutzer (nicht mit sudo):
#    bash install.sh
#  Erneuter Aufruf = Update (auch von paperless-mrc).
#
#  Die Verarbeitung selbst übernimmt paperless-mrc
#  (https://github.com/Philoneous/paperless-mrc), das hier als Python-Paket installiert wird.
# =============================================================================
set -Eeuo pipefail

REPO_URL="${REPO_URL:-https://github.com/Philoneous/mac-pdf-mrc.git}"
PACKAGE="${PACKAGE:-git+https://github.com/Philoneous/paperless-mrc.git}"  # Verarbeitung
SRC_DIR="${SRC_DIR:-}"  # vorhandener Checkout statt Download (Entwicklung, CI)
APP="$HOME/Applications/PDF MRC.app"
NAME="PDF komprimieren (MRC)"  # Menütitel bei deutscher Systemsprache (englisch: „Compress PDF (MRC)“)

msg() { printf '[..] %s\n' "$*"; }
ok()  { printf '[OK] %s\n' "$*"; }
die() { printf '[FEHLER] %s\n' "$*" >&2; exit 1; }

[[ "$(uname -s)" == Darwin ]] || die "Nur für macOS."
[[ $EUID -ne 0 ]] || die "Bitte nicht als root ausführen."
command -v brew >/dev/null || die "Homebrew fehlt – siehe https://brew.sh"
xcrun --find swiftc >/dev/null 2>&1 || die "Swift-Compiler fehlt – bitte 'xcode-select --install' ausführen."
[[ "$HOME" != *[\&\<\>\"\$\`\\]* ]] || die "Ungewöhnliche Zeichen im Pfad $HOME."

# ---- Werkzeuge (Tesseract mit allen Sprachen, OpenJPEG, Poppler, jbig2enc, uv) -----
msg "Homebrew-Pakete installieren"
brew install --quiet tesseract tesseract-lang openjpeg poppler jbig2enc uv

# ---- paperless-mrc in eigener Python-Umgebung ------------------------------------------
msg "paperless-mrc installieren"
uv tool install --quiet --force --python 3.13 --reinstall-package paperless-mrc "$PACKAGE"
BIN="$(uv tool dir --bin)"
TOOL="$BIN/paperless-mrc"
"$(uv tool dir)/paperless-mrc/bin/recode_pdf" --version >/dev/null 2>&1 || die "recode_pdf startet nicht."
[[ "$TOOL" != *[\&\<\>\"\$\`\\]* ]] || die "Ungewöhnliche Zeichen im Pfad $TOOL – bitte UV_TOOL_BIN_DIR setzen."
ok "paperless-mrc installiert ($TOOL)"

# ---- App bauen ------------------------------------------------------------------------------
if [[ -z "$SRC_DIR" ]]; then
  SRC_DIR="$(mktemp -d)/mac-pdf-mrc"
  git clone -q "$REPO_URL" "$SRC_DIR"
fi
BUILD_DIR="$(mktemp -d)"
/bin/bash "$SRC_DIR/build/build_app.sh" "$BUILD_DIR" --homebrew "$TOOL"
mkdir -p "$HOME/Applications"
rm -rf "$APP"
mv "$BUILD_DIR/PDF MRC.app" "$APP"
ok "App installiert: $APP"

# ---- Aufrufskript der Vorversion entfernen ------------------------------------------------------
if [[ -f "$BIN/pdf-mrc" ]] && grep -q "Finder-Schnellaktion" "$BIN/pdf-mrc"; then
  rm "$BIN/pdf-mrc"
  ok "Aufrufskript der Vorversion entfernt"
fi

# ---- Schnellaktionen einrichten bzw. aktualisieren (Zustand bleibt; bei Erstinstallation „komprimieren“ an) ---------
"$APP/Contents/MacOS/pdf-mrc" --schnellaktionen-einrichten
ok "Fertig. App „PDF MRC“ in ~/Applications; Rechtsklick auf PDFs → Schnellaktionen → „${NAME}“"
