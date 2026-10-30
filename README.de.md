# PDF MRC für macOS

*[English](README.md) · Deutsch*

<img src="App/Icon/icon.svg" width="96" align="right" alt="">

Kleine Mac-App, die gescannte PDFs per *Mixed Raster Content* (MRC) stark verkleinert – manuell in der App oder per
Rechtsklick im Finder – und sie an einen [Paperless-ngx](https://github.com/paperless-ngx/paperless-ngx)-Server
schicken kann.

Die Verarbeitung übernimmt [paperless-mrc](https://github.com/Philoneous/paperless-mrc) – dasselbe Skript, das in
Paperless-ngx neue Scans komprimiert –, das wiederum [archive-pdf-tools](https://github.com/internetarchive/archive-pdf-tools)
des Internet Archive nutzt. Was dabei genau passiert (nur gescannte Seiten, leere Seiten entfernen, Textebene
übernehmen oder per Tesseract erkennen, falsche Seitengrößen korrigieren, Ergebnis prüfen), steht dort im README.

## Installation

1. `PDF-MRC.dmg` aus dem [neuesten Release](https://github.com/Philoneous/mac-pdf-mrc/releases/latest) laden.
2. Öffnen und **PDF MRC** in **Programme** ziehen.
3. Erster Start: Die App ist nicht von Apple beglaubigt, macOS blockiert sie deshalb einmal. *Systemeinstellungen →
   Datenschutz & Sicherheit* öffnen, nach unten scrollen und **Dennoch öffnen** klicken.

Voraussetzungen: macOS 13 oder neuer, Apple-Chip. Alles, was die App braucht (Python, paperless-mrc, Tesseract,
OpenJPEG, jbig2enc), steckt in der App – Homebrew ist nicht nötig. Das Ergebnis prüft die App zusätzlich zu den
Prüfungen von paperless-mrc (Seitenzahl, Textebene) mit dem PDF-Darsteller von macOS: Jede Seite muss sich öffnen
und zeichnen lassen.

**Updates** installiert die App automatisch (Sparkle): Sie sucht beim Start – auch wenn eine Schnellaktion sie im
Hintergrund startet – und alle vier Stunden, solange sie läuft, lädt neue Versionen im Hintergrund und installiert sie
beim Beenden. Unter *Einstellungen* lässt sich *automatisch installieren*, *vor der Installation fragen* oder *nur
manuell* wählen und sofort suchen (auch *PDF MRC → Nach Updates suchen …*). Updates sind signiert (EdDSA) und werden
vor der Installation geprüft.

## Die App

Die Seitenleiste links führt zu den Bereichen *Manuell umwandeln*, *Kontextmenü*, *Paperless*, *Verlauf*,
*Einstellungen* und *Info*.

**Manuell umwandeln:** PDF hineinziehen oder auswählen, Einstellungen anpassen, *Umwandeln*. Das Ergebnis und alle
Meldungen von paperless-mrc erscheinen darunter, *Im Finder zeigen* öffnet die neue Datei.

**Kontextmenü:** Schnellaktion *PDF komprimieren (MRC)* im Finder ein- und ausschalten und ihre Einstellungen
festlegen (unabhängig von der manuellen Umwandlung; *Einstellungen aus „Manuell umwandeln“ übernehmen* kopiert sie
herüber). Rechtsklick auf ein oder mehrere PDFs → *Schnellaktionen*. Die Schnellaktion übergibt die Dateien an die App und ist
sofort fertig; die App arbeitet im Hintergrund (ohne Dock-Symbol), zeigt währenddessen ein Symbol in der Menüleiste –
ein Klick zeigt den Fortschritt jeder Datei und die letzten Ergebnisse – und meldet jedes Ergebnis als Mitteilung mit
*Im Finder zeigen* / *In Paperless öffnen*. macOS fragt einmal, ob PDF MRC Mitteilungen senden darf; ohne Erlaubnis
nutzt die App einfache Mitteilungen. Ist alles erledigt, verschwindet das Symbol und die App beendet sich (außer ihr
Fenster ist offen).

**Paperless:** Adresse des Paperless-ngx-Servers und API-Token (in Paperless unter *Mein Profil*), *Speichern und
Verbindung testen*, dazu zwei weitere Schnellaktionen:

- **An Paperless senden** – schickt das PDF unverändert; Paperless (mit paperless-mrc) komprimiert es dort.
- **Komprimieren und an Paperless senden** – komprimiert erst auf dem Mac (Einstellungen aus dem Reiter *Kontextmenü*)
  und schickt das Ergebnis, oder das Original, wenn es sich nicht verkleinern lässt. paperless-mrc auf dem Server lässt
  eine solche Datei unverändert, es wird also nichts doppelt umgewandelt.

Die Datei auf dem Mac bleibt in beiden Fällen unverändert. Die App lädt über `/api/documents/post_document/` hoch,
wartet bis zu zehn Minuten, bis Paperless fertig ist (`/api/tasks/`), und meldet das Ergebnis als Mitteilung:
angelegtes Dokument (mit Nummer), Duplikat oder Fehler. Verbindung und Token werden vor dem Hochladen geprüft. Die meiste
Zeit vergeht meist auf dem Server (paperless-mrc und die Verarbeitung in Paperless); der Verlauf zeigt, wie lange jeder
Schritt gedauert hat.

- Das Token liegt im macOS-Schlüsselbund. Nach einem Update fragt macOS einmal, ob die App weiter darauf zugreifen darf
  (*Immer erlauben*) – die App ist ad hoc signiert, jede Version hat also eine neue Signatur.
- Im Heimnetz fragt macOS beim ersten Mal, ob die App auf Geräte im lokalen Netzwerk zugreifen darf.
- **Von unterwegs** HTTPS (z. B. Reverse Proxy mit Zertifikat) oder ein VPN nutzen – mit `http://` gehen Token und
  Dokumente unverschlüsselt über das Netz; die App weist darauf hin. Selbstsignierte Zertifikate werden nicht
  unterstützt.

**Sprachen:** Deutsch und Englisch sind enthalten. Weitere Tesseract-Sprachen (z. B. `fra`, `pol`, `chi_sim`) lassen
sich im Sprachfeld der Einstellungen eintragen – die App zeigt fehlende Sprachen an und lädt sie mit *Laden* aus
[tessdata_fast](https://github.com/tesseract-ocr/tessdata_fast). Sie liegen in
`~/Library/Application Support/mac-pdf-mrc/tessdata`.

**Verlauf:** die letzten 50 Umwandlungen – manuell, über das Kontextmenü und an Paperless gesendet – mit Ergebnis,
Größen, Seitenzahl, Dauer jedes Schritts (Komprimieren, Hochladen, Verarbeitung in Paperless) und dem vollständigen
Protokoll von paperless-mrc mit den Details jeder Seite (Fotoseiten übersprungen, Seiten gedreht oder begradigt, leere
Seiten entfernt). Je Eintrag *Im Finder zeigen*, *In Paperless öffnen* und *Protokoll kopieren*; *Verlauf löschen …*
entfernt alle Einträge.

**Sprache:** Englisch oder Deutsch, unter *Einstellungen* wählbar (*Systemsprache*: Deutsch, wenn der Mac Deutsch
verwendet, sonst Englisch). Sie gilt auch für die Namen der Schnellaktionen im Finder und das Protokoll von
paperless-mrc; macOS lädt die Sprache beim Start der App, nach einem Wechsel bietet die App daher *Jetzt neu starten*
an.

### Einstellungen (je Profil, *Standardwerte wiederherstellen* setzt sie zurück)

Jede Einstellung zeigt diese Erklärung als Tooltip, wenn man den Mauszeiger darüber hält.

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
| Sprachen | `deu+eng` | Tesseract-Sprachen; weitere nachladbar |
| Seiten automatisch drehen / Mindestsicherheit | an / 12 | nur Seiten ohne übernommene Textebene |
| Unsichere Drehung per Texterkennung prüfen | an | ist sich die Ausrichtungserkennung unsicher, schlägt aber eine Drehung vor, wird in beiden Lagen erkannt; gedreht nur bei mindestens 1,5-mal so vielen sicheren Wörtern (z. B. hochkant gescannte Querformat-Formulare) |
| Schräglage begradigen / erst ab / Suchbereich ± | an / 0,2° / 5° | Ergebnis am Rand des Suchbereichs gilt als unklar → keine Korrektur |
| Mindestdeutlichkeit der Schräglage | 1,3 | nur begradigen, wenn sich der beste Winkel deutlich abhebt; verhindert, dass Logos oder Stempel auf textarmen Seiten eine gerade Seite schief drehen |
| **Leere Seiten** | | |
| Leere gescannte Seiten entfernen | an | |
| Leer unter Tintenanteil (%) | 0,005 | eine Seite mit nur einer Seitenzahl liegt bei ca. 0,05 % |
| Leer nur ab Papierfläche (%) | 90 | schützt kontrastarme Fotos davor, als leer entfernt zu werden |
| **Qualität und Größe** | | |
| Hintergrundauflösung | 1/2 | Text und Linien bleiben immer in voller Auflösung |
| Kompressionsrate | 200 | höher = kleiner; Farbflächen und hellgraue Schrift leiden |
| Falsche Seitengrößen auf A4 korrigieren | an | z. B. Handyscans mit 61 × 86 cm |
| Nachschärfen / Radius | 150 % / 1,5 px | hellgraue, dünne Schrift bleibt scharf; 0 = aus |
| Textmaske, Faktor | 0,5 | kleiner = auch hellgraue Schrift bleibt scharf; 1 = recode_pdf-Standard |
| Höchstauflösung | aus | höher aufgelöste Scans herunterskalieren (z. B. 300 dpi): schneller und kleiner |
| Gleichzeitige Seiten | automatisch | Anzahl der Prozessorkerne |
| **Ausgabe** | | |
| Ergebnis | Kopie | *Als Kopie neben dem Original speichern* (`<Name> (komprimiert).pdf`, Zusatz änderbar) oder *Original ersetzen* (Original in den Papierkorb) |

Nicht abschaltbar (Sicherheit): digital signierte PDFs bleiben unverändert, und ein Ergebnis entsteht nur, wenn es
geprüft und kleiner ist. Sonst entsteht keine Datei und das Original bleibt, wie es ist; eine schon vorhandene Kopie
wird nicht überschrieben. Gespeichert werden die Einstellungen in
`~/Library/Application Support/mac-pdf-mrc/settings.json`.

## Hinweise

- Erscheint eine Schnellaktion nicht: *Systemeinstellungen → Tastatur → Tastaturkurzbefehle → Dienste* prüfen.
- Beim ersten Zugriff auf Schreibtisch, Dokumente oder Downloads fragt macOS nach der Erlaubnis.
- **Deinstallieren:** *PDF MRC* aus Programme löschen, die Schnellaktionen in `~/Library/Services` (Dateinamen englisch:
  *Compress PDF (MRC)*, *Send to Paperless*, *Compress and Send to Paperless*) und
  `~/Library/Application Support/mac-pdf-mrc`.
- Intel-Macs werden nicht unterstützt (archive-pdf-tools gibt es nicht als fertiges Intel-Paket).

### Alternative: Homebrew-Installer (Backup)

Der bisherige Weg funktioniert weiterhin und baut die App lokal (braucht [Homebrew](https://brew.sh)); aktualisiert wird
durch erneutes Ausführen, eine eingebaute Update-Funktion gibt es dabei nicht:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/Philoneous/mac-pdf-mrc/main/install.sh)"
```

Er installiert nach `~/Applications/PDF MRC.app`. **Wechsel zur DMG-Version:** `~/Applications/PDF MRC.app` löschen,
`uv tool uninstall paperless-mrc` ausführen, die DMG-Version installieren und einmal öffnen (sie legt die
Schnellaktionen neu an).

## Entwicklung

`build/build_app.sh dist --standalone` baut die eigenständige App (zum Bauen nötig: Homebrew, uv, Netz). Es
entfernt alles, was paperless-mrc nie lädt (gemessen mit einem Import-Protokoll über dessen Testsuite), erzeugt die
Hinweise zu Drittkomponenten (`build/notices.py`) und prüft, dass jedes mitgelieferte Programm und jede Bibliothek alle
geladenen Bibliotheken findet (`build/check_bundle.py`);
`build/make_dmg.sh dist dist/PDF-MRC.dmg` packt sie. GitHub Actions (`.github/workflows/macos.yml`) baut und testet bei
jedem Push auf `main`, zwei Jobs parallel:

- **App (DMG):** bauen, DMG, aus dem DMG nach `/Applications` installieren, **Homebrew ausblenden**, dann End-to-End-Tests
  mit dem Python der App: Kontextmenü-Modus auf Englisch und Deutsch (`ci/test_app.py`), Sprache nachladen, Senden an
  einen Ersatzserver, der sich wie Paperless-ngx 3.3.0 verhält (`ci/test_paperless.py`, `ci/paperless_mock.py`),
  Bildschirmfotos und ein echtes **Sparkle-Update** von einem lokalen Feed (`ci/test_update.sh`).
- **Homebrew-Installer (Backup):** `install.sh` aus dem Checkout und dieselben Tests.

`ci/check_strings.py` prüft, dass jeder Text eine englische Übersetzung hat. Schlägt ein Schritt fehl, hängen seine
letzten Ausgabezeilen als Annotation am Lauf; bei manuellem Start landen zusätzlich die Bildschirmfotos im Branch
`ci-screenshots`.

**Releases:** *Actions → macOS → Run workflow* auf `main` mit einer Version (z. B. `1.0.0`) starten oder ein Tag
`vX.Y.Z` pushen. Der Workflow baut und testet wie oben, danach signiert `build/release.sh`
das DMG für Sparkle (Repository-Secret `SPARKLE_PRIVATE_KEY`, geprüft gegen `SUPublicEDKey` in der App), schreibt
`appcast.xml`, lädt die Quellarchive der mitgelieferten Copyleft-Komponenten (siehe *Lizenz*) ins Release
`third-party-sources` und legt das GitHub-Release an. Installierte Apps finden es über
`https://github.com/Philoneous/mac-pdf-mrc/releases/latest/download/appcast.xml`. Ein normaler Push löst kein Update
aus.

Die App ruft paperless-mrc so auf wie Paperless: `DOCUMENT_WORKING_PATH` auf eine Kopie, Einstellungen über
`PAPERLESS_OCR_*` und `MRC_*`, Ergebnis aus der maschinenlesbaren Zeile `paperless-mrc-result: {…}`.

## Unterstützen

PDF MRC ist kostenlos. Wenn dir die App Zeit oder Speicherplatz spart, kannst du die Entwicklung auf
[Ko-fi](https://ko-fi.com/Philoneous) unterstützen (PayPal oder Karte, ohne Konto) – auch über den Knopf *Sponsor* auf
GitHub oder *Info → Auf Ko-fi unterstützen* in der App. Beiträge sind freiwillig und keine steuerlich absetzbaren
Spenden.

## Lizenz

Copyright © 2026 Philoneous. GNU Affero General Public License v3.0 oder später (`AGPL-3.0-or-later`), siehe
[LICENSE](LICENSE) – wie paperless-mrc.

**Mitgelieferte Komponenten.** Die App enthält Software Dritter, jeweils unter eigener Lizenz – u. a.
[archive-pdf-tools](https://github.com/internetarchive/archive-pdf-tools) und
[archive-hocr-tools](https://github.com/internetarchive/archive-hocr-tools) (Internet Archive, AGPL-3.0),
[PyMuPDF](https://github.com/pymupdf/PyMuPDF) und [MuPDF](https://mupdf.com) (Artifex, AGPL-3.0),
[pikepdf](https://github.com/pikepdf/pikepdf) (MPL-2.0), [Tesseract](https://github.com/tesseract-ocr/tesseract)
(Apache-2.0), [Python](https://www.python.org) ([python-build-standalone](https://github.com/astral-sh/python-build-standalone)),
NumPy, SciPy, scikit-image, Pillow, OpenJPEG, jbig2enc, Leptonica und [Sparkle](https://sparkle-project.org). Die
vollständige Liste mit Versionen, Lizenzen und Lizenztexten entsteht beim Bauen: in der App unter
*Info → Hinweise zu Drittkomponenten* (`PDF MRC.app/Contents/Resources/Licenses`) und an jedem Release als
`THIRD-PARTY-NOTICES.txt`. Die genauen Quellarchive aller Copyleft-Komponenten liegen im Release
[third-party-sources](https://github.com/Philoneous/mac-pdf-mrc/releases/tag/third-party-sources).

PDF MRC ist ein unabhängiges Projekt und steht in keiner Verbindung zu Paperless-ngx, dem Internet Archive oder
Artifex.
