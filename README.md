# mac-pdf-mrc

Kleine Mac-App **PDF MRC**, die gescannte PDFs per *Mixed Raster Content* (MRC) stark verkleinert – manuell in der
App oder per Rechtsklick im Finder (*Schnellaktionen → PDF komprimieren (MRC)*).

Die Verarbeitung übernimmt [paperless-mrc](https://github.com/Philoneous/paperless-mrc) – dasselbe Skript, das in
Paperless-ngx neue Scans komprimiert. Was dabei genau passiert (nur gescannte Seiten, leere Seiten entfernen,
Textebene übernehmen oder per Tesseract erkennen, falsche Seitengrößen korrigieren, Ergebnis prüfen), steht dort im
README. Dieses Repo enthält die App, die Schnellaktion und den Installer.

## Die App

**Reiter „Manuell umwandeln“:** PDF hineinziehen oder auswählen, Einstellungen anpassen, *Umwandeln*. Das Ergebnis und
alle Meldungen von paperless-mrc erscheinen darunter, *Im Finder zeigen* öffnet die neue Datei.

**Reiter „Kontextmenü“:** Schnellaktion im Finder ein- und ausschalten und ihre Einstellungen festlegen (unabhängig von
der manuellen Umwandlung; *Einstellungen der manuellen Umwandlung übernehmen* kopiert sie herüber). Das Ergebnis jeder
Datei erscheint als Mitteilung.

Einstellungen (je Profil, *Standardwerte wiederherstellen* setzt sie zurück):

| Einstellung | Standard | Wirkung |
|---|---|---|
| **Seitenauswahl** | | |
| Auch PDFs mit digitalen Seiten bearbeiten | an | digitale Seiten bleiben unverändert; aus = nur reine Scan-PDFs |
| Fotoseiten unverändert lassen | an | MRC verschlechtert Fotos sichtbar |
| Texterkennung prüft unter Papierfläche (%) | 50 | Seiten mit weniger Papierfläche (Fotos, farbig hinterlegter Text) gelten nur mit genug erkanntem Text als Dokument |
| Foto unter sicher erkannten Wörtern | 10 | Wörter mit ≥ 3 Zeichen und hoher Erkennungssicherheit |
| Vektorisierte Scans rastern | an | Seiten ohne Bild und Text aus Tausenden Vektorelementen werden gerastert und durchsuchbar |
| Vektorisiert ab Elementen / Rasterauflösung | 1000 / 300 dpi | |
| **Texterkennung** | | |
| Vorhandene Textebene übernehmen | an | aus = immer neu mit Tesseract erkennen |
| Sprachen | `deu+eng+pol` | Tesseract-Sprachen; installiert sind alle (`tesseract-lang`) |
| Seiten automatisch drehen / Mindestsicherheit | an / 12 | nur Seiten ohne übernommene Textebene |
| Schräglage begradigen / erst ab / Suchbereich ± | an / 0,2° / 5° | Ergebnis am Rand des Suchbereichs gilt als unklar → keine Korrektur |
| Mindestdeutlichkeit Schräglage | 1,3 | nur begradigen, wenn sich der beste Winkel deutlich abhebt; verhindert, dass Logos oder Stempel auf textarmen Seiten eine gerade Seite schief drehen |
| **Leere Seiten** | | |
| Leere gescannte Seiten entfernen | an | |
| Leer unter Tintenanteil (%) | 0,005 | eine Seite mit nur einer Seitenzahl liegt bei ca. 0,05 % |
| Leer nur ab Papierfläche (%) | 90 | schützt kontrastarme Fotos davor, als leer entfernt zu werden |
| **Qualität und Größe** | | |
| Hintergrundauflösung | 1/2 | Text und Linien bleiben immer in voller Auflösung |
| Kompressionsrate | 200 | höher = kleiner; Farbflächen und hellgraue Schrift leiden |
| Falsche Seitengrößen auf A4 korrigieren | an | z. B. Handyscans mit 61 × 86 cm |
| Nachschärfen / Radius | 150 % / 1,5 px | hellgraue, dünne Schrift bleibt scharf; 0 = aus |
| Textmaske: Faktor | 0,5 | kleiner = auch hellgraue Schrift bleibt scharf; 1 = recode_pdf-Standard |
| Höchstauflösung | aus | höher aufgelöste Scans herunterskalieren (z. B. 300 dpi): schneller und kleiner |
| Gleichzeitige Seiten | automatisch | Anzahl der Prozessorkerne |
| **Ausgabe** | | |
| Ergebnis | Kopie | *Als Kopie neben dem Original* (`<Name> (komprimiert).pdf`, Zusatz änderbar) oder *Original ersetzen* (Original in den Papierkorb) |

Nicht abschaltbar (Sicherheit): digital signierte PDFs bleiben unverändert, und ein Ergebnis entsteht nur, wenn es
geprüft und kleiner ist. Einstellungsdateien älterer Versionen bleiben gültig; neue Einstellungen erhalten dort den
Standardwert.

Ist keine Verkleinerung möglich (keine gescannten Seiten, digital signiert, Ergebnis nicht kleiner, Fehler), entsteht
keine Datei und das Original bleibt, wie es ist. Eine schon vorhandene Kopie wird nicht überschrieben.

Gespeichert werden die Einstellungen in `~/Library/Application Support/mac-pdf-mrc/settings.json`.

**Reiter „Paperless“:** Adresse des Paperless-ngx-Servers und API-Token (in Paperless unter *Mein Profil*), *Speichern
und Verbindung testen*, dazu zwei weitere Schnellaktionen ein- und ausschalten:

- **An Paperless senden** – schickt die PDF unverändert; Paperless (mit paperless-mrc) komprimiert sie dort.
- **Komprimieren und an Paperless senden** – komprimiert vorher auf dem Mac (Einstellungen aus dem Reiter
  „Kontextmenü“) und schickt das Ergebnis; ist keine Verkleinerung möglich, das Original. paperless-mrc auf dem Server
  lässt eine so komprimierte Datei unverändert (sie besteht nicht mehr aus einem einzelnen Seitenbild), es wird also
  nicht doppelt umgewandelt.

In beiden Fällen bleibt die Datei auf dem Mac unverändert. Die App lädt über `/api/documents/post_document/` hoch,
wartet bis zu drei Minuten auf das Ergebnis (`/api/tasks/`) und meldet es als Mitteilung: angelegtes Dokument (mit
Nummer), Duplikat oder Fehler. Verbindung und Token werden vor dem Upload geprüft.

- Das Token liegt im macOS-Schlüsselbund, nicht in `settings.json`. Weil die App bei jedem Update neu gebaut wird,
  fragt macOS nach einem Update einmal, ob sie weiter darauf zugreifen darf (*Immer erlauben*).
- Im Heimnetz fragt macOS beim ersten Senden, ob die App Geräte im lokalen Netz erreichen darf.
- **Von unterwegs** nur über HTTPS (z. B. Reverse-Proxy mit Zertifikat) oder ein VPN – bei `http://` gehen Token und
  Dokumente im Klartext durchs Netz; die App weist darauf hin. Selbstsignierte Zertifikate werden nicht akzeptiert.
- Für Skripte: `echo TOKEN | "$HOME/Applications/PDF MRC.app/Contents/MacOS/pdf-mrc" --paperless-token` speichert das Token.

## Installation

Als normaler Benutzer, [Homebrew](https://brew.sh) vorausgesetzt:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/Philoneous/mac-pdf-mrc/main/install.sh)"
```

Der Installer
- installiert per Homebrew Tesseract mit allen Sprachpaketen (`tesseract-lang`, großer Download), OpenJPEG, Poppler,
  jbig2enc und uv,
- installiert paperless-mrc (aktueller Stand von `main`) mit `uv tool install` in eine eigene Python-Umgebung,
- baut die App aus dem Quellcode (`swiftc` aus den Command Line Tools, die Homebrew ohnehin voraussetzt) nach
  `~/Applications/PDF MRC.app` – lokal gebaut, daher keine Gatekeeper-Warnung,
- richtet bei der Erstinstallation die Schnellaktion in `~/Library/Services` ein; bei Updates bleibt sie an oder aus,
  wie in der App eingestellt.

**Update** (App und paperless-mrc): denselben Befehl erneut ausführen.
**Entfernen:** `uv tool uninstall paperless-mrc`, dann `~/Applications/PDF MRC.app`,
`~/Library/Services/PDF komprimieren (MRC).workflow` und `~/Library/Application Support/mac-pdf-mrc` löschen.

## Hinweise

- Voraussetzung macOS 13 oder neuer, Apple Silicon. Auf Intel-Macs müsste archive-pdf-tools aus dem Quellcode gebaut
  werden; das ist ungetestet.
- Erscheint die Schnellaktion nicht im Kontextmenü: *Systemeinstellungen → Tastatur → Tastaturkurzbefehle → Dienste*
  prüfen, ob sie aktiviert ist.
- Beim ersten Zugriff auf Schreibtisch, Dokumente oder Downloads fragt macOS nach der Erlaubnis.

## Entwicklung

Bei jedem Push baut und testet GitHub Actions auf einem macOS-Runner (`.github/workflows/macos.yml`): Installer aus
dem Checkout, Ende-zu-Ende-Test des Kontextmenü-Modus (`ci/test_app.py`), Senden an Paperless gegen einen
Ersatzserver, der sich wie Paperless-ngx 3.3.0 verhält (`ci/test_paperless.py`, `ci/paperless_mock.py`), und je ein
Bildschirmfoto der Reiter (Artefakt `screenshots`; bei manuellem Start zusätzlich im Branch `ci-screenshots`). Schlägt ein Schritt fehl,
stehen die letzten Ausgabezeilen als Annotation am Lauf. Lokal: `SRC_DIR=$PWD bash install.sh`.

Die App ruft paperless-mrc wie Paperless auf: Umgebungsvariable `DOCUMENT_WORKING_PATH` auf eine Kopie, Einstellungen
über `PAPERLESS_OCR_*` und `MRC_*`, Ergebnis in der letzten Ausgabezeile mit Präfix `paperless-mrc:`.

## Lizenz

GNU Affero General Public License v3.0 oder später (`AGPL-3.0-or-later`), siehe [LICENSE](LICENSE) – wie paperless-mrc.
