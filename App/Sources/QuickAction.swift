// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

/// Finder-Schnellaktion ein-/ausschalten: Workflow aus der App nach ~/Library/Services kopieren bzw. löschen.
/// Die Vorlage legt der Installer in Contents/Resources ab.
enum QuickAction {
    static let fileName = "PDF komprimieren (MRC).workflow"

    static var installedURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Services/\(fileName)")
    }

    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: installedURL.path)
    }

    static func setInstalled(_ on: Bool) throws {
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
