// SPDX-License-Identifier: AGPL-3.0-or-later
import AppKit
import Foundation

/// Was mit einer Datei geschehen soll.
enum JobKind: String, Codable, CaseIterable {
    case manual           // Reiter „Convert manually“
    case compress         // Schnellaktion „Compress PDF (MRC)“
    case send             // Schnellaktion „Send to Paperless“
    case compressAndSend  // Schnellaktion „Compress and Send to Paperless“

    var title: String {
        switch self {
        case .manual: return L("Converted manually")
        case .compress: return L("Compressed")
        case .send: return L("Sent to Paperless")
        case .compressAndSend: return L("Compressed and sent to Paperless")
        }
    }

    var symbol: String {
        switch self {
        case .manual, .compress: return "doc.zipper"
        case .send, .compressAndSend: return "tray.and.arrow.up"
        }
    }
}

/// Stand eines laufenden Auftrags (Menüleiste).
enum JobStage: Equatable {
    case queued, compressing, uploading, waitingForPaperless

    var title: String {
        switch self {
        case .queued: return L("Waiting…")
        case .compressing: return L("Compressing…")
        case .uploading: return L("Uploading…")
        case .waitingForPaperless: return L("Paperless is processing…")
        }
    }
}

/// Nur eine Umwandlung gleichzeitig (paperless-mrc nutzt ohnehin alle Kerne); Hochladen und Warten auf Paperless
/// laufen daneben weiter.
actor CompressionGate {
    static let shared = CompressionGate()
    private var busy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !busy {
            busy = true
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    func release() {
        if waiting.isEmpty {
            busy = false
        } else {
            waiting.removeFirst().resume()
        }
    }
}

/// Führt einen Auftrag aus und liefert den Verlaufseintrag (gemeinsam für App, Menüleiste und Kommandozeile).
enum JobRunner {
    static let paperlessWaitLimit: TimeInterval = 600

    static func run(_ kind: JobKind, file src: URL, settings: AppSettings,
                    stage: @escaping @Sendable (JobStage) -> Void = { _ in }) async -> HistoryEntry {
        var entry = HistoryEntry(kind: kind, source: src.path)
        entry.sizeBefore = (try? FileManager.default.attributesOfItem(atPath: src.path)[.size] as? Int) ?? nil
        do {
            switch kind {
            case .manual, .compress:
                try await compress(src, profile: kind == .manual ? settings.manual : settings.quickAction,
                                   into: &entry, stage: stage)
            case .send, .compressAndSend:
                try await send(src, compress: kind == .compressAndSend, settings: settings, into: &entry, stage: stage)
            }
        } catch {
            entry.status = .failed
            entry.message = L("Error: %@", error.localizedDescription)
        }
        return entry
    }

    private static func timed<T>(_ step: String, _ entry: inout HistoryEntry, _ work: () async throws -> T)
        async rethrows -> T {
        let start = Date()
        defer { entry.timings.append(.init(step: step, seconds: Date().timeIntervalSince(start))) }
        return try await work()
    }

    private static func compress(_ src: URL, profile: Profile, into entry: inout HistoryEntry,
                                 stage: @Sendable (JobStage) -> Void) async throws {
        await CompressionGate.shared.acquire()
        stage(.compressing)
        let outcome = await timed("compress", &entry) {
            Result { try Converter.convert(src, with: profile) }
        }
        await CompressionGate.shared.release()
        let conversion = try outcome.get()
        entry.message = conversion.message
        entry.log = conversion.log
        entry.output = conversion.output?.path
        entry.status = conversion.output == nil ? .unchanged : .done
        entry.sizeAfter = conversion.result.sizeAfter
        entry.pages = conversion.result.pages
    }

    private static func send(_ src: URL, compress: Bool, settings: AppSettings, into entry: inout HistoryEntry,
                             stage: @escaping @Sendable (JobStage) -> Void) async throws {
        let client = try PaperlessClient.configured(settings)
        entry.paperlessURL = client.base.absoluteString
        // Verbindung und Token vorab prüfen: klare Meldung statt abgebrochenem Upload
        stage(.uploading)
        try await client.check()

        var file = src
        var note = ""
        var copy: Converter.CompressedCopy?
        defer { if let copy { try? FileManager.default.removeItem(at: copy.directory) } }
        if compress {
            await CompressionGate.shared.acquire()
            stage(.compressing)
            let outcome = await timed("compress", &entry) {
                Result { try Converter.compressCopy(src, with: settings.quickAction) }
            }
            await CompressionGate.shared.release()
            let compressed = try outcome.get()
            copy = compressed
            entry.log = compressed.log
            entry.pages = compressed.result.pages
            if compressed.changed {
                file = compressed.file
                entry.sizeAfter = compressed.result.sizeAfter
                note = L("Compressed (%@). ", compressed.message)
            } else {
                note = L("Not compressed (%@), original sent. ", compressed.message)
            }
        }

        stage(.uploading)
        let upload = file
        let task = try await timed("upload", &entry) {
            try await client.upload(upload, filename: src.lastPathComponent)
        }

        stage(.waitingForPaperless)
        let start = Date()
        var state = PaperlessClient.TaskState.running
        while Date().timeIntervalSince(start) < paperlessWaitLimit {
            state = (try? await client.state(of: task)) ?? .running
            if case .running = state {
                try await Task.sleep(nanoseconds: 2_000_000_000)
                continue
            }
            break
        }
        entry.timings.append(.init(step: "paperless", seconds: Date().timeIntervalSince(start)))

        switch state {
        case .running:
            entry.status = .pending
            entry.message = note + L("Uploaded; Paperless is still processing – check the result there")
        case .created(let id):
            entry.paperlessDocument = id
            entry.message = note + (id.map { L("Added to Paperless (document #%lld)", $0) } ?? L("Added to Paperless"))
        case .duplicate(let id):
            entry.status = .unchanged
            entry.paperlessDocument = id
            entry.message = note + (id.map { L("Paperless: duplicate of document #%lld – not added", $0) }
                                    ?? L("Paperless: duplicate – not added"))
        case .failed(let message):
            entry.status = .failed
            entry.message = note + L("Paperless error: %@", message)
        }
    }
}

/// Übergabe aus dem Finder an die laufende (oder im Hintergrund gestartete) App: Auftragsdateien in
/// ~/Library/Application Support/mac-pdf-mrc/jobs, dazu eine Distributed Notification.
enum JobQueue {
    struct Request: Codable {
        let kind: JobKind
        let files: [String]
    }

    static let posted = Notification.Name("io.github.philoneous.mac-pdf-mrc.jobs")
    static let backgroundFlag = "--hintergrund"
    private static let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/mac-pdf-mrc/jobs")

    /// Kommandozeile (Schnellaktion): Auftrag ablegen, App benachrichtigen bzw. im Hintergrund starten, sofort enden.
    static func submit(_ kind: JobKind, files: [String]) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = String(format: "%.6f-%@.json", Date().timeIntervalSince1970, UUID().uuidString)
        let temp = directory.appendingPathComponent("." + name)
        try JSONEncoder().encode(Request(kind: kind, files: files)).write(to: temp)
        try fm.moveItem(at: temp, to: directory.appendingPathComponent(name))  // erst vollständig sichtbar

        let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .filter { $0.processIdentifier != getpid() && !$0.isTerminated }
        if !others.isEmpty {
            DistributedNotificationCenter.default().postNotificationName(posted, object: nil, userInfo: nil,
                                                                         deliverImmediately: true)
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        configuration.arguments = [backgroundFlag]
        let done = DispatchSemaphore(value: 0)
        var launchError: Error?
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, error in
            launchError = error
            done.signal()
        }
        _ = done.wait(timeout: .now() + 30)
        if let launchError { throw launchError }
    }

    /// App: alle abgelegten Aufträge übernehmen (Umbenennen = übernehmen, damit keiner doppelt läuft).
    static func takePending() -> [Request] {
        let fm = FileManager.default
        let names = ((try? fm.contentsOfDirectory(atPath: directory.path)) ?? [])
            .filter { $0.hasSuffix(".json") && !$0.hasPrefix(".") }.sorted()
        var requests: [Request] = []
        for name in names {
            let file = directory.appendingPathComponent(name)
            let claimed = directory.appendingPathComponent(".taken-\(getpid())-" + name)
            guard (try? fm.moveItem(at: file, to: claimed)) != nil else { continue }
            if let data = try? Data(contentsOf: claimed), let request = try? JSONDecoder().decode(Request.self, from: data) {
                requests.append(request)
            }
            try? fm.removeItem(at: claimed)
        }
        return requests
    }
}

/// Laufende Aufträge der App (Menüleiste): übernimmt Aufträge, meldet Ergebnisse, beendet die Hintergrund-App danach.
@MainActor
final class JobCenter: ObservableObject {
    static let shared = JobCenter()

    struct Job: Identifiable {
        let id = UUID()
        let kind: JobKind
        let file: URL
        var stage = JobStage.queued
    }

    @Published private(set) var jobs: [Job] = []
    @Published private(set) var finished: [HistoryEntry] = []  // Ergebnisse dieser Sitzung (Menüleiste)
    @Published var menuBarVisible = false
    private var idleTimer: Timer?

    var isBusy: Bool { !jobs.isEmpty }

    func start() {
        NSLog("PDFMRC start")
        DistributedNotificationCenter.default().addObserver(forName: JobQueue.posted, object: nil, queue: .main) { _ in
            Task { @MainActor in JobCenter.shared.collect() }
        }
        collect()
    }

    func collect() {
        for request in JobQueue.takePending() {
            for path in request.files {
                enqueue(request.kind, file: URL(fileURLWithPath: path))
            }
        }
    }

    func enqueue(_ kind: JobKind, file: URL) {
        let job = Job(kind: kind, file: file)
        jobs.append(job)
        idleTimer?.invalidate()
        menuBarVisible = true
        let settings = AppSettings.load()
        let id = job.id
        Task.detached {
            let entry = await JobRunner.run(kind, file: file, settings: settings) { stage in
                Task { @MainActor in JobCenter.shared.update(id, stage) }
            }
            NSLog("PDFMRC job done: %@", entry.status.rawValue)
            History.append(entry)
            await Notifier.post(entry)
            await MainActor.run { JobCenter.shared.finish(id, entry) }
        }
    }

    private func update(_ id: UUID, _ stage: JobStage) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[index].stage = stage
    }

    private func finish(_ id: UUID, _ entry: HistoryEntry) {
        NSLog("PDFMRC finish; remaining %ld", jobs.count - 1)
        jobs.removeAll { $0.id == id }
        finished.insert(entry, at: 0)
        finished = Array(finished.prefix(5))
        guard jobs.isEmpty else { return }
        // Symbol noch kurz zeigen (Ergebnis anklicken), dann ausblenden; ohne offenes Fenster die App beenden
        idleTimer = Timer.scheduledTimer(withTimeInterval: 8, repeats: false) { _ in
            Task { @MainActor in
                let center = JobCenter.shared
                guard center.jobs.isEmpty else { return }
                center.menuBarVisible = false
                NSLog("PDFMRC idle; windows: %@", NSApp.windows.map { "\(type(of: $0)) visible=\($0.isVisible) main=\($0.canBecomeMain)" }.joined(separator: ", "))
                if !AppWindows.anyVisible {
                    NSApp.terminate(nil)
                }
            }
        }
    }
}

/// Fenster der App (ohne Menüleisten-Fenster).
@MainActor
enum AppWindows {
    /// Im Hintergrund gestartet: das Fenster, das SwiftUI beim Start anlegt, gleich wieder schließen.
    static var suppressLaunchWindow = false

    /// Hauptfenster (kein Menüleisten-Fenster, das ist ein Panel).
    static var main: [NSWindow] {
        NSApp.windows.filter { $0.canBecomeMain && !($0 is NSPanel) && $0.styleMask.contains(.titled) }
    }

    static var anyVisible: Bool { main.contains { $0.isVisible } }

    /// Hauptfenster zeigen (aus Menüleiste oder Mitteilung); die App erscheint dann auch im Dock.
    static func showMain(tab: String? = nil) {
        if let tab { UserDefaults.standard.set(tab, forKey: "tab") }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        if let window = main.first {
            window.makeKeyAndOrderFront(nil)
        } else {
            // Die App „erneut öffnen“: SwiftUI legt dann ein neues Fenster der WindowGroup an
            NSWorkspace.shared.open(Bundle.main.bundleURL)
        }
    }
}
