import AppKit

/// Picks the window an open/save panel should attach to as a sheet.
///
/// `NSApp.keyWindow` right after `NSApp.activate()` can be the borderless floating indicator (a dot that
/// would show the sheet attached to nothing visible, then strand the keyboard). Windows that
/// `FocusKit.ignoredForIdle` rejects are skipped, as are hidden, minimised and sheet windows; the next
/// suitable window is used, and `nil` means the caller should run the panel standalone with `panel.begin`.
enum SheetParent {
    @MainActor static func isSuitable(_ window: NSWindow) -> Bool {
        window.isVisible && !window.isMiniaturized && window.sheetParent == nil && !FocusKit.ignoredForIdle(window)
    }

    /// First suitable window in `candidates`, in order.
    @MainActor static func pick(from candidates: [NSWindow?]) -> NSWindow? {
        candidates.lazy.compactMap { $0 }.first(where: isSuitable)
    }

    /// Key window, then main window, then any other visible window that can be main. Callers are on the main
    /// thread already (they present AppKit panels), so this is callable from non-isolated closures.
    static func current() -> NSWindow? {
        MainActor.assumeIsolated {
            pick(from: [NSApp.keyWindow, NSApp.mainWindow] + NSApp.orderedWindows.filter(\.canBecomeMain))
        }
    }
}
