// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

/// Kennzahlen aus der maschinenlesbaren Ergebniszeile von paperless-mrc.
struct MRCResult {
    var compressed = false
    var sizeBefore: Int?
    var sizeAfter: Int?
    var pages: Int?

    init(_ json: [String: Any]?) {
        guard let json else { return }
        func n(_ key: String) -> Int? { (json[key] as? NSNumber)?.intValue }
        compressed = json["status"] as? String == "compressed"
        sizeBefore = n("size_before")
        sizeAfter = n("size_after")
        pages = n("pages")
    }
}

struct Conversion {
    let message: String  // Ergebniszeile von paperless-mrc
    let log: String      // alle Meldungen von paperless-mrc
    let output: URL?     // nil: keine Datei erzeugt (nicht verkleinerbar, Fehler, übersprungen)
    var result = MRCResult(nil)
}

enum ConversionError: LocalizedError {
    case emptySuffix
    case toolMissing(String)

    var errorDescription: String? {
        switch self {
        case .emptySuffix:
            return L("The file name suffix must not be empty.")
        case .toolMissing(let path):
            return L("paperless-mrc not found (%@). Please reinstall the app.", path)
        }
    }
}

/// Ruft paperless-mrc auf einer Kopie der PDF auf (Schnittstelle wie in Paperless: DOCUMENT_WORKING_PATH).
/// paperless-mrc ersetzt die Kopie nur, wenn das Ergebnis geprüft und kleiner ist.
enum Converter {
    /// So wird paperless-mrc gestartet.
    struct Runtime {
        let executable: URL
        let arguments: [String]
        let path: [String]
        let environment: [String: String]
    }

    /// Eigenständige App: Python, paperless-mrc und Werkzeuge liegen im App-Paket (build_app.sh --standalone).
    /// Sonst Homebrew-Installation (install.sh): paperless-mrc laut Info.plist, Werkzeuge aus Homebrew.
    static var runtime: Runtime? {
        let fm = FileManager.default
        let contents = Bundle.main.bundleURL.appendingPathComponent("Contents")
        let resources = contents.appendingPathComponent("Resources")
        let python = resources.appendingPathComponent("python/bin/python3")
        if fm.isExecutableFile(atPath: python.path) {
            return Runtime(executable: python, arguments: ["-m", "paperless_mrc.main"],
                           path: [python.deletingLastPathComponent().path, contents.appendingPathComponent("Helpers").path,
                                  "/usr/bin", "/bin", "/usr/sbin", "/sbin"],
                           environment: ["TESSDATA_PREFIX": Languages.directory.path,
                                         "FONTCONFIG_FILE": resources.appendingPathComponent("fonts/fonts.conf").path,
                                         // das App-Paket bleibt unverändert (Signatur), keine fremden Pakete
                                         "PYTHONDONTWRITEBYTECODE": "1", "PYTHONNOUSERSITE": "1",
                                         "PYMUPDF_SUGGEST_LAYOUT_ANALYZER": "0"])
        }
        let tool = homebrewTool
        guard fm.isExecutableFile(atPath: tool.path) else { return nil }
        return Runtime(executable: tool, arguments: [],
                       path: [tool.deletingLastPathComponent().path, "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin",
                              "/bin"],
                       environment: [:])
    }

    private static var homebrewTool: URL {
        if let path = Bundle.main.object(forInfoDictionaryKey: "MRCPaperlessPath") as? String {
            return URL(fileURLWithPath: path)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/paperless-mrc")
    }

    /// Komprimierte Arbeitskopie in einem temporären Ordner (vom Aufrufer zu löschen).
    struct CompressedCopy {
        let directory: URL
        let file: URL      // unter dem Originalnamen; unverändert, wenn changed == false
        let message: String
        let log: String
        let changed: Bool
        let result: MRCResult
    }

    static func compressCopy(_ src: URL, with profile: Profile) throws -> CompressedCopy {
        let fm = FileManager.default
        guard let runtime else { throw ConversionError.toolMissing(homebrewTool.path) }
        if Languages.isManaged {
            try Languages.prepare()
            let missing = Languages.missing(profile.languages)
            guard missing.isEmpty else { throw LanguageError.missing(missing) }
        }

        // Arbeitskopie auf demselben Laufwerk, unter dem Originalnamen (für die Meldungen)
        let workDir = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: src,
                                 create: true)
        do {
            let work = workDir.appendingPathComponent(src.lastPathComponent)
            try fm.copyItem(at: src, to: work)

            let prefix = "paperless-mrc: "
            let resultPrefix = "paperless-mrc-result: "
            let output = try run(runtime, on: work, with: profile).split(separator: "\n").map(String.init)
            let lines = output.filter { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
            // Ergebnis aus der maschinenlesbaren Zeile (übersetzbar); ältere paperless-mrc: letzte Meldung
            var message: String
            let json = output.last(where: { $0.hasPrefix(resultPrefix) }).flatMap {
                try? JSONSerialization.jsonObject(with: Data($0.dropFirst(resultPrefix.count).utf8)) as? [String: Any]
            }
            if let json {
                message = describeResult(json)
            } else {
                message = lines.last ?? L("No response from paperless-mrc")
                if message.hasPrefix(src.lastPathComponent + ": ") {
                    message.removeFirst(src.lastPathComponent.count + 2)
                }
            }
            return CompressedCopy(directory: workDir, file: work, message: message,
                                  log: lines.joined(separator: "\n"),
                                  changed: !fm.contentsEqual(atPath: src.path, andPath: work.path),
                                  result: MRCResult(json))
        } catch {
            try? fm.removeItem(at: workDir)
            throw error
        }
    }

    static func convert(_ src: URL, with profile: Profile) throws -> Conversion {
        let fm = FileManager.default
        var dest = src
        if profile.output == .copy {
            guard !profile.suffix.isEmpty else { throw ConversionError.emptySuffix }
            dest = src.deletingLastPathComponent()
                .appendingPathComponent(src.deletingPathExtension().lastPathComponent + profile.suffix + ".pdf")
            if fm.fileExists(atPath: dest.path) {
                return Conversion(message: L("%@ already exists – skipped", dest.lastPathComponent), log: "",
                                  output: nil)
            }
        }
        let copy = try compressCopy(src, with: profile)
        defer { try? fm.removeItem(at: copy.directory) }
        let work = copy.file
        let message = copy.message
        let log = copy.log

        if !copy.changed {
            return Conversion(message: message, log: log, output: nil, result: copy.result)
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
        return Conversion(message: message, log: log, output: dest, result: copy.result)
    }

    private static func run(_ runtime: Runtime, on work: URL, with profile: Profile) throws -> String {
        let process = Process()
        process.executableURL = runtime.executable
        process.arguments = runtime.arguments
        var env = ProcessInfo.processInfo.environment
        env["PYTHONPATH"] = nil
        env["PYTHONHOME"] = nil
        env.merge(runtime.environment) { $1 }
        env.merge(profile.environment) { $1 }
        env["DOCUMENT_WORKING_PATH"] = work.path
        // Protokoll in der Sprache der App, mit Zeiten je Schritt (für den Verlauf)
        env["MRC_LANGUAGE"] = Bundle.main.preferredLocalizations.first == "de" ? "de" : "en"
        env["MRC_TIMING"] = "true"
        env["PATH"] = runtime.path.joined(separator: ":")
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
