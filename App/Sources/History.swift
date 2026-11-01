// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

/// Ein Eintrag im Verlauf: was mit welcher Datei geschah, mit Zeiten und dem Protokoll von paperless-mrc.
struct HistoryEntry: Codable, Identifiable, Equatable {
    enum Status: String, Codable {
        case done       // komprimiert bzw. in Paperless angelegt
        case unchanged  // nichts zu tun (nicht verkleinerbar, Duplikat, übersprungen)
        case failed
        case pending    // in Paperless noch in Verarbeitung (Wartezeit abgelaufen)
    }

    struct Timing: Codable, Equatable {
        let step: String  // compress, upload, paperless
        let seconds: Double
    }

    var id = UUID()
    var date = Date()
    var kind: JobKind
    var source: String
    var output: String?
    var status: Status = .done
    var message = ""
    var sizeBefore: Int?
    var sizeAfter: Int?
    var pages: Int?
    var paperlessDocument: Int?
    var paperlessURL: String?  // Adresse des Servers, für „In Paperless öffnen“
    var timings: [Timing] = []
    var log = ""

    init(kind: JobKind, source: String, status: Status = .done) {
        self.kind = kind
        self.source = source
        self.status = status
    }

    /// Fehlende Schlüssel (andere Version) erhalten den Standardwert, statt den ganzen Verlauf zu verwerfen.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(JobKind.self, forKey: .kind)
        source = try c.decode(String.self, forKey: .source)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        date = try c.decodeIfPresent(Date.self, forKey: .date) ?? Date()
        output = try c.decodeIfPresent(String.self, forKey: .output)
        status = (try? c.decodeIfPresent(Status.self, forKey: .status)) ?? .done
        message = try c.decodeIfPresent(String.self, forKey: .message) ?? ""
        sizeBefore = try c.decodeIfPresent(Int.self, forKey: .sizeBefore)
        sizeAfter = try c.decodeIfPresent(Int.self, forKey: .sizeAfter)
        pages = try c.decodeIfPresent(Int.self, forKey: .pages)
        paperlessDocument = try c.decodeIfPresent(Int.self, forKey: .paperlessDocument)
        paperlessURL = try c.decodeIfPresent(String.self, forKey: .paperlessURL)
        timings = try c.decodeIfPresent([Timing].self, forKey: .timings) ?? []
        log = try c.decodeIfPresent(String.self, forKey: .log) ?? ""
    }

    var fileName: String { URL(fileURLWithPath: source).lastPathComponent }

    var paperlessLink: URL? {
        guard let id = paperlessDocument, let base = paperlessURL else { return nil }
        return URL(string: base + "/documents/\(id)/details")
    }
}

/// Verlauf der letzten Aufträge in ~/Library/Application Support/mac-pdf-mrc/history.json. App und Kontextmenü-Aufrufe
/// schreiben gleichzeitig, daher mit Dateisperre; Änderungen werden per Distributed Notification gemeldet.
enum History {
    static let limit = 50
    static let changed = Notification.Name("io.github.philoneous.mac-pdf-mrc.history")

    private static let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/mac-pdf-mrc")
    static let url = directory.appendingPathComponent("history.json")

    /// Ein Eintrag, der sich nicht lesen lässt, wird übersprungen statt den ganzen Verlauf zu verwerfen.
    private struct Lossy: Decodable {
        let entry: HistoryEntry?
        init(from decoder: Decoder) throws { entry = try? HistoryEntry(from: decoder) }
    }

    static func load() -> [HistoryEntry] {
        (try? read()) ?? []
    }

    /// nil: keine Datei; wirft, wenn die Datei kein lesbarer Verlauf ist.
    private static func read() throws -> [HistoryEntry]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([Lossy].self, from: data).compactMap(\.entry)
    }

    static func append(_ entry: HistoryEntry) {
        modify { $0.insert(entry, at: 0) }
    }

    static func clear() {
        modify { $0.removeAll() }
    }

    private static func modify(_ change: (inout [HistoryEntry]) -> Void) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let lock = open(directory.appendingPathComponent(".history.lock").path, O_CREAT | O_RDWR, 0o644)
        if lock >= 0 { flock(lock, LOCK_EX) }
        defer {
            if lock >= 0 {
                flock(lock, LOCK_UN)
                close(lock)
            }
        }
        var entries: [HistoryEntry]
        do {
            entries = try read() ?? []
        } catch {  // unlesbare Datei beiseitelegen statt sie zu überschreiben
            let aside = url.deletingPathExtension().appendingPathExtension("broken-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: url, to: aside)
            entries = []
        }
        change(&entries)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(Array(entries.prefix(limit))) {
            try? data.write(to: url, options: .atomic)
        }
        DistributedNotificationCenter.default().postNotificationName(changed, object: nil, userInfo: nil,
                                                                     deliverImmediately: true)
    }
}
