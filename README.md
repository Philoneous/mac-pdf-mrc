# mac-pdf-mrc

Finder-Schnellaktion für macOS, die gescannte PDFs per *Mixed Raster Content* (MRC) verkleinert:
Rechtsklick auf eine oder mehrere PDFs → *Schnellaktionen → PDF komprimieren (MRC)*.

Die Verarbeitung übernimmt [paperless-mrc](https://github.com/Philoneous/paperless-mrc) – dasselbe Skript, das in
Paperless-ngx neue Scans komprimiert. Was dabei genau passiert (nur gescannte Seiten, leere Seiten entfernen,
Textebene übernehmen oder per Tesseract erkennen, falsche Seitengrößen korrigieren, Ergebnis prüfen), steht dort im
README. Dieses Repo enthält nur den Mac-Installer und die Schnellaktion.

## Verhalten

- Je ausgewählter PDF entsteht `<Name> (komprimiert).pdf` daneben. **Das Original bleibt unverändert.**
- Ist keine Verkleinerung möglich (keine gescannten Seiten, digital signiert, Ergebnis nicht kleiner, Fehler),
  entsteht keine Datei.
- Gibt es `<Name> (komprimiert).pdf` schon, wird die PDF übersprungen.
- Das Ergebnis erscheint als Mitteilung, z. B. „1447 KB -> 45 KB, 1 Seite(n), 1 leere entfernt, Textebene per Tesseract“.

## Installation

Als normaler Benutzer, [Homebrew](https://brew.sh) vorausgesetzt:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/Philoneous/mac-pdf-mrc/main/install.sh)"
```

Der Installer
- installiert per Homebrew Tesseract mit allen Sprachpaketen (`tesseract-lang`, großer Download), OpenJPEG, Poppler,
  jbig2enc und uv,
- installiert paperless-mrc (aktueller Stand von `main`) mit `uv tool install` in eine eigene Python-Umgebung,
- legt das Aufrufskript `~/.local/bin/pdf-mrc` an,
- schreibt die Schnellaktion nach `~/Library/Services/PDF komprimieren (MRC).workflow`.

**Update** (auch neue Versionen von paperless-mrc): denselben Befehl erneut ausführen.
**Entfernen:** `uv tool uninstall paperless-mrc`, dann `~/.local/bin/pdf-mrc` und
`~/Library/Services/PDF komprimieren (MRC).workflow` löschen.

## Hinweise

- Tesseract-Sprachen: `deu+eng+pol`, änderbar in `~/.local/bin/pdf-mrc` (`PAPERLESS_OCR_LANGUAGE`).
- Erscheint der Eintrag nicht im Kontextmenü: *Systemeinstellungen → Tastatur → Tastaturkurzbefehle → Dienste* prüfen,
  ob er aktiviert ist.
- Für Apple-Silicon-Macs gibt es fertige Pakete aller Python-Abhängigkeiten. Auf Intel-Macs muss archive-pdf-tools aus
  dem Quellcode gebaut werden (Xcode Command Line Tools); das ist ungetestet.
- Auf einem echten Mac noch nicht getestet: Erscheinen im Kontextmenü, Mitteilungen, Zugriffsabfragen von macOS beim
  ersten Lauf in geschützten Ordnern (Schreibtisch, Dokumente, Downloads).

## Lizenz

GNU Affero General Public License v3.0 oder später (`AGPL-3.0-or-later`), siehe [LICENSE](LICENSE) – wie paperless-mrc.
