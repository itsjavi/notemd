import AppKit
import SwiftUI

extension View {
    /// Shows `menu` when the user right-clicks (or Control-clicks) empty space in the List this modifies,
    /// below or between its rows. Rows keep their own menus.
    ///
    /// `contextMenu(forSelectionType:)` is documented to call its menu with an empty selection for clicks on
    /// empty space, but on macOS 26 a real right-click there shows nothing (only rows get menus). So the click
    /// is caught before it reaches the List's outline view and the menu is shown from AppKit, built from the
    /// same SwiftUI view through `NSHostingMenu`.
    func listBackgroundContextMenu<MenuContent: View>(@ViewBuilder _ menu: @escaping () -> MenuContent) -> some View {
        background(ListBackgroundMenuAnchor(menu: { AnyView(menu()) }))
    }
}

/// An invisible view covering the List that watches its window's right-clicks.
private struct ListBackgroundMenuAnchor: NSViewRepresentable {
    let menu: () -> AnyView

    func makeNSView(context: Context) -> AnchorView { AnchorView() }

    func updateNSView(_ view: AnchorView, context: Context) {
        view.menuContent = menu
    }

    static func dismantleNSView(_ view: AnchorView, coordinator: ()) {
        view.stopMonitoring()
    }

    final class AnchorView: NSView {
        var menuContent: (() -> AnyView)?
        private var monitor: Any?

        /// Never takes clicks itself: the List above it gets them.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil {
                stopMonitoring()
            } else if monitor == nil {
                monitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown]) { [weak self] event in
                    guard let self, self.showMenu(for: event) else { return event }
                    return nil
                }
            }
        }

        func stopMonitoring() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        /// Shows the menu when `event` is a context click on empty space of the table under this view.
        private func showMenu(for event: NSEvent) -> Bool {
            if event.type == .leftMouseDown && !event.modifierFlags.contains(.control) { return false }
            guard let window, event.window === window, !isHiddenOrHasHiddenAncestor, let menuContent,
                  bounds.contains(convert(event.locationInWindow, from: nil)),
                  let table = tableView(at: event.locationInWindow, in: window),
                  table.row(at: table.convert(event.locationInWindow, from: nil)) == -1
            else { return false }
            let menu = NSHostingMenu(rootView: menuContent())
            NSMenu.popUpContextMenu(menu, with: event, for: table)
            return true
        }

        /// The table (SwiftUI Lists are outline views) whose empty space or row is at `point`.
        private func tableView(at point: NSPoint, in window: NSWindow) -> NSTableView? {
            guard let root = window.contentView,
                  let hit = root.hitTest(root.superview?.convert(point, from: nil) ?? point)
            else { return nil }
            for view in sequence(first: hit, next: \.superview) {
                if let table = view as? NSTableView { return table }
                if let scrollView = view as? NSScrollView { return scrollView.documentView as? NSTableView }
            }
            return nil
        }
    }
}
