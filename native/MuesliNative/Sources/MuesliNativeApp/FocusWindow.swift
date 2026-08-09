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
        // Narrow enough to live as a strip down the edge of the screen.
        window.minSize = NSSize(width: 280, height: 420)
        window.isReleasedWhenClosed = false
        window.center()
        window.delegate = self
        window.level = Self.isPinned ? .floating : .normal
        self.window = window
    }

    // MARK: - Pin (always on top)

    private static let pinnedDefaultsKey = "fork.focus.windowPinned"

    static var isPinned: Bool {
        UserDefaults.standard.bool(forKey: pinnedDefaultsKey)
    }

    func setPinned(_ pinned: Bool) {
        UserDefaults.standard.set(pinned, forKey: Self.pinnedDefaultsKey)
        window?.level = pinned ? .floating : .normal
    }
}

// Zero-edit hook: MuesliController gains the focus window without touching its own
// (upstream) file, keeping the daily merge conflict-light.
extension MuesliController {
    // One shared instance, not a registry: the app has exactly one MuesliController for the
    // life of the process. If a second controller ever calls this, last-one-wins — the stale
    // window controller (and its retained controller) is released rather than leaked.
    private static var sharedFocusWindowController: FocusWindowController?

    /// Dev affordance for headless visual QA: MUESLI_OPEN_FOCUS=1 opens the Focus window at
    /// launch, and MUESLI_FOCUS_SELECT=<meetingID> opens it straight onto that note. No-ops
    /// unless the env vars are set, so normal launches are unaffected.
    @MainActor
    func openFocusWindowAtLaunchIfRequested() {
        guard ProcessInfo.processInfo.environment["MUESLI_OPEN_FOCUS"] == "1" else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.openFocusWindow()
        }
    }

    @MainActor
    var isFocusWindowPinned: Bool { FocusWindowController.isPinned }

    @MainActor
    func setFocusWindowPinned(_ pinned: Bool) {
        Self.sharedFocusWindowController?.setPinned(pinned)
        // Persist even if the window hasn't been built yet this launch.
        if Self.sharedFocusWindowController == nil {
            UserDefaults.standard.set(pinned, forKey: "fork.focus.windowPinned")
        }
    }

    @MainActor
    @objc func openFocusWindow() {
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
