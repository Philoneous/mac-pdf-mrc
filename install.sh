#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# =============================================================================
#  mac-pdf-mrc installieren oder aktualisieren (macOS, Homebrew):
#  App „PDF MRC“ in ~/Applications und Finder-Schnellaktion „PDF komprimieren (MRC)“.
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
NAME="PDF komprimieren (MRC)"
WORKFLOW="$HOME/Library/Services/$NAME.workflow"

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
  git clone -q --depth 1 "$REPO_URL" "$SRC_DIR"
fi
VERSION="$(git -C "$SRC_DIR" rev-parse --short HEAD 2>/dev/null || echo dev)"
msg "App bauen ($VERSION)"
BUILD="$(mktemp -d)/PDF MRC.app"
mkdir -p "$BUILD/Contents/MacOS" "$BUILD/Contents/Resources"
xcrun swiftc -swift-version 5 -parse-as-library -O -target "$(uname -m)-apple-macos13.0" \
  -o "$BUILD/Contents/MacOS/pdf-mrc" "$SRC_DIR"/App/Sources/*.swift

cat > "$BUILD/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
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
	<string>$VERSION</string>
	<key>LSMinimumSystemVersion</key>
	<string>13.0</string>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>MRCPaperlessPath</key>
	<string>$TOOL</string>
</dict>
</plist>
EOF

# Vorlage der Finder-Schnellaktion (die App schaltet sie ein/aus, indem sie sie nach ~/Library/Services kopiert)
TEMPLATE="$BUILD/Contents/Resources/$NAME.workflow"
mkdir -p "$TEMPLATE/Contents"
cat > "$TEMPLATE/Contents/Info.plist" <<EOF
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
				<string>$NAME</string>
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

cat > "$TEMPLATE/Contents/document.wflow" <<EOF
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
					<string>"$APP/Contents/MacOS/pdf-mrc" --kontextmenue "\$@"</string>
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

plutil -lint -s "$BUILD/Contents/Info.plist" "$TEMPLATE/Contents/Info.plist" "$TEMPLATE/Contents/document.wflow" \
  || die "Plist-Dateien ungültig."
codesign --force --sign - "$BUILD" >/dev/null 2>&1 || die "Signieren der App fehlgeschlagen."
first_install=true
[[ -d "$APP" ]] && first_install=false
mkdir -p "$HOME/Applications"
rm -rf "$APP"
mv "$BUILD" "$APP"
ok "App installiert: $APP"

# ---- Aufrufskript der Vorversion entfernen ------------------------------------------------------
if [[ -f "$BIN/pdf-mrc" ]] && grep -q "Finder-Schnellaktion" "$BIN/pdf-mrc"; then
  rm "$BIN/pdf-mrc"
  ok "Aufrufskript der Vorversion entfernt"
fi

# ---- Schnellaktion: bei Erstinstallation einschalten, sonst Zustand beibehalten -------------------
if $first_install || [[ -d "$WORKFLOW" ]]; then
  rm -rf "$WORKFLOW"
  mkdir -p "$(dirname "$WORKFLOW")"
  cp -R "$APP/Contents/Resources/$NAME.workflow" "$WORKFLOW"
  ok "Schnellaktion „${NAME}“ eingerichtet"
else
  ok "Schnellaktion bleibt ausgeschaltet (in der App einschaltbar)"
fi
/System/Library/CoreServices/pbs -flush >/dev/null 2>&1 || true
ok "Fertig. App „PDF MRC“ in ~/Applications; Rechtsklick auf PDFs → Schnellaktionen → „${NAME}“"
