// SPDX-License-Identifier: AGPL-3.0-or-later
import SwiftUI

/// Beschriftung einer Option mit ⓘ dahinter. Die Erklärung erscheint sofort beim Darüberfahren (der Tooltip von
/// macOS, .help, kommt nur verzögert) und auch per Klick (Trackpad, Bedienungshilfen).
struct TipLabel: View {
    private let title: Text
    private let tip: LocalizedStringKey

    init(_ title: LocalizedStringKey, tip: LocalizedStringKey) {
        self.title = Text(title)
        self.tip = tip
    }

    init(verbatim title: String, tip: LocalizedStringKey) {
        self.title = Text(verbatim: title)
        self.tip = tip
    }

    var body: some View {
        HStack(spacing: 5) {
            title
            InfoTip(tip)
        }
    }
}

/// Das ⓘ allein (z. B. hinter einer Abschnittsüberschrift).
struct InfoTip: View {
    private let tip: LocalizedStringKey
    @State private var hovering = false
    @State private var pinned = false

    init(_ tip: LocalizedStringKey) {
        self.tip = tip
    }

    var body: some View {
        Image(systemName: "questionmark.circle")
            .imageScale(.small)
            .foregroundStyle(hovering || pinned ? Color.accentColor : Color.secondary)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .onTapGesture { pinned.toggle() }
            .popover(isPresented: Binding(get: { hovering || pinned },
                                          set: { if !$0 { hovering = false; pinned = false } }),
                     arrowEdge: .trailing) {
                Text(tip)
                    .font(.callout)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: 300, alignment: .leading)
                    .padding(12)
            }
            .accessibilityLabel(Text(tip))
            .accessibilityAddTraits(.isButton)
    }
}
