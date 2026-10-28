// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

/// Finder-Schnellaktion ein-/ausschalten: Workflow aus der App nach ~/Library/Services kopieren bzw. löschen.
/// Die Vorlagen legt der Installer in Contents/Resources ab.
struct QuickAction {
    /// Englischer Name = Dateiname des Workflows; der Menütitel wird beim Einrichten in die Systemsprache übersetzt.
    let name: String
    /// Dateiname bis Version 1.0.1 (deutsch); wird beim Start durch den neuen ersetzt.
    let legacyName: String

    static let compress = QuickAction(name: "Compress PDF (MRC)", legacyName: "PDF komprimieren (MRC)")
    static let send = QuickAction(name: "Send to Paperless", legacyName: "An Paperless senden")
    static let compressAndSend = QuickAction(name: "Compress and Send to Paperless",
                                             legacyName: "Komprimieren und an Paperless senden")
    static let all = [compress, send, compressAndSend]

    /// Beim Start der App (und vom Installer): eingeschaltete Schnellaktionen neu schreiben – aktueller Pfad der App,
    /// Menütitel in der Systemsprache. Beim allerersten Start wird „PDF komprimieren“ eingeschaltet.
    static func setUp() {
        let defaults = UserDefaults.standard
        let firstRun = !defaults.bool(forKey: "quickActionsSetUp")
        for action in all {
            let legacy = action.migrateLegacy()
            if legacy || action.isInstalled || (firstRun && action.name == compress.name) {
                try? action.setInstalled(true)
            }
        }
        defaults.set(true, forKey: "quickActionsSetUp")
    }

    private var fileName: String { "\(name).workflow" }

    private static let services = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Services")

    private var installedURL: URL { Self.services.appendingPathComponent(fileName) }

    /// Entfernt den Workflow mit dem alten deutschen Dateinamen; true, wenn er eingeschaltet war.
    private func migrateLegacy() -> Bool {
        let legacy = Self.services.appendingPathComponent("\(legacyName).workflow")
        guard FileManager.default.fileExists(atPath: legacy.path) else { return false }
        try? FileManager.default.removeItem(at: legacy)
        return true
    }

    var isInstalled: Bool {
        FileManager.default.fileExists(atPath: installedURL.path)
    }

    func setInstalled(_ on: Bool) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: installedURL.path) {
            try fm.removeItem(at: installedURL)
        }
        if on {
            guard let template = Bundle.main.resourceURL?.appendingPathComponent(fileName),
                  fm.fileExists(atPath: template.path) else {
                throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: fileName])
            }
            try fm.createDirectory(at: installedURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: template, to: installedURL)
            try customize()
        }
        // Dienste-Menü neu einlesen
        let pbs = Process()
        pbs.executableURL = URL(fileURLWithPath: "/System/Library/CoreServices/pbs")
        pbs.arguments = ["-flush"]
        try? pbs.run()
    }

    /// Trägt den Pfad dieser App in den Workflow ein (Platzhalter aus build_app.sh) und setzt den Menütitel in der
    /// Systemsprache (der Dateiname bleibt als Kennung englisch).
    private func customize() throws {
        let workflowURL = installedURL.appendingPathComponent("Contents/document.wflow")
        let executable = (Bundle.main.executablePath ?? "")
            .replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        let workflow = try String(contentsOf: workflowURL, encoding: .utf8)
        try workflow.replacingOccurrences(of: "__APP_EXECUTABLE__", with: executable)
            .write(to: workflowURL, atomically: true, encoding: .utf8)

        let plistURL = installedURL.appendingPathComponent("Contents/Info.plist")
        let data = try Data(contentsOf: plistURL)
        guard var plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              var services = plist["NSServices"] as? [[String: Any]], !services.isEmpty else { return }
        services[0]["NSMenuItem"] = ["default": L(name)]
        plist["NSServices"] = services
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: plistURL)
    }
}
