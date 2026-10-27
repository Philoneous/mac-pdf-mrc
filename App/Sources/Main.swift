// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

/// Startpunkt. Aufrufe aus den Finder-Schnellaktionen laufen ohne Oberfläche:
///   --kontextmenue <PDFs…>          komprimieren (Kontextmenü-Profil)
///   --paperless <PDFs…>             Original an Paperless senden
///   --paperless-komprimiert <PDFs…> komprimieren (Kontextmenü-Profil) und an Paperless senden
///   --paperless-token               API-Token von der Standardeingabe in den Schlüsselbund (für Skripte)
///   --schnellaktionen-einrichten    Schnellaktionen einrichten/aktualisieren (wie beim Start der App)
///   --sprachen-laden <Kürzel…>      Tesseract-Sprachen nachladen (eigenständige App), z. B. fra pol
/// Ohne diese Argumente startet die App.
@main
enum Main {
    @MainActor
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        let files = Array(args.dropFirst())
        switch args.first {
        case "--kontextmenue": ContextMenuRun.run(files)
        case "--paperless": PaperlessRun.run(files, compress: false)
        case "--paperless-komprimiert": PaperlessRun.run(files, compress: true)
        case "--schnellaktionen-einrichten": QuickAction.setUp()
        case "--sprachen-laden":
            for code in files {
                do {
                    try PaperlessRun.blocking { try await Languages.download(code) }
                    print(L("Sprache „%@“ installiert", code))
                } catch {
                    FileHandle.standardError.write(Data((L("Fehler: %@", error.localizedDescription) + "\n").utf8))
                    exit(1)
                }
            }
        case "--paperless-token":
            do {
                try PaperlessToken.save(readLine(strippingNewline: true) ?? "")
            } catch {
                FileHandle.standardError.write(Data((L("Fehler: %@", error.localizedDescription) + "\n").utf8))
                exit(1)
            }
        default: PDFMRCApp.main()
        }
    }
}

enum ContextMenuRun {
    /// Wandelt alle PDFs mit dem Kontextmenü-Profil um und meldet jedes Ergebnis als Mitteilung.
    static func run(_ paths: [String]) {
        let profile = AppSettings.load().quickAction
        for path in paths {
            let src = URL(fileURLWithPath: path)
            let text: String
            do {
                text = try Converter.convert(src, with: profile).message
            } catch {
                text = L("Fehler: %@", error.localizedDescription)
            }
            report(src, text)
        }
    }

    /// Ergebnis ausgeben und als Mitteilung anzeigen.
    static func report(_ src: URL, _ text: String) {
        print("\(src.lastPathComponent): \(text)")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", "on run argv",
                             "-e", "display notification (item 2 of argv) with title (item 1 of argv)",
                             "-e", "end run", src.lastPathComponent, text]
        do {
            try process.run()
            process.waitUntilExit()
        } catch {}  // Mitteilung ist nur Komfort
    }
}

enum PaperlessRun {
    static let waitLimit: TimeInterval = 180  // so lange auf das Ergebnis von Paperless warten

    /// Lädt alle PDFs hoch (optional vorher komprimiert, die Datei auf dem Mac bleibt unverändert) und meldet,
    /// was Paperless daraus gemacht hat.
    static func run(_ paths: [String], compress: Bool) {
        let settings = AppSettings.load()
        let client: PaperlessClient
        do {
            client = try PaperlessClient.configured(settings)
            // Verbindung und Token vorab prüfen: klare Meldung statt abgebrochenem Upload, keine Daten umsonst
            try blocking { try await client.check() }
        } catch {
            paths.forEach { ContextMenuRun.report(URL(fileURLWithPath: $0), L("Fehler: %@", error.localizedDescription)) }
            return
        }

        // 1. hochladen
        var pending: [(src: URL, task: String, note: String)] = []
        for path in paths {
            let src = URL(fileURLWithPath: path)
            var copy: Converter.CompressedCopy?
            defer {
                if let copy { try? FileManager.default.removeItem(at: copy.directory) }
            }
            do {
                var file = src
                var note = ""
                if compress {
                    let compressed = try Converter.compressCopy(src, with: settings.quickAction)
                    copy = compressed
                    if compressed.changed {
                        file = compressed.file
                        note = L("Komprimiert (%@). ", compressed.message)
                    } else {
                        note = L("Nicht komprimiert (%@), Original gesendet. ", compressed.message)
                    }
                }
                let task = try blocking { try await client.upload(file, filename: src.lastPathComponent) }
                pending.append((src, task, note))
            } catch {
                ContextMenuRun.report(src, L("Fehler: %@", error.localizedDescription))
            }
        }

        // 2. auf Paperless warten
        let deadline = Date().addingTimeInterval(waitLimit)
        while !pending.isEmpty {
            pending = pending.filter { item in
                let state = (try? blocking { try await client.state(of: item.task) }) ?? .running
                switch state {
                case .running:
                    return true
                case .created(let id):
                    ContextMenuRun.report(item.src, item.note + (id.map { L("In Paperless angelegt (Dokument #%lld)", $0) } ?? L("In Paperless angelegt")))
                case .duplicate(let id):
                    ContextMenuRun.report(item.src, item.note + (id.map { L("Paperless: Duplikat von Dokument #%lld – nicht übernommen", $0) }
                                                       ?? L("Paperless: Duplikat – nicht übernommen")))
                case .failed(let message):
                    ContextMenuRun.report(item.src, item.note + L("Paperless-Fehler: %@", message))
                }
                return false
            }
            if pending.isEmpty { break }
            if Date() > deadline {
                pending.forEach {
                    ContextMenuRun.report($0.src, $0.note + L("Hochgeladen; Paperless verarbeitet noch – Ergebnis dort prüfen"))
                }
                break
            }
            Thread.sleep(forTimeInterval: 2)
        }
    }

    private final class Box<T>: @unchecked Sendable {
        var result: Result<T, Error>?
    }

    /// Führt eine async-Funktion im Kommandozeilenmodus synchron aus.
    /// `@Sendable`: sonst übernimmt ein Closure aus einem @MainActor-Kontext (Main.main) dessen Isolation, würde auf
    /// dem hier blockierten Main-Thread laufen wollen – Deadlock.
    static func blocking<T>(_ work: @escaping @Sendable () async throws -> T) throws -> T {
        let box = Box<T>()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            do {
                box.result = .success(try await work())
            } catch {
                box.result = .failure(error)
            }
            done.signal()
        }
        done.wait()
        return try box.result!.get()
    }
}
