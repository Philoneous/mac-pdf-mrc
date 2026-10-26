// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

/// Startpunkt: mit `--kontextmenue <PDFs…>` (Aufruf aus der Finder-Schnellaktion) ohne Oberfläche,
/// sonst die App.
@main
enum Main {
    @MainActor
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        if args.first == "--kontextmenue" {
            ContextMenuRun.run(Array(args.dropFirst()))
            return
        }
        PDFMRCApp.main()
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
                text = "Fehler: \(error.localizedDescription)"
            }
            print("\(src.lastPathComponent): \(text)")
            notify(title: src.lastPathComponent, text: text)
        }
    }

    private static func notify(title: String, text: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", "on run argv",
                             "-e", "display notification (item 2 of argv) with title (item 1 of argv)",
                             "-e", "end run", title, text]
        do {
            try process.run()
            process.waitUntilExit()
        } catch {}  // Mitteilung ist nur Komfort
    }
}
