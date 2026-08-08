import AppKit
import SwiftUI

// Fork-owned (Focus UI). A minimal notes-first window, opened from the menu bar icon
// when focus_ui_enabled is set in fork-config.json. The full dashboard stays available
// via the right-click menu's "Open Muesli" and from inside this window.

@MainActor
final class FocusWindowController: NSObject, NSWindowDelegate {
    private let controller: MuesliController
    private var window: NSWindow?

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
    private static var focusWindowControllers: [ObjectIdentifier: FocusWindowController] = [:]

    @MainActor
    func openFocusWindow() {
        let key = ObjectIdentifier(self)
        let windowController = Self.focusWindowControllers[key] ?? {
            let created = FocusWindowController(controller: self)
            Self.focusWindowControllers[key] = created
            return created
        }()
        windowController.show()
    }
}
