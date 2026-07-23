import AppKit
import SwiftUI

// Fork-owned (Cue coach port). A minimal always-on-top overlay showing the latest SAY + MOVE.
// Deliberately simple v1 (not Cue's full 615-line panel) — proves the loop; polish later.

struct CoachOverlayView: View {
    @ObservedObject var say: CoachCueStore
    @ObservedObject var move: CoachCueStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Circle().fill(say.thinking ? Color.orange : Color.green)
                    .frame(width: 7, height: 7)
                Text("Coach").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            Group {
                Text("SAY").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
                Text(say.latest.isEmpty ? "Listening…" : say.latest)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !move.latest.isEmpty {
                Divider()
                Text("MOVE").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
                Text(move.latest)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(width: 340, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.08)))
    }
}

@MainActor
final class CoachOverlayController {
    private var panel: NSPanel?

    func show(say: CoachCueStore, move: CoachCueStore) {
        guard panel == nil else { return }
        let hosting = NSHostingView(rootView: CoachOverlayView(say: say, move: move))
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 160),
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.contentView = hosting

        // Top-right of the main screen, below the menu bar.
        if let screen = NSScreen.main {
            let vf = screen.visibleFrame
            let size = hosting.fittingSize
            panel.setFrameTopLeftPoint(NSPoint(x: vf.maxX - size.width - 24, y: vf.maxY - 24))
        }
        panel.orderFrontRegardless()
        self.panel = panel
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
    }
}
