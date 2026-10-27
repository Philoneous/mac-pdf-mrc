#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# =============================================================================
#  Baut „PDF MRC.app“.
#
#    build/build_app.sh <Zielordner> --standalone
#        Eigenständige App: Python, paperless-mrc, Tesseract (deu, eng, osd), OpenJPEG, jbig2enc und pdftoppm
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
NAME="PDF komprimieren (MRC)"
NAME_SEND="An Paperless senden"
NAME_SEND_MRC="Komprimieren und an Paperless senden"

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
  brew install --quiet uv tesseract openjpeg poppler jbig2enc

  msg "Python und paperless-mrc"
  uv python install --quiet 3.13
  PY_SRC="$(ls -d "$(uv python dir)"/cpython-3.13*-macos-aarch64-none | sort -V | tail -1)"
  cp -R "$PY_SRC" "$R/python"
  PY="$R/python/bin/python3"
  rm -f "$R"/python/lib/python3.*/EXTERNALLY-MANAGED
  uv pip install --quiet --python "$PY" --system "$PACKAGE"
  PAPERLESS_VERSION="$("$PY" -c 'import importlib.metadata as m, json; d = m.distribution("paperless-mrc"); u = json.loads(d.read_text("direct_url.json") or "{}"); print(d.version + "+" + u.get("vcs_info", {}).get("commit_id", "")[:7])')"
  # PyMuPDF 2 bringt eine KI-Layoutanalyse mit (onnxruntime, Modelle), die paperless-mrc nicht nutzt;
  # PyMuPDF lädt sie nur, wenn vorhanden (try/except ImportError). Tests der Bibliotheken werden nicht gebraucht.
  uv pip uninstall --quiet --python "$PY" --system onnxruntime protobuf flatbuffers pymupdf4llm pymupdf-layout || true
  SP="$(echo "$R"/python/lib/python3.*/site-packages)"
  rm -rf "$SP/pymupdf/layout" "$SP/pymupdf/mupdf-devel"
  find "$SP" -type d \( -name tests -o -name test \) -prune -exec rm -rf {} +
  # Nicht benötigte Teile der Standardbibliothek
  rm -rf "$R"/python/lib/python3.*/{test,idlelib,tkinter,turtledemo,ensurepip} "$R"/python/lib/{tcl,tk,itcl,thread}* \
         "$R"/python/share "$R"/python/include
  # Skripte (recode_pdf, pdf-to-hocr …) mit festem Python-Pfad → über PATH (python/bin steht vorn)
  for f in "$R"/python/bin/*; do
    if [[ -f "$f" && ! -L "$f" ]] && head -c 2 "$f" | grep -q '#!' && head -n 1 "$f" | grep -q python; then
      sed -i '' -e '1s|^#!.*$|#!/usr/bin/env python3|' "$f"
    fi
  done
  "$PY" -m compileall -q "$R/python/lib" >/dev/null || true  # .pyc vorab (das Paket ist danach schreibgeschützt)

  msg "Werkzeuge aus Homebrew übernehmen"
  BREW="$(brew --prefix)"
  # Programme und ihre Bibliotheken (Zeitgrenze: bricht ab statt zu hängen)
  perl -e 'alarm shift; exec @ARGV' 900 python3 "$SRC_DIR/build/bundle_dylibs.py" "$H" "$F" \
    "$BREW"/bin/{tesseract,opj_compress,opj_decompress,jbig2,pdftoppm} || die "Bibliotheken übernehmen fehlgeschlagen."

  msg "Tesseract-Sprachdaten"
  mkdir -p "$R/tessdata"
  cp -RL "$BREW/share/tessdata/configs" "$BREW/share/tessdata/tessconfigs" "$R/tessdata/"  # u. a. hOCR-Ausgabe
  cp -L "$BREW/share/tessdata/eng.traineddata" "$BREW/share/tessdata/osd.traineddata" "$R/tessdata/"
  chmod -R u+w "$R/tessdata"
  for lang in $TESS_LANGS; do
    curl -fsSL -o "$R/tessdata/$lang.traineddata" "https://github.com/tesseract-ocr/tessdata_fast/raw/main/$lang.traineddata"
  done

  # Fontconfig (von Poppler genutzt): Systemschriften, Cache im Benutzerordner
  mkdir -p "$R/fonts"
  cat > "$R/fonts/fonts.conf" <<'FC'
<?xml version="1.0"?>
<!DOCTYPE fontconfig SYSTEM "fonts.dtd">
<fontconfig>
  <dir>/System/Library/Fonts</dir>
  <dir>/Library/Fonts</dir>
  <dir prefix="xdg">fonts</dir>
  <cachedir prefix="xdg">mac-pdf-mrc-fontconfig</cachedir>
</fontconfig>
FC
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
write_workflow "$NAME" --kontextmenue
write_workflow "$NAME_SEND" --paperless
write_workflow "$NAME_SEND_MRC" --paperless-komprimiert
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
fi

if [[ -n "${GITHUB_ACTIONS:-}" && "$MODE" == --standalone ]]; then
  echo "::notice title=Größe::App $(du -sh "$BUILD" | cut -f1): Python $(du -sh "$C/Resources/python" | cut -f1), Werkzeuge $(du -shc "$C/Helpers" "$C/Frameworks" | tail -1 | cut -f1), tessdata $(du -sh "$C/Resources/tessdata" | cut -f1)"
fi
mkdir -p "$OUT"
rm -rf "$OUT/PDF MRC.app"
mv "$BUILD" "$OUT/PDF MRC.app"
ok "Gebaut: $OUT/PDF MRC.app ($(du -sh "$OUT/PDF MRC.app" | cut -f1)), paperless-mrc $PAPERLESS_VERSION"
