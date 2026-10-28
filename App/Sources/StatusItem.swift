// SPDX-License-Identifier: AGPL-3.0-or-later
import AppKit
import SwiftUI

/// Symbol in der Menüleiste, solange Aufträge laufen; ein Klick zeigt Fortschritt und letzte Ergebnisse (JobsMenu).
@MainActor
final class StatusItem: NSObject {
    static let shared = StatusItem()
    private var item: NSStatusItem?
    private let popover = NSPopover()

    func setVisible(_ visible: Bool) {
        if visible, item == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            item.button?.target = self
            item.button?.action = #selector(toggle(_:))
            self.item = item
            setBusy(true)
        } else if !visible, let item {
            closePopover()
            NSStatusBar.system.removeStatusItem(item)
            self.item = nil
        }
    }

    func setBusy(_ busy: Bool) {
        let image = NSImage(systemSymbolName: busy ? "doc.zipper" : "checkmark.circle",
                            accessibilityDescription: "PDF MRC")
        image?.isTemplate = true
        item?.button?.image = image
    }

    func closePopover() {
        if popover.isShown { popover.performClose(nil) }
    }

    @objc private func toggle(_ sender: Any?) {
        guard let button = item?.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.behavior = .transient
            popover.contentViewController = NSHostingController(rootView: JobsMenu())
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}
