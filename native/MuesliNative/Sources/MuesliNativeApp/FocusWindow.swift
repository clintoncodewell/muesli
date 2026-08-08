import AppKit
import SwiftUI

// Fork-owned (Focus UI). A minimal notes-first window, opened from the menu bar icon
// when focus_ui_enabled is set in fork-config.json. The full dashboard stays available
// via the right-click menu's "Open Muesli" and from inside this window.

@MainActor
final class FocusWindowController: NSObject, NSWindowDelegate {
    private let controller: MuesliController
    private var window: NSWindow?

    var owner: MuesliController { controller }

    init(controller: MuesliController) {
        self.controller = controller
    }

    func show() {
        if window == nil {
            buildWindow()
        }
        guard let window else { return }
        controller.syncAppState()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    private func buildWindow() {
        let hosting = NSHostingController(
            rootView: FocusRootView(appState: controller.appState, controller: controller)
        )
        let window = NSWindow(contentViewController: hosting)
        window.title = ""
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.setContentSize(NSSize(width: 700, height: 780))
        window.minSize = NSSize(width: 480, height: 480)
        window.isReleasedWhenClosed = false
        window.center()
        window.delegate = self
        self.window = window
    }
}

// Zero-edit hook: MuesliController gains the focus window without touching its own
// (upstream) file, keeping the daily merge conflict-light.
extension MuesliController {
    // One shared instance, not a registry: the app has exactly one MuesliController for the
    // life of the process. If a second controller ever calls this, last-one-wins — the stale
    // window controller (and its retained controller) is released rather than leaked.
    private static var sharedFocusWindowController: FocusWindowController?

    @MainActor
    func openFocusWindow() {
        let windowController: FocusWindowController
        if let existing = Self.sharedFocusWindowController, existing.owner === self {
            windowController = existing
        } else {
            windowController = FocusWindowController(controller: self)
            Self.sharedFocusWindowController = windowController
        }
        windowController.show()
    }
}
