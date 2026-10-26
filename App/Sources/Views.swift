// SPDX-License-Identifier: AGPL-3.0-or-later
import AppKit
import SwiftUI
import UniformTypeIdentifiers

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct PDFMRCApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var store = SettingsStore()

    var body: some Scene {
        WindowGroup("PDF MRC") {
            ContentView().environmentObject(store)
        }
        .defaultSize(width: 580, height: 780)
        .windowResizability(.contentMinSize)
    }
}

struct ContentView: View {
    @AppStorage("tab") private var tab = "umwandeln"

    var body: some View {
        TabView(selection: $tab) {
            ConvertView()
                .tabItem { Text("Manuell umwandeln") }
                .tag("umwandeln")
            ContextMenuView()
                .tabItem { Text("Kontextmenü") }
                .tag("kontextmenue")
        }
        .padding()
        .frame(minWidth: 560, idealWidth: 580, minHeight: 520, idealHeight: 780)
    }
}

// MARK: - Manuelle Umwandlung

struct ConvertView: View {
    @EnvironmentObject private var store: SettingsStore
    @State private var file: URL?
    @State private var running = false
    @State private var result: Conversion?
    @State private var failure: String?
    @State private var choosing = false
    @State private var dropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            dropZone
            ProfileForm(profile: $store.settings.manual)
            HStack {
                Button("Umwandeln", action: convert)
                    .keyboardShortcut(.defaultAction)
                    .disabled(file == nil || running)
                if running {
                    ProgressView().controlSize(.small)
                    Text("Wird umgewandelt …").foregroundStyle(.secondary)
                }
                Spacer()
                if let output = result?.output {
                    Button("Im Finder zeigen") { NSWorkspace.shared.activateFileViewerSelecting([output]) }
                }
            }
            if let failure {
                Text(failure).foregroundStyle(.red)
            }
            if let result {
                Text(result.message).bold().textSelection(.enabled)
                if !result.log.isEmpty {
                    ScrollView {
                        Text(result.log)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 70)
                }
            }
        }
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.pdf]) { picked in
            if case .success(let url) = picked { select(url) }
        }
    }

    private var dropZone: some View {
        RoundedRectangle(cornerRadius: 10)
            .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6]))
            .foregroundStyle(dropTargeted ? Color.accentColor : Color.secondary)
            .frame(height: 86)
            .overlay {
                VStack(spacing: 8) {
                    Text(file?.lastPathComponent ?? "PDF hierher ziehen")
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button("PDF auswählen …") { choosing = true }
                }
                .padding(.horizontal)
            }
            .dropDestination(for: URL.self) { urls, _ in
                guard let url = urls.first(where: { $0.pathExtension.lowercased() == "pdf" }) else { return false }
                select(url)
                return true
            } isTargeted: { dropTargeted = $0 }
    }

    private func select(_ url: URL) {
        file = url
        result = nil
        failure = nil
    }

    private func convert() {
        guard let file else { return }
        let profile = store.settings.manual
        running = true
        result = nil
        failure = nil
        Task.detached {
            let outcome = Result { try Converter.convert(file, with: profile) }
            await MainActor.run {
                running = false
                switch outcome {
                case .success(let conversion): result = conversion
                case .failure(let error): failure = error.localizedDescription
                }
            }
        }
    }
}

// MARK: - Kontextmenü

struct ContextMenuView: View {
    @EnvironmentObject private var store: SettingsStore
    @State private var enabled = QuickAction.isInstalled
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Schnellaktion „PDF komprimieren (MRC)“ im Finder anzeigen", isOn: $enabled)
                .onChange(of: enabled) { on in
                    guard on != QuickAction.isInstalled else { return }
                    do {
                        try QuickAction.setInstalled(on)
                        failure = nil
                    } catch {
                        failure = error.localizedDescription
                        enabled = QuickAction.isInstalled
                    }
                }
            Text("Rechtsklick auf eine oder mehrere PDFs → Schnellaktionen. Dabei gelten die Einstellungen unten; "
                 + "das Ergebnis erscheint als Mitteilung.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let failure {
                Text(failure).foregroundStyle(.red)
            }
            Button("Einstellungen der manuellen Umwandlung übernehmen") {
                store.settings.quickAction = store.settings.manual
            }
            ProfileForm(profile: $store.settings.quickAction)
        }
    }
}

// MARK: - Einstellungen eines Profils

struct ProfileForm: View {
    @Binding var profile: Profile

    var body: some View {
        Form {
            Section("Seitenauswahl") {
                Toggle("Auch PDFs mit digitalen Seiten bearbeiten", isOn: $profile.mixedPdfs)
                    .help("Digitale Seiten bleiben dabei unverändert. Aus: nur PDFs, die ausschließlich aus Scans bestehen.")
                Toggle("Fotoseiten unverändert lassen", isOn: $profile.skipPhotos)
                    .help("MRC verschlechtert Fotos sichtbar. Seiten mit wenig Papierfläche (Fotos, aber auch farbig "
                          + "hinterlegter Text) gelten nur mit genug erkanntem Text als Dokument.")
                TextField("Texterkennung prüft unter Papierfläche (%)", value: $profile.photoPaperPercent,
                          format: .number.precision(.fractionLength(0...1)))
                    .disabled(!profile.skipPhotos)
                    .help("Gemessen: Dokumente auf weißem Papier 61–98 %, Fotos 11–43 %. Standard: 50.")
                TextField("Foto unter sicher erkannten Wörtern", value: $profile.photoMinWords, format: .number)
                    .disabled(!profile.skipPhotos)
                    .help("Wörter mit mindestens 3 Zeichen und hoher Erkennungssicherheit. Standard: 10.")
                Toggle("Vektorisierte Scans rastern und durchsuchbar machen", isOn: $profile.vectorPages)
                    .help("Manche Scanprogramme speichern Seiten als Tausende Vektorelemente ohne Text.")
                TextField("Vektorisiert ab Elementen", value: $profile.vectorMinItems, format: .number)
                    .disabled(!profile.vectorPages)
                    .help("Seite ohne Bild und Text mit mindestens so vielen Linien/Kurven. Standard: 1000.")
                Picker("Rasterauflösung", selection: $profile.vectorDpi) {
                    Text("200 dpi").tag(200)
                    Text("300 dpi (Standard)").tag(300)
                    Text("400 dpi").tag(400)
                    Text("600 dpi").tag(600)
                }
                .disabled(!profile.vectorPages)
            }
            Section("Texterkennung") {
                Toggle("Vorhandene Textebene übernehmen", isOn: $profile.keepTextLayer)
                    .help("Aus: Text immer neu mit Tesseract erkennen (dann wird auch gedreht und begradigt).")
                TextField("Sprachen", text: $profile.languages, prompt: Text("deu+eng+pol"))
                    .help("Tesseract-Sprachkürzel, mit + verbunden")
                Toggle("Seiten automatisch drehen", isOn: $profile.rotate)
                TextField("Mindestsicherheit Drehung", value: $profile.rotateThreshold,
                          format: .number.precision(.fractionLength(0...1)))
                    .disabled(!profile.rotate)
                    .help("Tesseract-Konfidenz, ab der gedreht wird. Standard: 12.")
                Toggle("Schräglage begradigen", isOn: $profile.deskew)
                TextField("Erst ab Schräglage (Grad)", value: $profile.deskewMinAngle,
                          format: .number.precision(.fractionLength(0...2)))
                    .disabled(!profile.deskew)
                    .help("Kleinere Schräglagen bleiben. Standard: 0,2.")
                TextField("Suchbereich ± (Grad)", value: $profile.deskewMaxAngle,
                          format: .number.precision(.fractionLength(0...1)))
                    .disabled(!profile.deskew)
                    .help("Ein Ergebnis am Rand gilt als unklar (z. B. Seite ohne Textzeilen) und wird nicht korrigiert. "
                          + "Standard: 5.")
            }
            Section("Leere Seiten") {
                Toggle("Leere gescannte Seiten entfernen", isOn: $profile.removeBlank)
                TextField("Leer unter Tintenanteil (%)", value: $profile.blankInkPercent,
                          format: .number.precision(.fractionLength(0...4)))
                    .disabled(!profile.removeBlank)
                    .help("Eine Seite mit nur einer Seitenzahl liegt bei ca. 0,05 %. Standard: 0,005 %.")
                TextField("Leer nur ab Papierfläche (%)", value: $profile.blankPaperPercent,
                          format: .number.precision(.fractionLength(0...1)))
                    .disabled(!profile.removeBlank)
                    .help("Schützt kontrastarme Fotos (z. B. einer Wand) davor, als leer entfernt zu werden. Standard: 90.")
            }
            Section("Qualität und Größe") {
                Picker("Hintergrundauflösung", selection: $profile.bgDownsample) {
                    Text("Voll").tag(1)
                    Text("1/2 (Standard)").tag(2)
                    Text("1/3").tag(3)
                    Text("1/4").tag(4)
                }
                LabeledContent("Kompressionsrate: \(Int(profile.bgRate))") {
                    Slider(value: $profile.bgRate, in: 50...800, step: 25)
                }
                .help("Höher = kleinere Datei; Farbflächen und hellgraue Schrift leiden. Standard: 200.")
                Toggle("Falsche Seitengrößen (z. B. Handyscans) auf A4 korrigieren", isOn: $profile.fitA4)
                Picker("Höchstauflösung", selection: $profile.maxDpi) {
                    Text("Aus (Standard)").tag(0)
                    Text("200 dpi").tag(200)
                    Text("300 dpi").tag(300)
                    Text("400 dpi").tag(400)
                }
                .help("Höher aufgelöste Scans werden herunterskaliert: schneller und kleiner, feinste Details gehen verloren.")
                LabeledContent(profile.sharpen == 0 ? "Nachschärfen: aus" : "Nachschärfen: \(profile.sharpen) %") {
                    Slider(value: Binding(get: { Double(profile.sharpen) }, set: { profile.sharpen = Int($0) }),
                           in: 0...300, step: 25)
                }
                .help("Hebt hellgraue, dünne Schrift an, damit sie scharf bleibt. Standard: 150 %, 0 = aus.")
                TextField("Radius Nachschärfen (px bei 200 dpi)", value: $profile.sharpenRadius,
                          format: .number.precision(.fractionLength(0...1)))
                    .disabled(profile.sharpen == 0)
                    .help("Standard: 1,5. Wird mit der Auflösung des Scans skaliert.")
                Stepper(profile.jobs == 0 ? "Gleichzeitige Seiten: automatisch" : "Gleichzeitige Seiten: \(profile.jobs)",
                        value: $profile.jobs, in: 0...16)
                    .help("Automatisch = Anzahl der Prozessorkerne.")
            }
            Section("Ausgabe") {
                Picker("Ergebnis", selection: $profile.output) {
                    Text("Als Kopie neben dem Original").tag(OutputMode.copy)
                    Text("Original ersetzen (Original in den Papierkorb)").tag(OutputMode.replace)
                }
                .pickerStyle(.radioGroup)
                if profile.output == .copy {
                    TextField("Namenszusatz", text: $profile.suffix)
                }
            }
            Section {
                Button("Standardwerte wiederherstellen") { profile = Profile() }
            }
        }
        .formStyle(.grouped)
    }
}
