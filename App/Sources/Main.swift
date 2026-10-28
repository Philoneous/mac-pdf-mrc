// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

/// Startpunkt.
///   --auftrag <Art> <PDFs…>          Finder-Schnellaktion: Auftrag an die App übergeben (startet sie bei Bedarf im
///                                    Hintergrund) und sofort enden; Art: compress, send, compressAndSend
///   --kontextmenue <PDFs…>          direkt komprimieren (Kontextmenü-Profil), Ergebnis auf der Konsole
///   --paperless <PDFs…>             direkt: Original an Paperless senden
///   --paperless-komprimiert <PDFs…> direkt: komprimieren (Kontextmenü-Profil) und an Paperless senden
///   --paperless-token               API-Token von der Standardeingabe in den Schlüsselbund (für Skripte)
///   --schnellaktionen-einrichten    Schnellaktionen einrichten/aktualisieren (wie beim Start der App)
///   --sprachen-laden <Kürzel…>      Tesseract-Sprachen nachladen (eigenständige App), z. B. fra pol
/// Ohne diese Argumente (oder mit --hintergrund) startet die App.
@main
enum Main {
    @MainActor
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        let files = Array(args.dropFirst())
        switch args.first {
        case "--auftrag":
            guard let kind = args.dropFirst().first.flatMap(JobKind.init(rawValue:)) else { fail("unknown job") }
            let paths = Array(args.dropFirst(2))
            do {
                try JobQueue.submit(kind, files: paths)
            } catch {
                // App ließ sich nicht starten: dann eben hier und jetzt (nichts geht verloren)
                Direct.run(kind, paths)
            }
        case "--kontextmenue": Direct.run(.compress, files)
        case "--paperless": Direct.run(.send, files)
        case "--paperless-komprimiert": Direct.run(.compressAndSend, files)
        case "--schnellaktionen-einrichten": QuickAction.setUp()
        case "--sprachen-laden":
            for code in files {
                do {
                    try Direct.blocking { try await Languages.download(code) }
                    print(L("Language “%@” installed", code))
                } catch {
                    fail(L("Error: %@", error.localizedDescription))
                }
            }
        case "--paperless-token":
            do {
                try PaperlessToken.save(readLine(strippingNewline: true) ?? "")
            } catch {
                fail(L("Error: %@", error.localizedDescription))
            }
        default: PDFMRCApp.main()
        }
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(1)
    }
}

/// Aufträge ohne App-Oberfläche: Ergebnis auf der Konsole, im Verlauf und als Mitteilung (osascript).
enum Direct {
    static func run(_ kind: JobKind, _ paths: [String]) {
        let settings = AppSettings.load()
        for path in paths {
            let src = URL(fileURLWithPath: path)
            let entry = (try? blocking { await JobRunner.run(kind, file: src, settings: settings) })
                ?? HistoryEntry(kind: kind, source: path, status: .failed)
            print("\(src.lastPathComponent): \(entry.message)")
            History.append(entry)
            Notifier.legacy(title: src.lastPathComponent, text: entry.message)
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
