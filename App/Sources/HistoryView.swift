// SPDX-License-Identifier: AGPL-3.0-or-later
import AppKit
import SwiftUI

extension HistoryEntry.Status {
    var symbol: String {
        switch self {
        case .done: return "checkmark.circle.fill"
        case .unchanged: return "minus.circle.fill"
        case .failed: return "xmark.octagon.fill"
        case .pending: return "clock.fill"
        }
    }

    var color: Color {
        switch self {
        case .done: return .green
        case .unchanged: return .secondary
        case .failed: return .red
        case .pending: return .orange
        }
    }
}

extension HistoryEntry.Timing {
    var title: String {
        switch step {
        case "compress": return L("Compression")
        case "upload": return L("Upload")
        case "paperless": return L("Paperless processing")
        default: return step
        }
    }
}

/// Verlauf der App; lädt neu, wenn ein anderer Prozess (Kontextmenü) einen Eintrag schreibt.
@MainActor
final class HistoryStore: ObservableObject {
    @Published private(set) var entries = History.load()

    init() {
        // Beobachter lebt mit der App (schwacher Verweis, kein Aufräumen nötig)
        _ = DistributedNotificationCenter.default().addObserver(forName: History.changed, object: nil,
                                                                queue: .main) { [weak self] _ in
            Task { @MainActor in self?.entries = History.load() }
        }
    }
}

struct HistoryView: View {
    @StateObject private var store = HistoryStore()
    @State private var selection: HistoryEntry.ID?
    @State private var confirmClear = false

    private var selected: HistoryEntry? {
        store.entries.first { $0.id == selection } ?? store.entries.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if store.entries.isEmpty {
                Spacer()
                Text("No conversions yet. Converted and sent PDFs appear here, with the full log.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                Table(store.entries, selection: $selection) {
                    TableColumn("Date") { entry in
                        Text(entry.date.formatted(date: .numeric, time: .shortened))
                    }
                    .width(min: 110, ideal: 120)
                    TableColumn("File") { entry in
                        Label {
                            Text(entry.fileName).lineLimit(1).truncationMode(.middle)
                        } icon: {
                            Image(systemName: entry.status.symbol).foregroundStyle(entry.status.color)
                        }
                    }
                    .width(min: 140, ideal: 200)
                    TableColumn("Action") { entry in
                        Text(entry.kind.title).lineLimit(1)
                    }
                    .width(min: 100, ideal: 150)
                }
                .frame(minHeight: 150, idealHeight: 220)
                if let entry = selected {
                    HistoryDetail(entry: entry)
                }
            }
            HStack {
                Text(L("The last %lld conversions are kept.", History.limit))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Clear History…") { confirmClear = true }
                    .disabled(store.entries.isEmpty)
                    .help("Removes all entries from the history. Converted files are not affected.")
            }
        }
        .confirmationDialog("Clear the history?", isPresented: $confirmClear) {
            Button("Clear History", role: .destructive) { History.clear() }
        }
    }
}

/// Details eines Eintrags: Ergebnis, Größen, Zeiten und das Protokoll von paperless-mrc (mit Seitendetails).
struct HistoryDetail: View {
    let entry: HistoryEntry

    private func size(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    private var sizes: String? {
        guard let before = entry.sizeBefore else { return nil }
        guard let after = entry.sizeAfter else { return size(before) }
        let saving = before > 0 ? Int((1 - Double(after) / Double(before)) * 100) : 0
        return L("%@ → %@ (−%lld %%)", size(before), size(after), saving)
    }

    private var timings: String? {
        guard !entry.timings.isEmpty else { return nil }
        return entry.timings.map { "\($0.title) \(String(format: "%.1f", $0.seconds)) s" }.joined(separator: " · ")
    }

    private var file: URL? {
        [entry.output, entry.source].compactMap { $0 }.map { URL(fileURLWithPath: $0) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                Image(systemName: entry.status.symbol).foregroundStyle(entry.status.color)
                Text(entry.message).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            .font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                GridRow {
                    Text("File").foregroundStyle(.secondary)
                    Text(entry.output ?? entry.source).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                }
                if let sizes {
                    GridRow {
                        Text("Size").foregroundStyle(.secondary)
                        Text(sizes)
                    }
                }
                if let pages = entry.pages {
                    GridRow {
                        Text("Pages").foregroundStyle(.secondary)
                        Text(verbatim: "\(pages)")
                    }
                }
                if let timings {
                    GridRow {
                        Text("Duration").foregroundStyle(.secondary)
                        Text(timings)
                    }
                }
            }
            .font(.callout)
            HStack {
                if let file {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file]) }
                }
                if let link = entry.paperlessLink {
                    Button("Open in Paperless") { NSWorkspace.shared.open(link) }
                }
                Spacer()
                if !entry.log.isEmpty {
                    Button("Copy Log") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(entry.log, forType: .string)
                    }
                    .help("Copies the full log of this conversion to the clipboard.")
                }
            }
            Text("Log").font(.subheadline).bold()
            ScrollView {
                Text(entry.log.isEmpty ? L("No log – the file was not processed by paperless-mrc on this Mac.") : entry.log)
                    .font(.caption.monospaced())
                    .foregroundStyle(entry.log.isEmpty ? .secondary : .primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.3)))
            .frame(minHeight: 120)
        }
    }
}
