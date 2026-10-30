#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# =============================================================================
#  Baut „PDF MRC.app“.
#
#    build/build_app.sh <Zielordner> --standalone
#        Eigenständige App: Python, paperless-mrc, Tesseract (deu, eng, osd), OpenJPEG und jbig2enc
#        liegen im App-Paket. Braucht beim Bauen Homebrew (Werkzeuge), uv (Python) und Netz.
#    build/build_app.sh <Zielordner> --homebrew <Pfad zu paperless-mrc>
#        App für die Homebrew-Installation (install.sh): Werkzeuge und paperless-mrc liegen außerhalb.
#
#  Umgebung: VERSION (z. B. 1.2.0), BUILD_NUMBER (fortlaufend, für Updates), PACKAGE (paperless-mrc-Quelle).
# =============================================================================
set -Eeuo pipefail
trap 'echo "[FEHLER] ${BASH_SOURCE[0]##*/} Zeile $LINENO: $BASH_COMMAND (Exit $?)" >&2' ERR

SRC_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:?Zielordner fehlt}"
MODE="${2:?--standalone oder --homebrew fehlt}"
PAPERLESS_TOOL="${3:-}"
PACKAGE="${PACKAGE:-git+https://github.com/Philoneous/paperless-mrc.git}"
VERSION="${VERSION:-$(git -C "$SRC_DIR" describe --tags --always 2>/dev/null | sed 's/^v//' || echo dev)}"
BUILD_NUMBER="${BUILD_NUMBER:-$(git -C "$SRC_DIR" rev-list --count HEAD 2>/dev/null || echo 1)}"
TESS_LANGS="${TESS_LANGS:-deu}"  # zusätzlich zu eng und osd aus Homebrew; Quelle: tessdata_fast
SPARKLE_VERSION="${SPARKLE_VERSION:-2.9.6}"  # Updates (nur eigenständige App)
SPARKLE_DIR="$SRC_DIR/build/.sparkle-$SPARKLE_VERSION"  # Sparkle.framework, bin/sign_update
SPARKLE_FEED="${SPARKLE_FEED:-https://github.com/Philoneous/mac-pdf-mrc/releases/latest/download/appcast.xml}"
SPARKLE_PUBLIC_KEY="${SPARKLE_PUBLIC_KEY:-SrykS0Sl6v8dGZlbnI6w4D35cwaghPkH8L0ByMD2RLw=}"
NAME="Compress PDF (MRC)"  # Dateinamen der Schnellaktionen; Menütitel übersetzt die App (QuickAction.swift)
NAME_SEND="Send to Paperless"
NAME_SEND_MRC="Compress and Send to Paperless"

msg() { printf '[..] %s\n' "$*"; }
ok()  { printf '[OK] %s\n' "$*"; }
die() { printf '[FEHLER] %s\n' "$*" >&2; exit 1; }

case "$MODE" in
  --standalone) ;;
  --homebrew) [[ -x "$PAPERLESS_TOOL" ]] || die "paperless-mrc nicht gefunden: $PAPERLESS_TOOL" ;;
  *) die "Unbekannte Variante: $MODE" ;;
esac
[[ "$PAPERLESS_TOOL" != *[\&\<\>\"\$\`\\]* ]] || die "Ungewöhnliche Zeichen im Pfad $PAPERLESS_TOOL."

BUILD="$(mktemp -d)/PDF MRC.app"
C="$BUILD/Contents"
mkdir -p "$C/MacOS" "$C/Resources"

# ---- Swift-App ----------------------------------------------------------------------------------
swift_flags=()
if [[ "$MODE" == --standalone ]]; then
  if [[ ! -d "$SPARKLE_DIR/Sparkle.framework" ]]; then
    msg "Sparkle $SPARKLE_VERSION laden"
    mkdir -p "$SPARKLE_DIR"
    curl -fsSL "https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-$SPARKLE_VERSION.tar.xz" \
      | tar -xJ -C "$SPARKLE_DIR" || die "Sparkle konnte nicht geladen werden."
  fi
  swift_flags=(-D SPARKLE -F "$SPARKLE_DIR" -framework Sparkle -Xlinker -rpath -Xlinker @executable_path/../Frameworks)
fi
msg "App kompilieren ($VERSION, Build $BUILD_NUMBER)"
xcrun swiftc -swift-version 5 -parse-as-library -O -target "$(uname -m)-apple-macos13.0" \
  ${swift_flags[@]+"${swift_flags[@]}"} -o "$C/MacOS/pdf-mrc" "$SRC_DIR"/App/Sources/*.swift
cp -R "$SRC_DIR"/App/Resources/*.lproj "$C/Resources/"
cp "$SRC_DIR/App/Icon/AppIcon.icns" "$C/Resources/AppIcon.icns"  # aus icon.svg: build/make_icon.py
ICONSET=$(mktemp -d)/AppIcon.iconset
iconutil -c iconset -o "$ICONSET" "$C/Resources/AppIcon.icns" || die "AppIcon.icns ungültig."
rm -rf "$(dirname "$ICONSET")"
plutil -lint -s "$C"/Resources/*.lproj/*.strings || die "Übersetzungsdateien ungültig."

# ---- Laufzeit (nur eigenständige App) -------------------------------------------------------------
PAPERLESS_VERSION="extern"
if [[ "$MODE" == --standalone ]]; then
  R="$C/Resources"; H="$C/Helpers"; F="$C/Frameworks"
  mkdir -p "$H" "$F"
  ditto "$SPARKLE_DIR/Sparkle.framework" "$F/Sparkle.framework"

  msg "Bauwerkzeuge aus Homebrew"
  brew install --quiet uv tesseract openjpeg jbig2enc zstd

  msg "Python und paperless-mrc"
  uv python install --quiet 3.13
  PY_SRC="$(ls -d "$(uv python dir)"/cpython-3.13*-macos-aarch64-none | sort -V | tail -1)"
  cp -R "$PY_SRC" "$R/python"
  PY="$R/python/bin/python3"
  rm -f "$R"/python/lib/python3.*/EXTERNALLY-MANAGED
  uv pip install --quiet --python "$PY" --system "$PACKAGE"
  PAPERLESS_VERSION="$("$PY" -c 'import importlib.metadata as m, json; d = m.distribution("paperless-mrc"); u = json.loads(d.read_text("direct_url.json") or "{}"); print(d.version + "+" + u.get("vcs_info", {}).get("commit_id", "")[:7])')"
  # Ausdünnen – gemessen mit einem Import-Protokoll aller Python-Prozesse über die Testsuite von paperless-mrc
  # (inkl. recode_pdf, pdf-to-hocr, Worker). Nie geladen und daher entfernt (spart Platz und Lizenzpflichten):
  #  - KI-Layoutanalyse von PyMuPDF (onnxruntime …; PyMuPDF lädt sie nur, wenn vorhanden)
  #  - lxml (nur XMP-Metadaten in pikepdf), networkx (skimage.graph), imageio/tifffile (skimage.io),
  #    psutil/PyYAML (Test-/Konfig-Helfer von numpy/scipy), pip (nur zum Installieren)
  #  - scipy.odr: einziger Nutzer der GCC-Fortran-Laufzeit (GPL/LGPL); scipy unterstützt das Fehlen ausdrücklich
  for pkg in onnxruntime protobuf flatbuffers pymupdf4llm pymupdf-layout lxml networkx imageio tifffile psutil \
             pyyaml pip; do
    uv pip uninstall --quiet --python "$PY" --system "$pkg" 2>/dev/null || true
  done
  SP="$(echo "$R"/python/lib/python3.*/site-packages)"
  for mod in onnxruntime lxml networkx imageio tifffile psutil yaml pip; do
    [[ ! -e "$SP/$mod" ]] || die "Python-Paket $mod konnte nicht entfernt werden."
  done
  rm -rf "$SP/pymupdf/layout" "$SP/pymupdf/mupdf-devel" "$SP/scipy/odr" "$SP"/scipy/.dylibs/lib{gfortran,quadmath,gcc_s}*
  find "$SP" -type d \( -name tests -o -name test \) -prune -exec rm -rf {} +
  # Nicht benötigte Teile der Standardbibliothek (Tcl/Tk: keine Oberfläche in Python)
  rm -rf "$R"/python/lib/python3.*/{test,idlelib,tkinter,turtledemo,ensurepip} "$R"/python/lib/{tcl,tk,itcl,thread}* \
         "$R"/python/lib/libtcl* "$R"/python/lib/python3.*/lib-dynload/_tkinter* "$R"/python/share "$R"/python/include
  # Skripte (recode_pdf, pdf-to-hocr …) mit festem Python-Pfad → über PATH (python/bin steht vorn)
  python3 "$SRC_DIR/build/fix_scripts.py" "$R/python/bin" || die "Skripte umstellen fehlgeschlagen."
  if grep -l "$(dirname "$BUILD")" "$R"/python/bin/* 2>/dev/null; then
    die "Skripte in python/bin verweisen noch auf den Build-Ordner (siehe oben)."
  fi
  "$PY" -m compileall -q "$R/python/lib" >/dev/null || true  # .pyc vorab (das Paket ist danach schreibgeschützt)

  msg "Werkzeuge aus Homebrew übernehmen"
  BREW="$(brew --prefix)"
  # Programme und ihre Bibliotheken (Zeitgrenze: bricht ab statt zu hängen)
  # pdftoppm (Poppler) entfällt: paperless-mrc prüft das Ergebnis dort mit Poppler, die App stattdessen mit Quartz
  # (MRC_POPPLER_CHECK=false) – Poppler zog alle (L)GPL/MPL-Bibliotheken nach (NSS, gpgme, glib …).
  # opj_decompress wird nie aufgerufen, recode_pdf verlangt es aber beim Start (which) neben opj_compress.
  KEGS="$(dirname "$BUILD")/kegs.json"
  perl -e 'alarm shift; exec @ARGV' 900 python3 "$SRC_DIR/build/bundle_dylibs.py" --manifest "$KEGS" "$H" "$F" \
    "$BREW"/bin/{tesseract,opj_compress,opj_decompress,jbig2} || die "Bibliotheken übernehmen fehlgeschlagen."

  msg "Tesseract-Sprachdaten"
  mkdir -p "$R/tessdata"
  cp -RL "$BREW/share/tessdata/configs" "$BREW/share/tessdata/tessconfigs" "$R/tessdata/"  # u. a. hOCR-Ausgabe
  cp -L "$BREW/share/tessdata/eng.traineddata" "$BREW/share/tessdata/osd.traineddata" "$R/tessdata/"
  chmod -R u+w "$R/tessdata"
  for lang in $TESS_LANGS; do
    curl -fsSL -o "$R/tessdata/$lang.traineddata" "https://github.com/tesseract-ocr/tessdata_fast/raw/main/$lang.traineddata"
  done

  msg "Lizenzhinweise"
  python3 "$SRC_DIR/build/notices.py" --app "$BUILD" --kegs "$KEGS" --sparkle "$SPARKLE_DIR" \
    --license "$SRC_DIR/LICENSE" --version "$VERSION" || die "Lizenzhinweise unvollständig (siehe oben)."
fi

# ---- Info.plist ------------------------------------------------------------------------------------
EXTRA_PLIST=""
if [[ "$MODE" == --standalone ]]; then
  EXTRA_PLIST="	<key>SUFeedURL</key>
	<string>$SPARKLE_FEED</string>
	<key>SUPublicEDKey</key>
	<string>$SPARKLE_PUBLIC_KEY</string>
	<key>SUEnableAutomaticChecks</key>
	<true/>
	<key>SUAutomaticallyUpdate</key>
	<true/>
	<key>SUScheduledCheckInterval</key>
	<integer>14400</integer>
"
fi
if [[ "$MODE" == --homebrew ]]; then
  EXTRA_PLIST="	<key>MRCPaperlessPath</key>
	<string>$PAPERLESS_TOOL</string>
"
fi
cat > "$C/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleLocalizations</key>
	<array>
		<string>en</string>
		<string>de</string>
	</array>
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
	<key>CFBundleExecutable</key>
	<string>pdf-mrc</string>
	<key>CFBundleIdentifier</key>
	<string>io.github.philoneous.mac-pdf-mrc</string>
	<key>CFBundleName</key>
	<string>PDF MRC</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>$VERSION</string>
	<key>CFBundleVersion</key>
	<string>$BUILD_NUMBER</string>
	<key>MRCPaperlessVersion</key>
	<string>$PAPERLESS_VERSION</string>
	<key>LSMinimumSystemVersion</key>
	<string>13.0</string>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>NSLocalNetworkUsageDescription</key>
	<string>PDF MRC sendet Dokumente an deinen Paperless-Server im lokalen Netz.</string>
	<key>NSAppTransportSecurity</key>
	<dict>
		<key>NSAllowsArbitraryLoads</key>
		<true/>
	</dict>
$EXTRA_PLIST</dict>
</plist>
EOF

write_workflow() {
local name="$1" flag="$2"
local template="$BUILD/Contents/Resources/$name.workflow"
mkdir -p "$template/Contents"
cat > "$template/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>NSServices</key>
	<array>
		<dict>
			<key>NSBackgroundColorName</key>
			<string>background</string>
			<key>NSIconName</key>
			<string>NSTouchBarDocuments</string>
			<key>NSMenuItem</key>
			<dict>
				<key>default</key>
				<string>$name</string>
			</dict>
			<key>NSMessage</key>
			<string>runWorkflowAsService</string>
			<key>NSRequiredContext</key>
			<dict>
				<key>NSApplicationIdentifier</key>
				<string>com.apple.finder</string>
			</dict>
			<key>NSSendFileTypes</key>
			<array>
				<string>com.adobe.pdf</string>
			</array>
		</dict>
	</array>
</dict>
</plist>
EOF

cat > "$template/Contents/document.wflow" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>AMApplicationBuild</key>
	<string>509.1</string>
	<key>AMApplicationVersion</key>
	<string>2.10</string>
	<key>AMDocumentVersion</key>
	<string>2</string>
	<key>actions</key>
	<array>
		<dict>
			<key>action</key>
			<dict>
				<key>AMAccepts</key>
				<dict>
					<key>Container</key>
					<string>List</string>
					<key>Optional</key>
					<true/>
					<key>Types</key>
					<array>
						<string>com.apple.cocoa.string</string>
					</array>
				</dict>
				<key>AMActionVersion</key>
				<string>2.0.3</string>
				<key>AMApplication</key>
				<array>
					<string>Automator</string>
				</array>
				<key>AMParameterProperties</key>
				<dict>
					<key>COMMAND_STRING</key>
					<dict/>
					<key>CheckedForUserDefaultShell</key>
					<dict/>
					<key>inputMethod</key>
					<dict/>
					<key>shell</key>
					<dict/>
					<key>source</key>
					<dict/>
				</dict>
				<key>AMProvides</key>
				<dict>
					<key>Container</key>
					<string>List</string>
					<key>Types</key>
					<array>
						<string>com.apple.cocoa.string</string>
					</array>
				</dict>
				<key>ActionBundlePath</key>
				<string>/System/Library/Automator/Run Shell Script.action</string>
				<key>ActionName</key>
				<string>Run Shell Script</string>
				<key>ActionParameters</key>
				<dict>
					<key>COMMAND_STRING</key>
					<string>"__APP_EXECUTABLE__" $flag "\$@"</string>
					<key>CheckedForUserDefaultShell</key>
					<true/>
					<key>inputMethod</key>
					<integer>1</integer>
					<key>shell</key>
					<string>/bin/zsh</string>
					<key>source</key>
					<string></string>
				</dict>
				<key>BundleIdentifier</key>
				<string>com.apple.RunShellScript</string>
				<key>CFBundleVersion</key>
				<string>2.0.3</string>
				<key>CanShowSelectedItemsWhenRun</key>
				<false/>
				<key>CanShowWhenRun</key>
				<true/>
				<key>Category</key>
				<array>
					<string>AMCategoryUtilities</string>
				</array>
				<key>Class Name</key>
				<string>RunShellScriptAction</string>
				<key>InputUUID</key>
				<string>DF522603-56A9-44E4-A44B-1B5D45938A81</string>
				<key>Keywords</key>
				<array>
					<string>Shell</string>
					<string>Script</string>
					<string>Command</string>
					<string>Run</string>
					<string>Unix</string>
				</array>
				<key>OutputUUID</key>
				<string>5245DE12-4FAE-43E4-81B7-A0E7D762AAE4</string>
				<key>UUID</key>
				<string>E2257A0F-E289-46CF-8AD8-CB36FFBAA482</string>
				<key>UnlocalizedApplications</key>
				<array>
					<string>Automator</string>
				</array>
				<key>arguments</key>
				<dict>
					<key>0</key>
					<dict>
						<key>default value</key>
						<integer>0</integer>
						<key>name</key>
						<string>inputMethod</string>
						<key>required</key>
						<string>0</string>
						<key>type</key>
						<string>0</string>
						<key>uuid</key>
						<string>0</string>
					</dict>
					<key>1</key>
					<dict>
						<key>default value</key>
						<false/>
						<key>name</key>
						<string>CheckedForUserDefaultShell</string>
						<key>required</key>
						<string>0</string>
						<key>type</key>
						<string>0</string>
						<key>uuid</key>
						<string>1</string>
					</dict>
					<key>2</key>
					<dict>
						<key>default value</key>
						<string></string>
						<key>name</key>
						<string>source</string>
						<key>required</key>
						<string>0</string>
						<key>type</key>
						<string>0</string>
						<key>uuid</key>
						<string>2</string>
					</dict>
					<key>3</key>
					<dict>
						<key>default value</key>
						<string></string>
						<key>name</key>
						<string>COMMAND_STRING</string>
						<key>required</key>
						<string>0</string>
						<key>type</key>
						<string>0</string>
						<key>uuid</key>
						<string>3</string>
					</dict>
					<key>4</key>
					<dict>
						<key>default value</key>
						<string>/bin/sh</string>
						<key>name</key>
						<string>shell</string>
						<key>required</key>
						<string>0</string>
						<key>type</key>
						<string>0</string>
						<key>uuid</key>
						<string>4</string>
					</dict>
				</dict>
				<key>isViewVisible</key>
				<integer>1</integer>
				<key>location</key>
				<string>309.000000:305.000000</string>
				<key>nibPath</key>
				<string>/System/Library/Automator/Run Shell Script.action/Contents/Resources/Base.lproj/main.nib</string>
			</dict>
			<key>isViewVisible</key>
			<integer>1</integer>
		</dict>
	</array>
	<key>connectors</key>
	<dict/>
	<key>workflowMetaData</key>
	<dict>
		<key>applicationBundleID</key>
		<string>com.apple.finder</string>
		<key>applicationBundleIDsByPath</key>
		<dict>
			<key>/System/Library/CoreServices/Finder.app</key>
			<string>com.apple.finder</string>
		</dict>
		<key>applicationPath</key>
		<string>/System/Library/CoreServices/Finder.app</string>
		<key>applicationPaths</key>
		<array>
			<string>/System/Library/CoreServices/Finder.app</string>
		</array>
		<key>inputTypeIdentifier</key>
		<string>com.apple.Automator.fileSystemObject.PDF</string>
		<key>outputTypeIdentifier</key>
		<string>com.apple.Automator.nothing</string>
		<key>presentationMode</key>
		<integer>15</integer>
		<key>processesInput</key>
		<integer>0</integer>
		<key>serviceApplicationBundleID</key>
		<string>com.apple.finder</string>
		<key>serviceApplicationPath</key>
		<string>/System/Library/CoreServices/Finder.app</string>
		<key>serviceInputTypeIdentifier</key>
		<string>com.apple.Automator.fileSystemObject.PDF</string>
		<key>serviceOutputTypeIdentifier</key>
		<string>com.apple.Automator.nothing</string>
		<key>serviceProcessesInput</key>
		<integer>0</integer>
		<key>systemImageName</key>
		<string>NSTouchBarDocuments</string>
		<key>useAutomaticInputType</key>
		<integer>0</integer>
		<key>workflowTypeIdentifier</key>
		<string>com.apple.Automator.servicesMenu</string>
	</dict>
</dict>
</plist>
EOF
plutil -lint -s "$template/Contents/Info.plist" "$template/Contents/document.wflow" || die "Workflow $name ungültig."
}
# Die Schnellaktion übergibt nur an die App (Menüleiste, Mitteilungen, Verlauf) und endet sofort
write_workflow "$NAME" "--auftrag compress"
write_workflow "$NAME_SEND" "--auftrag send"
write_workflow "$NAME_SEND_MRC" "--auftrag compressAndSend"
plutil -lint -s "$C/Info.plist" || die "Info.plist der App ungültig."

# ---- Signieren (ad hoc) und prüfen -------------------------------------------------------------------
msg "Signieren"
while IFS= read -r -d '' f; do
  if file -b "$f" | grep -q Mach-O; then
    codesign --force --sign - "$f" >/dev/null 2>&1 || die "Signieren fehlgeschlagen: $f"
  fi
done < <(find "$C/Frameworks" "$C/Helpers" "$C/Resources" -type f -print0 2>/dev/null)
if [[ -d "$C/Frameworks/Sparkle.framework" ]]; then  # eingebettete Bundles von innen nach außen
  SPV="$C/Frameworks/Sparkle.framework/Versions/B"
  for b in "$SPV"/XPCServices/*.xpc "$SPV/Updater.app" "$SPV/Autoupdate" "$C/Frameworks/Sparkle.framework"; do
    codesign --force --sign - "$b" >/dev/null 2>&1 || die "Signieren fehlgeschlagen: $b"
  done
fi
codesign --force --sign - "$BUILD" >/dev/null 2>&1 || die "Signieren der App fehlgeschlagen."
codesign --verify --deep --strict "$BUILD" || die "Signatur ungültig."
if [[ "$MODE" == --standalone ]]; then
  # Keine Verweise auf Homebrew oder die Bauumgebung
  bad=""
  while IFS= read -r -d '' f; do
    file -b "$f" | grep -q Mach-O || continue
    own_id="$(otool -D "$f" | tail -n +2)"  # eigene ID einer Bibliothek ist kein Verweis
    refs="$(otool -L "$f" | tail -n +2 | grep -vF "${own_id:-@@keine@@} (" | grep -E '/opt/homebrew|/usr/local|/Users/' || true)"
    [[ -z "$refs" ]] || bad+="$f: $refs"$'\n'
  done < <(find "$C" -type f -print0)
  [[ -z "$bad" ]] || die "Externe Bibliotheken: $bad"
  # Jede Bibliothek, die ein Programm oder eine Python-Erweiterung lädt, muss im Paket oder System liegen
  # (fängt beim Ausdünnen versehentlich entfernte Teile ab)
  python3 "$SRC_DIR/build/check_bundle.py" "$BUILD" || die "Unvollständiges App-Paket (siehe oben)."
  [[ -s "$C/Resources/Licenses/THIRD-PARTY-NOTICES.txt" ]] || die "Lizenzhinweise fehlen."
fi

if [[ -n "${GITHUB_ACTIONS:-}" && "$MODE" == --standalone ]]; then
  echo "::notice title=Größe::App $(du -sh "$BUILD" | cut -f1): Python $(du -sh "$C/Resources/python" | cut -f1), Werkzeuge $(du -shc "$C/Helpers" "$C/Frameworks" | tail -1 | cut -f1), tessdata $(du -sh "$C/Resources/tessdata" | cut -f1)"
fi
mkdir -p "$OUT"
rm -rf "$OUT/PDF MRC.app"
mv "$BUILD" "$OUT/PDF MRC.app"
ok "Gebaut: $OUT/PDF MRC.app ($(du -sh "$OUT/PDF MRC.app" | cut -f1)), paperless-mrc $PAPERLESS_VERSION"
