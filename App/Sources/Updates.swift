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
                        Text(L("Version %@ (build %@)", Self.info("CFBundleShortVersionString"), Self.info("CFBundleVersion")))
                        Text(L("with paperless-mrc %@", Self.info("MRCPaperlessVersion")))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }

            Section("Updates") {
                if Updates.available {
                    Picker("Updates", selection: $mode) {
                        Text("Install automatically").tag(UpdateMode.automatic)
                        Text("Check automatically, ask before installing").tag(UpdateMode.ask)
                        Text("Manually only").tag(UpdateMode.manual)
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()
                    .help("Install automatically: new versions are downloaded in the background and installed when you quit the app. Ask: the app shows new versions and asks before installing. Manually only: no automatic checks; use “Check for updates now”.")
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
                    Text("The app checks when it opens and every four hours while it is open. Quick Actions in the Finder do not check. Automatically downloaded updates are installed when you quit the app.")
                        .font(.footnote).foregroundStyle(.secondary)
                } else {
                    Text("This installation was built with the Homebrew installer and is updated by running install.sh again.")
                        .foregroundStyle(.secondary)
                }
            }

            Section("License") {
                Text("PDF MRC is free software under the GNU Affero General Public License, version 3 or later (AGPL-3.0-or-later). It comes without any warranty.")
                HStack {
                    Link("License text", destination: URL(string: "https://www.gnu.org/licenses/agpl-3.0.html")!)
                    Link("Source code", destination: Self.repository)
                    Spacer()
                    if let licenses = Bundle.main.resourceURL?.appendingPathComponent("Licenses"),
                       FileManager.default.fileExists(atPath: licenses.path) {
                        Button("Component licenses…") { NSWorkspace.shared.open(licenses) }
                            .help("Opens the folder with the license texts of the bundled components (Tesseract, Poppler, Sparkle and others).")
                    }
                }
                Text("Includes archive-pdf-tools (Internet Archive), PyMuPDF, Tesseract, OpenJPEG, jbig2enc, Poppler and Sparkle, among others, each under its own license.")
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
