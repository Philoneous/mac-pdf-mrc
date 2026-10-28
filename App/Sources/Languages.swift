// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

/// Tesseract-Sprachdaten der eigenständigen App. Mitgeliefert sind Deutsch und Englisch (plus Ausrichtung „osd“);
/// weitere Sprachen werden aus tessdata_fast (github.com/tesseract-ocr) nachgeladen. Alles liegt in
/// ~/Library/Application Support/mac-pdf-mrc/tessdata (TESSDATA_PREFIX); mitgelieferte Dateien sind dort nur verlinkt,
/// damit das App-Paket unverändert bleibt und Updates die Links erneuern.
enum Languages {
    static let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/mac-pdf-mrc/tessdata")

    private static var bundled: URL? {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("tessdata"),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    /// Nur die eigenständige App verwaltet Sprachen; die Homebrew-Variante nutzt Homebrews tessdata.
    static var isManaged: Bool { bundled != nil }

    /// Links auf die mitgelieferten Dateien anlegen bzw. erneuern (heruntergeladene Dateien bleiben).
    static func prepare() throws {
        guard let bundled else { return }
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        for name in try fm.contentsOfDirectory(atPath: bundled.path) {
            let link = directory.appendingPathComponent(name)
            if (try? fm.destinationOfSymbolicLink(atPath: link.path)) != nil {
                try fm.removeItem(at: link)
            } else if fm.fileExists(atPath: link.path) {
                continue
            }
            try fm.createSymbolicLink(at: link, withDestinationURL: bundled.appendingPathComponent(name))
        }
    }

    static func codes(_ spec: String) -> [String] {
        spec.split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    static func isInstalled(_ code: String) -> Bool {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent("\(code).traineddata").path)
            || (bundled.map { FileManager.default.fileExists(atPath: $0.appendingPathComponent("\(code).traineddata").path) } ?? false)
    }

    static func missing(_ spec: String) -> [String] {
        guard isManaged else { return [] }
        return codes(spec).filter { !isInstalled($0) }
    }

    static var installed: [String] {
        guard isManaged else { return [] }
        try? prepare()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { $0.hasSuffix(".traineddata") }.map { String($0.dropLast(".traineddata".count)) }
            .filter { $0 != "osd" }.sorted()
    }

    /// Lädt eine Sprache aus tessdata_fast (dieselbe Variante wie die mitgelieferten und wie Debian/Ubuntu).
    static func download(_ code: String) async throws {
        guard code.range(of: #"^[a-z]{3}(_[a-z]+)*$"#, options: .regularExpression) != nil,
              let url = URL(string: "https://github.com/tesseract-ocr/tessdata_fast/raw/main/\(code).traineddata")
        else { throw LanguageError.invalidCode(code) }
        try prepare()
        let (file, response) = try await URLSession.shared.download(from: url)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
        guard status == 200, size > 100_000 else {
            try? FileManager.default.removeItem(at: file)
            throw LanguageError.notFound(code, status)
        }
        let target = directory.appendingPathComponent("\(code).traineddata")
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.moveItem(at: file, to: target)
    }
}

enum LanguageError: LocalizedError {
    case invalidCode(String)
    case notFound(String, Int)
    case missing([String])

    var errorDescription: String? {
        switch self {
        case .invalidCode(let code):
            return L("Invalid language code “%@” (e.g. fra, pol, chi_sim).", code)
        case .notFound(let code, let status):
            return L("Language “%@” not found (HTTP %lld).", code, status)
        case .missing(let codes):
            return L("Language(s) not installed: %@ – download them in the app under “Text recognition”.",
                     codes.joined(separator: ", "))
        }
    }
}
