import AppKit

/// Keyboard-focus wiring for Muesli (see KeyablePanel.swift). Muesli is an accessory app that flips to
/// `.regular` while a dashboard window is open and activates for onboarding, Settings and Sparkle.
/// Closing those windows must not leave it the active app with nothing to type into.
@MainActor
enum MuesliFocus {
    private static var installed = false
    /// Menu windows cannot become key, so an open menu looks idle; a hand-back then would close it.
    private static var menuTracking = false

    static func install() {
        guard !installed else { return }
        installed = true
        FocusKit.log = { NSLog("Muesli: %@", $0) }
        FocusKit.install()
        FocusKit.installEditKeyMonitor()
        // FocusKit hands back only when no window here could take the keyboard. The always-visible
        // dictation indicator panel can become key, so that check never passes while it is up. When the
        // window the user was typing in closes and only panels remain, hand activation back explicitly.
        NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { menuTracking = true }
        }
        NotificationCenter.default.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { menuTracking = false }
        }
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { n in
            MainActor.assumeIsolated {
                guard let closing = n.object as? NSWindow, closing.isKeyWindow, !(closing is NSPanel) else { return }
                handBackIfOnlyPanelsRemain()
            }
        }
    }

    /// Once the closing window is gone: next run-loop pass, then again after 0.35 s (as FocusKit does),
    /// in case the close animation or a follow-up window had not settled yet.
    private static func handBackIfOnlyPanelsRemain() {
        for delay in [0.0, 0.35] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                MainActor.assumeIsolated {
                    guard !menuTracking, NSApp.isActive, NSApp.keyWindow == nil, NSApp.modalWindow == nil,
                          !NSApp.windows.contains(where: { $0.isVisible && $0.isOnActiveSpace && $0.canBecomeKey && !($0 is NSPanel) })
                    else { return }
                    FocusKit.handBack()
                }
            }
        }
    }
}
