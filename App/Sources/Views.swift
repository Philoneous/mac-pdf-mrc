// SPDX-License-Identifier: AGPL-3.0-or-later
import AppKit
import SwiftUI
import UniformTypeIdentifiers

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var termination: DispatchSourceSignal?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationDidFinishLaunching(_ notification: Notification) {
        QuickAction.setUp()
        // SIGTERM (z. B. Abmelden per Skript) wie „Beenden“ behandeln, damit fertige Updates installiert werden
        signal(SIGTERM, SIG_IGN)
        termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        termination?.setEventHandler { NSApp.terminate(nil) }
        termination?.resume()
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
        WindowGroup("PDF MRC") {
            ContentView().environmentObject(store)
        }
        .defaultSize(width: 580, height: 780)
        .windowResizability(.contentMinSize)
        .commands {
            if Updates.available {
                CommandGroup(after: .appInfo) {
                    Button("Check for Updates…") { Updates.checkNow() }
                }
            }
        }

        Settings {
            InfoView().frame(width: 520, height: 560)
        }
    }
}

struct ContentView: View {
    @AppStorage("tab") private var tab = "umwandeln"

    var body: some View {
        TabView(selection: $tab) {
            ConvertView()
                .tabItem { Text("Convert manually") }
                .tag("umwandeln")
            ContextMenuView()
                .tabItem { Text("Context menu") }
                .tag("kontextmenue")
            PaperlessView()
                .tabItem { Text(verbatim: "Paperless") }
                .tag("paperless")
            InfoView()
                .tabItem { Text("About") }
                .tag("info")
        }
        .padding()
        .frame(minWidth: 560, idealWidth: 580, minHeight: 520, idealHeight: 780)
    }
}

// MARK: - Manuelle Umwandlung

struct ConvertView: View {
    @EnvironmentObject private var store: SettingsStore
    @State private var file: URL?
    @State private var running = false
    @State private var result: Conversion?
    @State private var failure: String?
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
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([output]) }
                }
            }
            if let failure {
                Text(failure).foregroundStyle(.red)
            }
            if let result {
                Text(result.message).bold().textSelection(.enabled)
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
        failure = nil
    }

    private func convert() {
        guard let file else { return }
        let profile = store.settings.manual
        running = true
        result = nil
        failure = nil
        Task.detached {
            let outcome = Result { try Converter.convert(file, with: profile) }
            await MainActor.run {
                running = false
                switch outcome {
                case .success(let conversion): result = conversion
                case .failure(let error): failure = error.localizedDescription
                }
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
            Toggle("Show “Compress PDF (MRC)” in the Finder context menu", isOn: $enabled)
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
                .help("Adds the Quick Action to the Finder context menu: right-click one or more PDFs → Quick Actions → “Compress PDF (MRC)”. It uses the settings in this tab; each result appears as a notification.")
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
                TextField("Server address", text: $store.settings.paperlessURL,
                          prompt: Text(verbatim: "https://paperless.example.com"))
                    .help("Address of your Paperless-ngx server, e.g. https://paperless.example.com. When away from home, use HTTPS (e.g. a reverse proxy with a certificate) or a VPN. Self-signed certificates are not supported.")
                SecureField("API token", text: $token)
                    .help("In Paperless under “My Profile” → “API Auth Token”. Stored in the macOS keychain. After an app update, macOS asks once whether the app may still access it.")
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
                Toggle("“Send to Paperless” (original)", isOn: $sendEnabled)
                    .onChange(of: sendEnabled) { on in sendEnabled = apply(.send, on) }
                    .help("Quick Action that sends the PDF unchanged. Paperless compresses it on the server (if paperless-mrc is installed there).")
                Toggle("“Compress and Send to Paperless”", isOn: $compressAndSendEnabled)
                    .onChange(of: compressAndSendEnabled) { on in compressAndSendEnabled = apply(.compressAndSend, on) }
                    .help("Quick Action that compresses on the Mac first (settings from the “Context menu” tab) and sends the result – or the original if it cannot be made smaller. Useful with a slow server or a slow upload.")
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
                Toggle("Also process PDFs with digital pages", isOn: $profile.mixedPdfs)
                    .help("Also compresses the scanned pages of PDFs that contain digital pages as well (e.g. a scan with a generated cover page); digital pages stay unchanged. Off: only PDFs that consist entirely of scans are processed. Default: on.")
                Toggle("Leave photo pages unchanged", isOn: $profile.skipPhotos)
                    .help("MRC visibly degrades photos, so pages recognized as photos stay unchanged. Default: on.")
                TextField("Text check below paper area (%)", value: $profile.photoPaperPercent,
                          format: .number.precision(.fractionLength(0...1)))
                    .disabled(!profile.skipPhotos)
                    .help("Pages with less paper area than this (photos, but also text on colored backgrounds) only count as documents if enough text is recognized. Measured: documents on white paper 61–98 %, photos 11–43 %. Default: 50.")
                TextField("Photo below confident words", value: $profile.photoMinWords, format: .number)
                    .disabled(!profile.skipPhotos)
                    .help("A page checked by text recognition counts as a photo if fewer words than this are recognized with high confidence (words with at least 3 characters). Default: 10.")
                Toggle("Rasterize vectorized scans and make them searchable", isOn: $profile.vectorPages)
                    .help("Some scanner software stores pages as thousands of vector elements instead of an image. Such pages (no image, no text) are rasterized, compressed and made searchable. Default: on.")
                TextField("Vectorized from elements", value: $profile.vectorMinItems, format: .number)
                    .disabled(!profile.vectorPages)
                    .help("A page without image and text counts as a vectorized scan from this many lines and curves. Default: 1000.")
                Picker("Raster resolution", selection: $profile.vectorDpi) {
                    Text(verbatim: "200 dpi").tag(200)
                    Text("300 dpi (default)").tag(300)
                    Text(verbatim: "400 dpi").tag(400)
                    Text(verbatim: "600 dpi").tag(600)
                }
                .disabled(!profile.vectorPages)
                .help("Resolution at which vectorized scans are rasterized. Default: 300 dpi.")
            }
            Section("Text recognition") {
                Toggle("Keep existing text layer", isOn: $profile.keepTextLayer)
                    .help("Keeps an existing text layer (e.g. from the scanner) instead of recognizing the text again. Off: always recognize with Tesseract – pages are then also rotated and deskewed. Default: on.")
                TextField("Languages", text: $profile.languages, prompt: Text(verbatim: "deu+eng"))
                    .help("Tesseract language codes joined with +, e.g. deu+eng+fra. German and English are included; missing languages can be downloaded here. Default: deu+eng.")
                if Languages.isManaged {
                    LanguageStatus(spec: profile.languages)
                }
                Toggle("Rotate pages automatically", isOn: $profile.rotate)
                    .help("Turns pages that are upside down or sideways the right way up. Only pages without a kept text layer. Default: on.")
                TextField("Minimum rotation confidence", value: $profile.rotateThreshold,
                          format: .number.precision(.fractionLength(0...1)))
                    .disabled(!profile.rotate)
                    .help("Confidence of Tesseract’s orientation detection required before a page is rotated. Higher = rotates less often. Default: 12.")
                Toggle("Deskew", isOn: $profile.deskew)
                    .help("Straightens slightly skewed scans. Only pages without a kept text layer. Default: on.")
                TextField("Minimum skew (degrees)", value: $profile.deskewMinAngle,
                          format: .number.precision(.fractionLength(0...2)))
                    .disabled(!profile.deskew)
                    .help("Smaller skews are left as they are. Default: 0.2.")
                TextField("Search range ± (degrees)", value: $profile.deskewMaxAngle,
                          format: .number.precision(.fractionLength(0...1)))
                    .disabled(!profile.deskew)
                    .help("Skew angles are searched within this range. A result at the edge of the range counts as ambiguous (e.g. a page without lines of text) and is not corrected. Default: 5.")
                TextField("Minimum skew clarity", value: $profile.deskewConfidence,
                          format: .number.precision(.fractionLength(0...2)))
                    .disabled(!profile.deskew)
                    .help("Only deskews if the best angle clearly stands out (factor over the median of all angles tested). Prevents logos or stamps on pages with little text from tilting a straight page. Default: 1.3.")
            }
            Section("Blank pages") {
                Toggle("Remove blank scanned pages", isOn: $profile.removeBlank)
                    .help("Removes scanned pages without content, e.g. empty back sides from duplex scanning. Digital pages are never removed. Default: on.")
                TextField("Blank below ink share (%)", value: $profile.blankInkPercent,
                          format: .number.precision(.fractionLength(0...4)))
                    .disabled(!profile.removeBlank)
                    .help("A page counts as blank if less than this share of its area is ink. A page with only a page number is about 0.05 %. Default: 0.005.")
                TextField("Minimum paper area for blank (%)", value: $profile.blankPaperPercent,
                          format: .number.precision(.fractionLength(0...1)))
                    .disabled(!profile.removeBlank)
                    .help("A page only counts as blank if at least this share of it is paper. Protects low-contrast photos (e.g. of a wall) from being removed as blank. Default: 90.")
            }
            Section("Quality and size") {
                Picker("Background resolution", selection: $profile.bgDownsample) {
                    Text("Full").tag(1)
                    Text("1/2 (default)").tag(2)
                    Text(verbatim: "1/3").tag(3)
                    Text(verbatim: "1/4").tag(4)
                }
                .help("Resolution of the background layer (paper, colored areas, pictures) relative to the scan. Text and lines always stay at full resolution. Default: 1/2.")
                LabeledContent(L("Compression rate: %lld", Int(profile.bgRate))) {
                    Slider(value: $profile.bgRate, in: 50...800, step: 25)
                }
                .help("JPEG 2000 compression of the background layer. Higher = smaller file; colored areas and light-gray text suffer. Default: 200.")
                Toggle("Correct wrong page sizes to A4", isOn: $profile.fitA4)
                    .help("Scales scanned pages with implausible page sizes (e.g. phone scans stored as 61 × 86 cm) to A4, so they display and print at a normal size. Default: on.")
                Picker("Maximum resolution", selection: $profile.maxDpi) {
                    Text("Off (default)").tag(0)
                    Text(verbatim: "200 dpi").tag(200)
                    Text(verbatim: "300 dpi").tag(300)
                    Text(verbatim: "400 dpi").tag(400)
                }
                .help("Downscales scans with a higher resolution before compressing: faster and smaller, but the finest details are lost. Default: off.")
                LabeledContent(profile.sharpen == 0 ? L("Sharpening: off") : L("Sharpening: %lld %%", profile.sharpen)) {
                    Slider(value: Binding(get: { Double(profile.sharpen) }, set: { profile.sharpen = Int($0) }),
                           in: 0...300, step: 25)
                }
                .help("Sharpens before compressing so that light-gray, thin text stays crisp. 0 = off. Default: 150 %.")
                TextField("Sharpening radius (px at 200 dpi)", value: $profile.sharpenRadius,
                          format: .number.precision(.fractionLength(0...1)))
                    .disabled(profile.sharpen == 0)
                    .help("Radius of the sharpening in pixels at 200 dpi; scaled with the resolution of the scan. Default: 1.5.")
                LabeledContent(L("Text mask factor: %.2f", profile.maskFactor)) {
                    Slider(value: $profile.maskFactor, in: 0.1...1.0, step: 0.05)
                }
                .help("Decides which pixels go into the sharp text layer. Smaller = light-gray text also stays sharp, but more specks. 1 = recode_pdf default. Default: 0.5.")
                Stepper(profile.jobs == 0 ? L("Simultaneous pages: automatic") : L("Simultaneous pages: %lld", profile.jobs),
                        value: $profile.jobs, in: 0...16)
                    .help("Number of pages processed at the same time. Automatic = number of processor cores.")
            }
            Section("Output") {
                Picker("Result", selection: $profile.output) {
                    Text("Save as a copy next to the original").tag(OutputMode.copy)
                    Text("Replace the original (original goes to the Trash)").tag(OutputMode.replace)
                }
                .pickerStyle(.radioGroup)
                .help("A result is only saved if it was verified and is smaller. Otherwise no file is created and the original stays unchanged; an existing copy is not overwritten. Default: copy.")
                if profile.output == .copy {
                    TextField("File name suffix", text: $profile.suffix)
                        .help("Added to the file name of the copy, e.g. “Invoice (compressed).pdf”.")
                }
            }
            Section {
                Button("Restore defaults") { profile = Profile() }
                    .help("Resets all settings in this tab to their defaults.")
            }
        }
        .formStyle(.grouped)
    }
}
