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

    static func checkNow() {
        #if SPARKLE
        controller.updater.checkForUpdates()
        #endif
    }
}

/// Einstellungsfenster (⌘,): Updates und Versionen.
struct SettingsView: View {
    @State private var automaticChecks = Updates.automaticChecks
    @State private var automaticInstall = Updates.automaticInstall

    private var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        return "\(info["CFBundleShortVersionString"] as? String ?? "?") (\(info["CFBundleVersion"] as? String ?? "?"))"
    }

    var body: some View {
        Form {
            if Updates.available {
                Section("Updates") {
                    Toggle("Automatisch nach Updates suchen", isOn: $automaticChecks)
                        .onChange(of: automaticChecks) { on in Updates.automaticChecks = on }
                    Toggle("Updates automatisch installieren", isOn: $automaticInstall)
                        .onChange(of: automaticInstall) { on in Updates.automaticInstall = on }
                        .disabled(!automaticChecks)
                    Button("Jetzt nach Updates suchen") { Updates.checkNow() }
                }
            } else {
                Text("Diese Installation wird über den Homebrew-Installer aktualisiert (install.sh erneut ausführen).")
                    .foregroundStyle(.secondary)
            }
            Section("Version") {
                LabeledContent("PDF MRC", value: version)
                LabeledContent("paperless-mrc",
                               value: Bundle.main.object(forInfoDictionaryKey: "MRCPaperlessVersion") as? String ?? "?")
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
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
