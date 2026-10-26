// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

struct Conversion {
    let message: String  // Ergebniszeile von paperless-mrc
    let log: String      // alle Meldungen von paperless-mrc
    let output: URL?     // nil: keine Datei erzeugt (nicht verkleinerbar, Fehler, übersprungen)
}

enum ConversionError: LocalizedError {
    case emptySuffix
    case toolMissing(String)

    var errorDescription: String? {
        switch self {
        case .emptySuffix:
            return "Der Namenszusatz darf nicht leer sein."
        case .toolMissing(let path):
            return "paperless-mrc nicht gefunden (\(path)). Bitte den Installer erneut ausführen."
        }
    }
}

/// Ruft paperless-mrc auf einer Kopie der PDF auf (Schnittstelle wie in Paperless: DOCUMENT_WORKING_PATH).
/// paperless-mrc ersetzt die Kopie nur, wenn das Ergebnis geprüft und kleiner ist.
enum Converter {
    static var tool: URL {
        if let path = Bundle.main.object(forInfoDictionaryKey: "MRCPaperlessPath") as? String {
            return URL(fileURLWithPath: path)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/paperless-mrc")
    }

    static func convert(_ src: URL, with profile: Profile) throws -> Conversion {
        let fm = FileManager.default
        var dest = src
        if profile.output == .copy {
            guard !profile.suffix.isEmpty else { throw ConversionError.emptySuffix }
            dest = src.deletingLastPathComponent()
                .appendingPathComponent(src.deletingPathExtension().lastPathComponent + profile.suffix + ".pdf")
            if fm.fileExists(atPath: dest.path) {
                return Conversion(message: "\(dest.lastPathComponent) existiert bereits – übersprungen", log: "",
                                  output: nil)
            }
        }
        guard fm.isExecutableFile(atPath: tool.path) else { throw ConversionError.toolMissing(tool.path) }

        // Arbeitskopie auf demselben Laufwerk, unter dem Originalnamen (für die Meldungen)
        let workDir = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: src,
                                 create: true)
        defer { try? fm.removeItem(at: workDir) }
        let work = workDir.appendingPathComponent(src.lastPathComponent)
        try fm.copyItem(at: src, to: work)

        let prefix = "paperless-mrc: "
        let lines = try run(on: work, with: profile)
            .split(separator: "\n").map(String.init)
            .filter { $0.hasPrefix(prefix) }
            .map { String($0.dropFirst(prefix.count)) }
        var message = lines.last ?? "Keine Rückmeldung von paperless-mrc"
        if message.hasPrefix(src.lastPathComponent + ": ") {
            message.removeFirst(src.lastPathComponent.count + 2)
        }
        let log = lines.joined(separator: "\n")

        if fm.contentsEqual(atPath: src.path, andPath: work.path) {
            return Conversion(message: message, log: log, output: nil)
        }
        if profile.output == .replace {
            // Ergebnis erst neben das Original legen; schlägt der Papierkorb fehl, bleibt das Original
            let staged = src.deletingLastPathComponent().appendingPathComponent(".\(src.lastPathComponent).mrc-neu")
            try fm.moveItem(at: work, to: staged)
            do {
                try fm.trashItem(at: src, resultingItemURL: nil)
            } catch {
                try? fm.removeItem(at: staged)
                throw error
            }
            try fm.moveItem(at: staged, to: src)
        } else {
            try fm.moveItem(at: work, to: dest)
        }
        return Conversion(message: message, log: log, output: dest)
    }

    private static func run(on work: URL, with profile: Profile) throws -> String {
        let process = Process()
        process.executableURL = tool
        var env = ProcessInfo.processInfo.environment
        env.merge(profile.environment) { $1 }
        env["DOCUMENT_WORKING_PATH"] = work.path
        env["PATH"] = [tool.deletingLastPathComponent().path, "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin",
                       "/bin"].joined(separator: ":")
        process.environment = env
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
