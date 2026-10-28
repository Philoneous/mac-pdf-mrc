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

    static func load() -> [HistoryEntry] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([HistoryEntry].self, from: data)) ?? []
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
        var entries = load()
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
