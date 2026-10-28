// SPDX-License-Identifier: AGPL-3.0-or-later
import AppKit
import UserNotifications

/// Mitteilungen der App (mit App-Symbol und Knöpfen „Im Finder zeigen“ / „In Paperless öffnen“). Ohne Erlaubnis oder
/// außerhalb der App (Kommandozeile) über osascript wie bisher.
enum Notifier {
    private static let category = "result"
    private static let showAction = "show"
    private static let paperlessAction = "paperless"
    private static let delegate = Delegate()

    /// Beim Start der App: Knöpfe anmelden und Klicks auf Mitteilungen empfangen (auch wenn sie die App starten).
    static func setUp() {
        let center = UNUserNotificationCenter.current()
        center.delegate = delegate
        center.setNotificationCategories([UNNotificationCategory(
            identifier: category,
            actions: [UNNotificationAction(identifier: showAction, title: L("Show in Finder"), options: []),
                      UNNotificationAction(identifier: paperlessAction, title: L("Open in Paperless"), options: [])],
            intentIdentifiers: [], options: [])])
    }

    static func post(_ entry: HistoryEntry) async {
        let center = UNUserNotificationCenter.current()
        guard await authorized(center) else {
            legacy(title: entry.fileName, text: entry.message)
            return
        }
        let content = UNMutableNotificationContent()
        content.title = entry.fileName
        content.subtitle = entry.status == .failed ? L("Failed") : entry.kind.title
        content.body = entry.message
        content.categoryIdentifier = category
        content.userInfo = ["output": entry.output ?? entry.source, "paperless": entry.paperlessLink?.absoluteString ?? ""]
        do {
            try await center.add(UNNotificationRequest(identifier: entry.id.uuidString, content: content, trigger: nil))
        } catch {
            legacy(title: entry.fileName, text: entry.message)
        }
    }

    /// Erlaubnis vorhanden? Beim ersten Mal fragt macOS; ohne Antwort binnen 10 s (z. B. niemand am Rechner) gilt
    /// sie für diese Mitteilung als nicht erteilt.
    private static func authorized(_ center: UNUserNotificationCenter) async -> Bool {
        switch await center.notificationSettings().authorizationStatus {
        case .authorized, .provisional:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                let once = Once()
                center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                    once.run { continuation.resume(returning: granted) }
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + 10) {
                    once.run { continuation.resume(returning: false) }
                }
            }
        default:
            return false
        }
    }

    /// Mitteilung per AppleScript (Kommandozeile, oder wenn Mitteilungen der App nicht erlaubt sind).
    static func legacy(title: String, text: String) {
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

    /// Führt nur den ersten Aufruf aus (Antwort oder Zeitgrenze).
    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false

        func run(_ work: () -> Void) {
            lock.lock()
            defer { lock.unlock() }
            guard !done else { return }
            done = true
            work()
        }
    }

    private final class Delegate: NSObject, UNUserNotificationCenterDelegate {
        // auch zeigen, wenn die App gerade vorn ist
        func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
            completionHandler([.banner, .list])
        }

        func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                    withCompletionHandler completionHandler: @escaping () -> Void) {
            let info = response.notification.request.content.userInfo
            let file = (info["output"] as? String).map { URL(fileURLWithPath: $0) }
            let paperless = (info["paperless"] as? String).flatMap { $0.isEmpty ? nil : URL(string: $0) }
            let action = response.actionIdentifier
            Task { @MainActor in
                switch action {
                case Notifier.paperlessAction:
                    if let paperless { NSWorkspace.shared.open(paperless) }
                case Notifier.showAction:
                    if let file { NSWorkspace.shared.activateFileViewerSelecting([file]) }
                default:  // Klick auf die Mitteilung: Verlauf zeigen
                    AppWindows.showMain(tab: "verlauf")
                }
            }
            completionHandler()
        }
    }
}
