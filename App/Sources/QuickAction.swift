// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

/// Finder-Schnellaktion ein-/ausschalten: Workflow aus der App nach ~/Library/Services kopieren bzw. löschen.
/// Die Vorlagen legt der Installer in Contents/Resources ab.
struct QuickAction {
    let name: String

    static let compress = QuickAction(name: "PDF komprimieren (MRC)")
    static let send = QuickAction(name: "An Paperless senden")
    static let compressAndSend = QuickAction(name: "Komprimieren und an Paperless senden")

    private var fileName: String { "\(name).workflow" }

    private var installedURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Services/\(fileName)")
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
        }
        // Dienste-Menü neu einlesen
        let pbs = Process()
        pbs.executableURL = URL(fileURLWithPath: "/System/Library/CoreServices/pbs")
        pbs.arguments = ["-flush"]
        try? pbs.run()
    }
}
