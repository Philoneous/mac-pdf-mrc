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

/// Sprache der Oberfläche (und der Protokolle von paperless-mrc). macOS lädt sie beim Start der App
/// (AppleLanguages in den Einstellungen der App); ein Wechsel braucht daher einen Neustart.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system, en, de
    var id: String { rawValue }

    static var current: AppLanguage {
        get {
            let domain = UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")
            switch (domain?["AppleLanguages"] as? [String])?.first?.prefix(2) {
            case "de": return .de
            case "en": return .en
            default: return .system
            }
        }
        set {
            if newValue == .system {
                UserDefaults.standard.removeObject(forKey: "AppleLanguages")
            } else {
                UserDefaults.standard.set([newValue.rawValue], forKey: "AppleLanguages")
            }
        }
    }

    /// Sprache, mit der die App gerade läuft.
    static var active: String { Bundle.main.preferredLocalizations.first ?? "en" }

    /// App neu starten (neue Instanz nach dem Beenden öffnen).
    @MainActor
    static func relaunch() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", Bundle.main.bundlePath]
        try? process.run()
        NSApp.terminate(nil)
    }
}

/// Bereich „Settings“ (und Einstellungsfenster ⌘,): Sprache, Updates.
struct SettingsPane: View {
    @State private var mode = UpdateMode.current
    @State private var language = AppLanguage.current
    @ObservedObject private var jobs = JobCenter.shared
    static let repository = URL(string: "https://github.com/Philoneous/mac-pdf-mrc")!

    /// Gewählte Sprache weicht von der laufenden ab → Neustart anbieten.
    private var needsRestart: Bool {
        // Systemsprachen aus der globalen Domäne (Locale.preferredLanguages enthält bereits die Wahl der App)
        let system = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?["AppleLanguages"]
            as? [String] ?? ["en"]
        let wanted = language == .system
            ? (Bundle.preferredLocalizations(from: Bundle.main.localizations, forPreferences: system).first ?? "en")
            : language.rawValue
        return wanted != AppLanguage.active
    }

    var body: some View {
        Form {
            Section("Language") {
                Picker(selection: $language) {
                    Text("System language").tag(AppLanguage.system)
                    Text(verbatim: "English").tag(AppLanguage.en)
                    Text(verbatim: "Deutsch").tag(AppLanguage.de)
                } label: { TipLabel("Language", tip: "Language of the app, of the Quick Action names in the Finder and of the paperless-mrc log. System language: German if your Mac uses German, otherwise English.") }
                .onChange(of: language) { AppLanguage.current = $0 }
                if needsRestart {
                    HStack {
                        Text("The new language is used after a restart.").foregroundStyle(.secondary)
                        Spacer()
                        Button("Restart Now") { AppLanguage.relaunch() }
                            .disabled(jobs.isBusy)
                            .help("Quits PDF MRC and opens it again. Not possible while conversions are running.")
                    }
                }
            }

            Section("Updates") {
                if Updates.available {
                    Picker(selection: $mode) {
                        Text("Install automatically").tag(UpdateMode.automatic)
                        Text("Check automatically, ask before installing").tag(UpdateMode.ask)
                        Text("Manually only").tag(UpdateMode.manual)
                    } label: { TipLabel("Installation", tip: "Install automatically: new versions are downloaded in the background and installed when you quit the app. Ask: the app shows new versions and asks before installing. Manually only: no automatic checks; use “Check for updates now”.") }
                    .pickerStyle(.radioGroup)
                    .onChange(of: mode) { UpdateMode.current = $0 }
                    TimelineView(.periodic(from: .now, by: 10)) { _ in
                        LabeledContent("Last checked", value: Updates.lastCheck.map {
                            $0.formatted(date: .abbreviated, time: .shortened)
                        } ?? L("never"))
                    }
                    HStack {
                        Button("Check for updates now") { Updates.checkNow() }
                            .help("Checks right away whether a new version is available.")
                        Spacer()
                        Link("Release notes", destination: Self.repository.appendingPathComponent("releases"))
                    }
                    Text("The app checks when it starts – also when a Quick Action starts it in the background – and every four hours while it is running. Automatically downloaded updates are installed when the app quits.")
                        .font(.footnote).foregroundStyle(.secondary)
                } else {
                    Text("This installation was built with the Homebrew installer and is updated by running install.sh again.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            mode = UpdateMode.current
            language = AppLanguage.current
        }
    }
}

/// Bereich „About“: Version, Unterstützen (Ko-fi), Lizenz.
struct AboutView: View {
    static let kofi = URL(string: "https://ko-fi.com/Philoneous")!

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
                        Text(L("Version %@ (build %@)", Self.info("CFBundleShortVersionString"), Self.info("CFBundleVersion")))
                        Text(L("with paperless-mrc %@", Self.info("MRCPaperlessVersion")))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }

            Section("Support") {
                HStack(alignment: .center, spacing: 12) {
                    Text("PDF MRC is free. If it saves you time or storage, you can support its development with a small contribution.")
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Link(destination: Self.kofi) {
                        Label("Support on Ko-fi", systemImage: "cup.and.saucer.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .help("Opens ko-fi.com/Philoneous in your browser. Payment by PayPal or card, no account needed. Contributions are voluntary and not tax-deductible donations.")
                }
            }

            Section("License") {
                Text(verbatim: "Copyright © 2026 Philoneous")
                Text("PDF MRC is free software under the GNU Affero General Public License, version 3 or later (AGPL-3.0-or-later). It comes without any warranty.")
                HStack {
                    Link("License text", destination: URL(string: "https://www.gnu.org/licenses/agpl-3.0.html")!)
                    Link("Source code", destination: SettingsPane.repository)
                    Spacer()
                    if let licenses = Bundle.main.resourceURL?.appendingPathComponent("Licenses"),
                       FileManager.default.fileExists(atPath: licenses.path) {
                        Button("Third-party notices…") {
                            NSWorkspace.shared.open(licenses.appendingPathComponent("THIRD-PARTY-NOTICES.txt"))
                        }
                        .help("Lists every bundled component with its version, license and where to get the source code.")
                        Button("License texts…") { NSWorkspace.shared.open(licenses) }
                            .help("Opens the folder with the full license texts of the bundled components.")
                    }
                }
                Text("Includes archive-pdf-tools and archive-hocr-tools (Internet Archive), PyMuPDF and MuPDF (Artifex), pikepdf, Tesseract, Python and Sparkle, among others, each under its own license.")
                    .font(.footnote).foregroundStyle(.secondary)
                Text("PDF MRC is an independent project and is not affiliated with or endorsed by Paperless-ngx or the Internet Archive.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
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
