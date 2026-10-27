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
            try localizeMenuTitle()
        }
        // Dienste-Menü neu einlesen
        let pbs = Process()
        pbs.executableURL = URL(fileURLWithPath: "/System/Library/CoreServices/pbs")
        pbs.arguments = ["-flush"]
        try? pbs.run()
    }

    /// Menütitel in der Systemsprache (der Dateiname bleibt als Kennung deutsch).
    private func localizeMenuTitle() throws {
        let plistURL = installedURL.appendingPathComponent("Contents/Info.plist")
        let data = try Data(contentsOf: plistURL)
        guard var plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              var services = plist["NSServices"] as? [[String: Any]], !services.isEmpty else { return }
        services[0]["NSMenuItem"] = ["default": L(name)]
        plist["NSServices"] = services
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: plistURL)
    }
}
