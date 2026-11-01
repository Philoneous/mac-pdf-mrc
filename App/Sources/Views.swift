// SPDX-License-Identifier: AGPL-3.0-or-later
import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var termination: DispatchSourceSignal?
    /// Vom Kontextmenü im Hintergrund gestartet: ohne Fenster und Dock-Symbol, nur Menüleiste.
    private let background = CommandLine.arguments.contains(JobQueue.backgroundFlag)

    func applicationWillFinishLaunching(_ notification: Notification) {
        if background { NSApp.setActivationPolicy(.accessory) }
        Notifier.setUp()  // früh, damit ein Klick auf eine Mitteilung ankommt, auch wenn er die App startet
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSLog("PDFMRC launched (background: %@)", background ? "yes" : "no")
        if ProcessInfo.processInfo.environment["MRC_DIAGNOSE"] != nil || background {
            // Lebenszeichen des Main-Threads (Diagnose: hängt die Hintergrund-App?)
            Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in NSLog("PDFMRC main alive") }
        }
        QuickAction.setUp()
        JobCenter.shared.start()
        if background {
            // SwiftUI öffnet beim Start immer ein Fenster – im Hintergrundmodus schließt ContentView es beim Erscheinen
            AppWindows.suppressLaunchWindow = true
            DispatchQueue.main.async { AppWindows.main.forEach { $0.close() } }
        }
        // Fenster zu, Aufträge laufen noch: kein Dock-Symbol mehr, nur die Menüleiste
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in
                if JobCenter.shared.isBusy && !AppWindows.anyVisible { NSApp.setActivationPolicy(.accessory) }
            }
        }
        NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { note in
            Task { @MainActor in
                if let window = note.object as? NSWindow, AppWindows.main.contains(window) { NSApp.setActivationPolicy(.regular) }
            }
        }
        // SIGTERM (z. B. Abmelden per Skript) wie „Beenden“ behandeln, damit fertige Updates installiert werden
        signal(SIGTERM, SIG_IGN)
        termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        termination?.setEventHandler { NSApp.terminate(nil) }
        termination?.resume()
    }

    /// Letztes Fenster zu: beenden – außer es laufen noch Aufträge (dann beendet sich die App danach selbst).
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !JobCenter.shared.isBusy
    }
}

struct PDFMRCApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var store = SettingsStore()

    init() {
        #if SPARKLE
        _ = Updates.controller  // Sparkle früh starten (sucht im Hintergrund, installiert beim Beenden)
        #endif
    }

    var body: some Scene {
        WindowGroup("PDF MRC", id: "main") {
            ContentView().environmentObject(store)
        }
        .defaultSize(width: 800, height: 780)
        .windowResizability(.contentMinSize)
        .commands {
            if Updates.available {
                CommandGroup(after: .appInfo) {
                    Button("Check for Updates…") { Updates.checkNow() }
                }
            }
        }

        Settings {
            SettingsPane().frame(width: 520, height: 520)
        }
    }
}

/// Bereiche der App in der Seitenleiste (immer sichtbar, auch bei schmalem Fenster).
enum Pane: String, CaseIterable, Identifiable {
    case umwandeln, kontextmenue, paperless, verlauf, einstellungen, info
    var id: Self { self }

    var title: String {
        switch self {
        case .umwandeln: return L("Convert manually")
        case .kontextmenue: return L("Context menu")
        case .paperless: return "Paperless"
        case .verlauf: return L("History")
        case .einstellungen: return L("Settings")
        case .info: return L("About")
        }
    }

    var symbol: String {
        switch self {
        case .umwandeln: return "doc.zipper"
        case .kontextmenue: return "contextualmenu.and.cursorarrow"
        case .paperless: return "tray.and.arrow.up"
        case .verlauf: return "clock.arrow.circlepath"
        case .einstellungen: return "gearshape"
        case .info: return "info.circle"
        }
    }
}

struct ContentView: View {
    @AppStorage("tab") private var tab = Pane.umwandeln.rawValue
    @Environment(\.openWindow) private var openWindow

    private var selection: Binding<Pane?> {
        Binding(get: { Pane(rawValue: tab) ?? .umwandeln }, set: { if let pane = $0 { tab = pane.rawValue } })
    }

    var body: some View {
        HStack(spacing: 0) {
            List(Pane.allCases, selection: selection) { pane in
                Label(pane.title, systemImage: pane.symbol).tag(pane)
            }
            .listStyle(.sidebar)
            .frame(width: 200)
            Divider()
            Group {
                switch Pane(rawValue: tab) ?? .umwandeln {
                case .umwandeln: ConvertView()
                case .kontextmenue: ContextMenuView()
                case .paperless: PaperlessView()
                case .verlauf: HistoryView()
                case .einstellungen: SettingsPane()
                case .info: AboutView()
                }
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(minWidth: 760, idealWidth: 800, minHeight: 520, idealHeight: 780)
        .onAppear {
            AppWindows.openWindow = openWindow  // um später ein neues Fenster öffnen zu können (Menüleiste, Mitteilung)
            guard AppWindows.suppressLaunchWindow else { return }
            AppWindows.suppressLaunchWindow = false
            DispatchQueue.main.async { AppWindows.main.forEach { $0.close() } }
        }
    }
}

// MARK: - Menüleiste

struct JobsMenu: View {
    @ObservedObject private var center = JobCenter.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(verbatim: "PDF MRC").font(.headline)
            ForEach(center.jobs) { job in
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(job.file.lastPathComponent).lineLimit(1).truncationMode(.middle)
                        Text(job.stage.title).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if !center.finished.isEmpty {
                if !center.jobs.isEmpty { Divider() }
                ForEach(center.finished) { entry in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: entry.status.symbol).foregroundStyle(entry.status.color)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.fileName).lineLimit(1).truncationMode(.middle)
                            Text(entry.message).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                        }
                    }
                }
            }
            Divider()
            HStack {
                Button("Show History") { open(.verlauf) }
                Spacer()
                Button("Open PDF MRC") { open(nil) }
            }
        }
        .padding()
        .frame(width: 340)
    }

    private func open(_ pane: Pane?) {
        StatusItem.shared.closePopover()
        AppWindows.showMain(tab: pane?.rawValue)
    }
}

// MARK: - Manuelle Umwandlung

struct ConvertView: View {
    @EnvironmentObject private var store: SettingsStore
    @State private var file: URL?
    @State private var running = false
    @State private var result: HistoryEntry?
    @State private var choosing = false
    @State private var dropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            dropZone
            ProfileForm(profile: $store.settings.manual)
            HStack {
                Button("Convert", action: convert)
                    .keyboardShortcut(.defaultAction)
                    .disabled(file == nil || running)
                    .help("Converts the selected PDF with the settings above. The original stays unchanged unless “Replace the original” is selected.")
                if running {
                    ProgressView().controlSize(.small)
                    Text("Converting…").foregroundStyle(.secondary)
                }
                Spacer()
                if let output = result?.output {
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: output)])
                    }
                }
            }
            if let result {
                Text(result.message)
                    .bold()
                    .foregroundStyle(result.status == .failed ? Color.red : Color.primary)
                    .textSelection(.enabled)
                if !result.log.isEmpty {
                    ScrollView {
                        Text(result.log)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 70)
                }
            }
        }
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.pdf]) { picked in
            if case .success(let url) = picked { select(url) }
        }
    }

    private var dropZone: some View {
        RoundedRectangle(cornerRadius: 10)
            .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6]))
            .foregroundStyle(dropTargeted ? Color.accentColor : Color.secondary)
            .frame(height: 86)
            .overlay {
                VStack(spacing: 8) {
                    Text(file?.lastPathComponent ?? L("Drop a PDF here"))
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button("Choose PDF…") { choosing = true }
                }
                .padding(.horizontal)
            }
            .dropDestination(for: URL.self) { urls, _ in
                guard let url = urls.first(where: { $0.pathExtension.lowercased() == "pdf" }) else { return false }
                select(url)
                return true
            } isTargeted: { dropTargeted = $0 }
    }

    private func select(_ url: URL) {
        file = url
        result = nil
    }

    private func convert() {
        guard let file else { return }
        let settings = store.settings
        running = true
        result = nil
        Task.detached {
            let entry = await JobRunner.run(.manual, file: file, settings: settings)
            History.append(entry)
            await MainActor.run {
                running = false
                result = entry
            }
        }
    }
}

// MARK: - Kontextmenü

struct ContextMenuView: View {
    @EnvironmentObject private var store: SettingsStore
    @State private var enabled = QuickAction.compress.isInstalled
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(isOn: $enabled) { TipLabel("Show “Compress PDF (MRC)” in the Finder context menu", tip: "Adds the Quick Action to the Finder context menu: right-click one or more PDFs → Quick Actions → “Compress PDF (MRC)”. It uses the settings in this tab; each result appears as a notification.") }
                .onChange(of: enabled) { on in
                    guard on != QuickAction.compress.isInstalled else { return }
                    do {
                        try QuickAction.compress.setInstalled(on)
                        failure = nil
                    } catch {
                        failure = error.localizedDescription
                        enabled = QuickAction.compress.isInstalled
                    }
                }
            Text("Right-click one or more PDFs in the Finder → Quick Actions. The settings below apply (also to “Compress and Send to Paperless”); each result appears as a notification.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let failure {
                Text(failure).foregroundStyle(.red)
            }
            Button("Copy settings from “Convert manually”") {
                store.settings.quickAction = store.settings.manual
            }
            .help("Replaces the settings in this tab with those from the “Convert manually” tab.")
            ProfileForm(profile: $store.settings.quickAction)
        }
    }
}

// MARK: - Paperless

struct PaperlessView: View {
    @EnvironmentObject private var store: SettingsStore
    @State private var token = ""
    @State private var tokenLoaded = false
    @State private var checking = false
    @State private var status: String?
    @State private var statusOK = false
    @State private var sendEnabled = QuickAction.send.isInstalled
    @State private var compressAndSendEnabled = QuickAction.compressAndSend.isInstalled
    @State private var failure: String?

    var body: some View {
        Form {
            Section("Server") {
                TextField(text: $store.settings.paperlessURL,
                          prompt: Text(verbatim: "https://paperless.example.com")) { TipLabel("Server address", tip: "Address of your Paperless-ngx server, e.g. https://paperless.example.com. When away from home, use HTTPS (e.g. a reverse proxy with a certificate) or a VPN. Self-signed certificates are not supported.") }
                SecureField(text: $token) { TipLabel("API token", tip: "In Paperless under “My Profile” → “API Auth Token”. Stored in the macOS keychain. After an app update, macOS asks once whether the app may still access it.") }
                HStack {
                    Button("Save and test connection", action: saveAndCheck)
                        .disabled(checking)
                        .help("Saves the address and token and checks that Paperless can be reached and accepts the token.")
                    if checking {
                        ProgressView().controlSize(.small)
                    }
                }
                if let status {
                    Text(status).foregroundStyle(statusOK ? Color.green : Color.red)
                }
                if store.settings.paperlessURL.lowercased().hasPrefix("http://") {
                    Text("Unencrypted (http): when away from home, connect only via HTTPS (e.g. a reverse proxy) or a VPN – otherwise the token and documents travel over the network in plain text.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            Section("Finder context menu") {
                Toggle(isOn: $sendEnabled) { TipLabel("“Send to Paperless” (original)", tip: "Quick Action that sends the PDF unchanged. Paperless compresses it on the server (if paperless-mrc is installed there).") }
                    .onChange(of: sendEnabled) { on in sendEnabled = apply(.send, on) }
                Toggle(isOn: $compressAndSendEnabled) { TipLabel("“Compress and Send to Paperless”", tip: "Quick Action that compresses on the Mac first (settings from the “Context menu” tab) and sends the result – or the original if it cannot be made smaller. Useful with a slow server or a slow upload.") }
                    .onChange(of: compressAndSendEnabled) { on in compressAndSendEnabled = apply(.compressAndSend, on) }
                Text("The file on your Mac always stays unchanged. Compression uses the settings in the “Context menu” tab; Paperless does not compress a file sent this way a second time. The result (added document, duplicate or error) appears as a notification.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let failure {
                    Text(failure).foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            guard !tokenLoaded else { return }
            tokenLoaded = true
            // Im Hintergrund: nach einem Update fragt macOS ggf. nach dem Schlüsselbund-Zugriff
            Task.detached {
                let stored = PaperlessToken.load() ?? ""
                await MainActor.run { token = stored }
            }
        }
    }

    /// Schaltet eine Schnellaktion; Rückgabe: tatsächlicher Zustand.
    private func apply(_ action: QuickAction, _ on: Bool) -> Bool {
        guard on != action.isInstalled else { return on }
        do {
            try action.setInstalled(on)
            failure = nil
        } catch {
            failure = error.localizedDescription
        }
        return action.isInstalled
    }

    private func saveAndCheck() {
        let address = store.settings.paperlessURL
        let token = token
        checking = true
        status = nil
        Task {
            do {
                try PaperlessToken.save(token)
                try await PaperlessClient(address: address, token: token).check()
                status = L("Connection OK")
                statusOK = true
            } catch {
                status = error.localizedDescription
                statusOK = false
            }
            checking = false
        }
    }
}

// MARK: - Sprachen der Texterkennung

struct LanguageStatus: View {
    let spec: String
    @State private var loading = false
    @State private var failure: String?
    @State private var generation = 0  // nach dem Laden neu auswerten

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            let missing = Languages.missing(spec)
            if !missing.isEmpty {
                HStack {
                    Text(L("Not installed: %@", missing.joined(separator: ", "))).foregroundStyle(.orange)
                    Spacer()
                    if loading {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Download") { load(missing) }
                            .help("Downloads the missing languages from tessdata_fast (github.com/tesseract-ocr) to ~/Library/Application Support/mac-pdf-mrc/tessdata.")
                    }
                }
            }
            if let failure {
                Text(failure).foregroundStyle(.red)
            }
            Text(L("Installed: %@", Languages.installed.joined(separator: ", ")))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .id(generation)
    }

    private func load(_ codes: [String]) {
        loading = true
        failure = nil
        Task {
            for code in codes {
                do {
                    try await Languages.download(code)
                } catch {
                    failure = error.localizedDescription
                    break
                }
            }
            loading = false
            generation += 1
        }
    }
}

// MARK: - Einstellungen eines Profils (Tooltips = Erklärungen aus dem README)

struct ProfileForm: View {
    @Binding var profile: Profile

    var body: some View {
        Form {
            Section("Page selection") {
                Toggle(isOn: $profile.mixedPdfs) { TipLabel("Also process PDFs with digital pages", tip: "Also compresses the scanned pages of PDFs that contain digital pages as well (e.g. a scan with a generated cover page); digital pages stay unchanged. Off: only PDFs that consist entirely of scans are processed. Default: on.") }
                Toggle(isOn: $profile.skipPhotos) { TipLabel("Leave photo pages unchanged", tip: "MRC visibly degrades photos, so pages recognized as photos stay unchanged. Default: on.") }
                TextField(value: $profile.photoPaperPercent,
                          format: .number.precision(.fractionLength(0...1))) { TipLabel("Text check below paper area (%)", tip: "Share of the page that must look like plain paper for it to count as a document straight away. Pages with less paper (photos, but also forms with shaded boxes) only count as documents if enough text is recognized. Range 0–100 %: 0 = never check, every page counts as a document; 100 = check every page. Documents on white paper typically have 60–98 %, photos 10–45 %. Default: 50.") }
                    .disabled(!profile.skipPhotos)
                TextField(value: $profile.photoMinWords, format: .number) { TipLabel("Photo below confident words", tip: "A checked page counts as a photo if fewer words than this are recognized with high confidence (words with at least 3 letters or digits). Range 0–100: 0 = a page never counts as a photo; higher = a page needs more text to be compressed. Default: 10.") }
                    .disabled(!profile.skipPhotos)
                Toggle(isOn: $profile.vectorPages) { TipLabel("Rasterize vectorized scans and make them searchable", tip: "Some scanner software stores pages as thousands of vector elements instead of an image. Such pages (no image, no text) are rasterized, compressed and made searchable. Default: on.") }
                TextField(value: $profile.vectorMinItems, format: .number) { TipLabel("Vectorized from elements", tip: "A page without image and text counts as a vectorized scan from this many lines and curves. Range 1–100,000: low values also turn simple digital drawings into an image; high values only very detailed pages. Default: 1000.") }
                    .disabled(!profile.vectorPages)
                Picker(selection: $profile.vectorDpi) {
                    Text(verbatim: "200 dpi").tag(200)
                    Text("300 dpi (default)").tag(300)
                    Text(verbatim: "400 dpi").tag(400)
                    Text(verbatim: "600 dpi").tag(600)
                } label: { TipLabel("Raster resolution", tip: "Resolution at which vectorized scans are turned into an image. Choice 200–600 dpi: 200 = smallest and fastest; 600 = sharpest for very small print, but larger and slower. Default: 300 dpi.") }
                .disabled(!profile.vectorPages)
            }
            Section("Text recognition") {
                Toggle(isOn: $profile.keepTextLayer) { TipLabel("Keep existing text layer", tip: "Keeps an existing text layer (e.g. from the scanner) instead of recognizing the text again. Off: always recognize with Tesseract – pages are then also rotated and deskewed. Default: on.") }
                TextField(text: $profile.languages, prompt: Text(verbatim: "deu+eng")) { TipLabel("Languages", tip: "Tesseract language codes joined with +, e.g. deu+eng+fra. German and English are included; missing languages can be downloaded here. Default: deu+eng.") }
                if Languages.isManaged {
                    LanguageStatus(spec: profile.languages)
                }
                Toggle(isOn: $profile.rotate) { TipLabel("Rotate pages automatically", tip: "Turns pages that are upside down or sideways the right way up. Only pages without a kept text layer. Default: on.") }
                TextField(value: $profile.rotateThreshold,
                          format: .number.precision(.fractionLength(0...1))) { TipLabel("Minimum rotation confidence", tip: "How sure Tesseract’s orientation detection must be before a page is rotated. Range 0–100: 0 = rotate whenever a rotation is suggested (pages may be turned the wrong way); high values = only rotate very clear cases, otherwise the page stays as it is. Default: 12 (as in Paperless-ngx).") }
                    .disabled(!profile.rotate)
                Toggle(isOn: $profile.rotateCheck) { TipLabel("Check uncertain rotation with text recognition", tip: "If the orientation detection is unsure (below the minimum confidence) but suggests a rotation, the text is recognized in both orientations; the page is only rotated if that gives clearly more confidently recognized words (at least 1.5 times as many). Helps with landscape forms scanned in portrait. Costs extra time only for such pages. Default: on.") }
                    .disabled(!profile.rotate)
                Toggle(isOn: $profile.deskew) { TipLabel("Deskew", tip: "Straightens slightly skewed scans. Only pages without a kept text layer. Default: on.") }
                TextField(value: $profile.deskewMinAngle,
                          format: .number.precision(.fractionLength(0...2))) { TipLabel("Minimum skew (degrees)", tip: "Smaller skews are left as they are, because every rotation slightly softens the image. Range 0–2°: 0 = correct every detected skew; 2 = only clearly visible skews. Default: 0.2.") }
                    .disabled(!profile.deskew)
                TextField(value: $profile.deskewMaxAngle,
                          format: .number.precision(.fractionLength(0...1))) { TipLabel("Search range ± (degrees)", tip: "The skew is searched within ± this angle. A result at the edge of the range counts as ambiguous (e.g. a page without lines of text) and is not corrected. Range 0.5–45°: small = faster, only slightly skewed pages; large = also strongly skewed pages, but slower. Default: 5.") }
                    .disabled(!profile.deskew)
                TextField(value: $profile.deskewConfidence,
                          format: .number.precision(.fractionLength(0...2))) { TipLabel("Minimum skew clarity", tip: "Only deskews if the best angle clearly stands out (factor over the median of all angles tested). Range 1–3: 1 = always deskew – logos or stamps on pages with little text can then tilt a straight page; 3 = only pages with many clear lines of text. Measured: pages without lines of text stay below 1.15, pages with at least one line of text reach 1.4 or more. Default: 1.3.") }
                    .disabled(!profile.deskew)
            }
            Section("Blank pages") {
                Toggle(isOn: $profile.removeBlank) { TipLabel("Remove blank scanned pages", tip: "Removes scanned pages without content, e.g. empty back sides from duplex scanning. Digital pages are never removed. Default: on.") }
                TextField(value: $profile.blankInkPercent,
                          format: .number.precision(.fractionLength(0...4))) { TipLabel("Blank below ink share (%)", tip: "A page counts as blank if less than this share of its area is ink. Range 0–1 %: 0 = never remove a page; higher = pages with little content are removed too. A page with only a page number has about 0.01 %. Default: 0.005.") }
                    .disabled(!profile.removeBlank)
                TextField(value: $profile.blankInkContrast, format: .number) { TipLabel("Ink contrast for blank (levels)", tip: "For the blank check, a pixel counts as ink if it is at least this many brightness levels (of 255) darker than the paper around it. Range 10–100: low = even faint content keeps a page (10: strong show-through from the back may too); high = only clear marks count (40 = behavior before November 2026: pale photos and faded receipts were removed). Measured on real scans: blank pages stay at zero even with show-through, a pale photo of a wall and faded print are recognized at 20. Default: 20.") }
                    .disabled(!profile.removeBlank)
                TextField(value: $profile.blankPaperPercent,
                          format: .number.precision(.fractionLength(0...1))) { TipLabel("Minimum paper area for blank (%)", tip: "A page only counts as blank if at least this share of it looks like paper. Protects low-contrast photos (e.g. of a white wall) from being removed. Range 0–100 %: 0 = no protection; 100 = practically no page counts as blank. Default: 90.") }
                    .disabled(!profile.removeBlank)
            }
            Section("Quality and size") {
                Picker(selection: $profile.bgDownsample) {
                    Text("Full").tag(1)
                    Text("1/2 (default)").tag(2)
                    Text(verbatim: "1/3").tag(3)
                    Text(verbatim: "1/4").tag(4)
                } label: { TipLabel("Background resolution", tip: "Resolution of the background layer (paper, colored areas, pictures on the page) relative to the scan; text and lines always keep full resolution. Choice full to 1/4: full = best colors and pictures, files about 1.7 times as large, text no more readable; 1/4 = smallest, colored areas and pictures become blocky. Default: 1/2.") }
                LabeledContent {
                    Slider(value: $profile.bgRate, in: 50...800, step: 25)
                } label: { TipLabel(verbatim: L("Compression rate: %lld", Int(profile.bgRate)), tip: "JPEG 2000 compression of the background layer. Range 50–800: 50 = barely compressed, large files; 800 = very small, colored areas and pictures get blotchy. Text that is part of the sharp text layer is not affected. Default: 200.") }
                Toggle(isOn: $profile.fitA4) { TipLabel("Correct wrong page sizes", tip: "Scales scanned pages with an implausible page size (shorter side larger than A3, e.g. phone scans stored several times too large) down to the target size, so they display and print at a normal size. The aspect ratio is kept; normal sizes such as A5, receipts or A3 plans stay as they are. Default: on.") }
                Picker(selection: $profile.fitPageSize) {
                    Text("A4 (default)").tag("a4")
                    Text(verbatim: "US Letter").tag("letter")
                    Text(verbatim: "US Legal").tag("legal")
                } label: { TipLabel("Target page size", tip: "Size that implausibly large pages are scaled down to. A4: Europe and most other countries; US Letter (8.5 × 11 in): USA, Canada; US Legal (8.5 × 14 in): US legal documents. Default: A4.") }
                    .disabled(!profile.fitA4)
                Picker(selection: $profile.maxDpi) {
                    Text("Off (default)").tag(0)
                    Text(verbatim: "200 dpi").tag(200)
                    Text(verbatim: "300 dpi").tag(300)
                    Text(verbatim: "400 dpi").tag(400)
                } label: { TipLabel("Maximum resolution", tip: "Downscales scans with a higher resolution before compressing: faster and smaller, but the finest details are lost. Choice: off or 200–400 dpi. Measured with a 300-dpi scan: 200 dpi halves the file, but digits in print of 6 pt and smaller start being misread. Default: off (the scan keeps its resolution).") }
                LabeledContent {
                    Slider(value: Binding(get: { Double(profile.sharpen) }, set: { profile.sharpen = Int($0) }),
                           in: 0...300, step: 25)
                } label: { TipLabel(verbatim: profile.sharpen == 0 ? L("Sharpening: off") : L("Sharpening: %lld %%", profile.sharpen), tip: "Sharpens the scan before compressing so that faint, thin text stays crisp and complete. Range 0–300 %: 0 = off, faint text can look patchy; high values make text bolder but also emphasize noise and stains – from 200 % text recognition makes slightly more errors. Default: 150 %.") }
                TextField(value: $profile.sharpenRadius,
                          format: .number.precision(.fractionLength(0...1))) { TipLabel("Sharpening radius (px at 200 dpi)", tip: "Width of the sharpening in pixels at 200 dpi; scaled with the resolution of the scan. Range 0.5–5: small = only fine edges, thin strokes can break up; large = visible halos around letters. Default: 1.5.") }
                    .disabled(profile.sharpen == 0)
                LabeledContent {
                    Slider(value: $profile.maskFactor, in: 0.1...1.0, step: 0.05)
                } label: { TipLabel(verbatim: L("Text mask factor: %.2f", profile.maskFactor), tip: "Decides which pixels go into the sharp text layer at full resolution; everything else ends up in the lower-resolution background. Range 0.1–1.0: smaller = faint text and thin lines also stay sharp, but more specks of dirt are kept; 1.0 = setting of the underlying tool recode_pdf, faint text may become blurry. Default: 0.5.") }
                Stepper(value: $profile.jobs, in: 0...16) { TipLabel(verbatim: profile.jobs == 0 ? L("Simultaneous pages: automatic") : L("Simultaneous pages: %lld", profile.jobs), tip: "Number of pages processed at the same time. Range: automatic or 1–16; more = faster on Macs with many cores, but needs more memory. Default: automatic (number of processor cores).") }
            }
            Section("Output") {
                Picker(selection: $profile.output) {
                    Text("Save as a copy next to the original").tag(OutputMode.copy)
                    Text("Replace the original (original goes to the Trash)").tag(OutputMode.replace)
                } label: { TipLabel("Result", tip: "A result is only saved if it was verified and is smaller. Otherwise no file is created and the original stays unchanged; an existing copy is not overwritten. Default: copy.") }
                .pickerStyle(.radioGroup)
                if profile.output == .copy {
                    TextField(text: $profile.suffix) { TipLabel("File name suffix", tip: "Added to the file name of the copy, e.g. “Invoice (compressed).pdf”.") }
                }
            }
            Section {
                Button("Restore defaults") { profile = Profile() }
                    .help("Resets all settings in this tab to their defaults.")
            }
        }
        .formStyle(.grouped)
        // Eingaben außerhalb des gültigen Bereichs sofort auf den Bereich setzen (Tooltips nennen ihn)
        .onChange(of: profile) { value in
            let valid = value.clamped()
            if valid != value { profile = valid }
        }
    }
}
