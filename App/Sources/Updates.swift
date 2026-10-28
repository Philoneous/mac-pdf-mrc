// SPDX-License-Identifier: AGPL-3.0-or-later
import SwiftUI
#if SPARKLE
import Sparkle
#endif

/// Updates über Sparkle (nur eigenständige App; build_app.sh --standalone kompiliert mit -D SPARKLE).
/// Feed, Schlüssel und Voreinstellungen (automatisch suchen und installieren) stehen im Info.plist.
enum Updates {
    #if SPARKLE
    static let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil,
                                                         userDriverDelegate: nil)
    #endif

    static var available: Bool {
        #if SPARKLE
        return true
        #else
        return false
        #endif
    }

    static var lastCheck: Date? {
        #if SPARKLE
        return controller.updater.lastUpdateCheckDate
        #else
        return nil
        #endif
    }

    static func checkNow() {
        #if SPARKLE
        controller.updater.checkForUpdates()
        #endif
    }
}

/// Wie Updates eingespielt werden (Sparkle: automaticallyChecksForUpdates / automaticallyDownloadsUpdates).
enum UpdateMode: String, CaseIterable, Identifiable {
    case automatic  // suchen, laden, beim Beenden installieren
    case ask        // suchen und vor der Installation fragen
    case manual     // nur über „Jetzt nach Updates suchen“
    var id: String { rawValue }

    static var current: UpdateMode {
        get {
            guard Updates.automaticChecks else { return .manual }
            return Updates.automaticInstall ? .automatic : .ask
        }
        set {
            Updates.automaticChecks = newValue != .manual
            Updates.automaticInstall = newValue == .automatic
        }
    }
}

/// Reiter „Info“ (und Einstellungsfenster ⌘,): Version, Updates, Lizenz.
struct InfoView: View {
    @State private var mode = UpdateMode.current
    static let repository = URL(string: "https://github.com/Philoneous/mac-pdf-mrc")!

    private static func info(_ key: String) -> String {
        Bundle.main.object(forInfoDictionaryKey: key) as? String ?? "?"
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 16) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable().frame(width: 72, height: 72)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(verbatim: "PDF MRC").font(.title2).bold()
                        Text(L("Version %@ (Build %@)", Self.info("CFBundleShortVersionString"), Self.info("CFBundleVersion")))
                        Text(L("mit paperless-mrc %@", Self.info("MRCPaperlessVersion")))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }

            Section("Updates") {
                if Updates.available {
                    Picker("Updates", selection: $mode) {
                        Text("Automatisch installieren").tag(UpdateMode.automatic)
                        Text("Automatisch suchen, vor Installation fragen").tag(UpdateMode.ask)
                        Text("Nur manuell").tag(UpdateMode.manual)
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()
                    .onChange(of: mode) { UpdateMode.current = $0 }
                    TimelineView(.periodic(from: .now, by: 10)) { _ in
                        LabeledContent("Zuletzt gesucht", value: Updates.lastCheck.map {
                            $0.formatted(date: .abbreviated, time: .shortened)
                        } ?? L("noch nie"))
                    }
                    HStack {
                        Button("Jetzt nach Updates suchen") { Updates.checkNow() }
                        Spacer()
                        Link("Versionshinweise", destination: Self.repository.appendingPathComponent("releases"))
                    }
                    Text("Die App sucht beim Öffnen und danach alle vier Stunden, solange sie geöffnet ist. Beim Umwandeln über das Kontextmenü wird nicht gesucht. Automatisch geladene Updates werden beim Beenden der App installiert.")
                        .font(.footnote).foregroundStyle(.secondary)
                } else {
                    Text("Diese Installation wird über den Homebrew-Installer aktualisiert (install.sh erneut ausführen).")
                        .foregroundStyle(.secondary)
                }
            }

            Section("Lizenz") {
                Text("PDF MRC ist freie Software unter der GNU Affero General Public License, Version 3 oder später (AGPL-3.0-or-later). Sie wird ohne jede Gewährleistung bereitgestellt.")
                HStack {
                    Link("Lizenztext", destination: URL(string: "https://www.gnu.org/licenses/agpl-3.0.html")!)
                    Link("Quellcode", destination: Self.repository)
                    Spacer()
                    if let licenses = Bundle.main.resourceURL?.appendingPathComponent("Licenses"),
                       FileManager.default.fileExists(atPath: licenses.path) {
                        Button("Lizenzen der Komponenten …") { NSWorkspace.shared.open(licenses) }
                    }
                }
                Text("Enthält u. a. archive-pdf-tools (Internet Archive), PyMuPDF, Tesseract, OpenJPEG, jbig2enc, Poppler und Sparkle, jeweils unter ihren eigenen Lizenzen.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { mode = UpdateMode.current }
    }
}

extension Updates {
    static var automaticChecks: Bool {
        get {
            #if SPARKLE
            return controller.updater.automaticallyChecksForUpdates
            #else
            return false
            #endif
        }
        set {
            #if SPARKLE
            controller.updater.automaticallyChecksForUpdates = newValue
            #endif
        }
    }

    static var automaticInstall: Bool {
        get {
            #if SPARKLE
            return controller.updater.automaticallyDownloadsUpdates
            #else
            return false
            #endif
        }
        set {
            #if SPARKLE
            controller.updater.automaticallyDownloadsUpdates = newValue
            #endif
        }
    }
}
