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
        .windowResizability(.contentSize)
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
        .frame(width: 580, height: 780)
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
            Section("Texterkennung (nur Seiten ohne vorhandene Textebene)") {
                TextField("Sprachen", text: $profile.languages, prompt: Text("deu+eng+pol"))
                    .help("Tesseract-Sprachkürzel, mit + verbunden")
                Toggle("Seiten automatisch drehen", isOn: $profile.rotate)
                Toggle("Schräglage begradigen", isOn: $profile.deskew)
            }
            Section("Leere Seiten") {
                Toggle("Leere gescannte Seiten entfernen", isOn: $profile.removeBlank)
                TextField("Leer unter Tintenanteil (%)", value: $profile.blankInkPercent,
                          format: .number.precision(.fractionLength(0...4)))
                    .disabled(!profile.removeBlank)
                    .help("Eine Seite mit nur einer Seitenzahl liegt bei ca. 0,05 %. Standard: 0,005 %.")
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
