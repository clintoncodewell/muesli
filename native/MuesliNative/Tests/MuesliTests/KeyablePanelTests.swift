import AppKit
import Testing
@testable import MuesliNativeApp

// Muesli's windows and panels must handle the edit shortcuts themselves, because an accessory app can be
// inactive or lack a matching menu item (the user hears a ding). The key map is the pure half of that.
@Suite("KeyablePanelTests")
struct KeyablePanelTests {
    private func sel(_ k: String, _ m: NSEvent.ModifierFlags) -> String? {
        FocusKit.editSelector(key: k, modifiers: m).map { NSStringFromSelector($0) }
    }

    @Test("command keys map to edit actions")
    func commandKeysMapToEditActions() {
        #expect(sel("x", .command) == "cut:")
        #expect(sel("c", .command) == "copy:")
        #expect(sel("v", .command) == "paste:")
        #expect(sel("a", .command) == "selectAll:")
        #expect(sel("z", .command) == "undo:")
    }

    @Test("caps lock and fn do not stop command keys")
    func capsLockAndFnDoNotStopCommandKeys() {
        #expect(sel("c", [.command, .capsLock]) == "copy:")
        #expect(sel("c", [.command, .function]) == "copy:")
        #expect(sel("z", [.command, .shift, .capsLock]) == "redo:")
        #expect(sel("v", [.command, .shift, .capsLock]) == nil)
    }

    @Test("shift-command-Z is redo")
    func shiftCommandZIsRedo() {
        #expect(sel("Z", [.command, .shift]) == "redo:")
        #expect(sel("z", [.command, .shift]) == "redo:")
    }

    @Test("shift-command-V is not paste")
    func shiftCommandVIsNotPaste() {
        #expect(sel("v", [.command, .shift]) == nil)
        #expect(sel("c", [.command, .shift]) == nil)
        #expect(sel("x", [.command, .shift]) == nil)
        #expect(sel("a", [.command, .shift]) == nil)
    }

    @Test("option-command-C is not copy")
    func optionCommandCIsNotCopy() {
        #expect(sel("c", [.command, .option]) == nil)
        #expect(sel("z", [.command, .option]) == nil)
    }

    @Test("other combos are ignored")
    func otherCombosAreIgnored() {
        #expect(sel("v", []) == nil)
        #expect(sel("v", [.command, .option]) == nil)
        #expect(sel("v", .control) == nil)
        #expect(sel("q", .command) == nil)
        #expect(sel("z", [.command, .control]) == nil)
    }

    // The hook is how an always-visible indicator opts out of FocusKit's idle check; the default must
    // not exempt any window.
    @MainActor
    @Test("ignoredForIdle defaults to false for a plain window")
    func ignoredForIdleDefaultsToFalse() {
        #expect(FocusKit.ignoredForIdle(NSWindow()) == false)
    }
}

// A save/open sheet must never attach to the borderless indicator: the helper skips windows that
// `FocusKit.ignoredForIdle` rejects and falls through to the next suitable window, else nil (`panel.begin`).
@MainActor
@Suite("SheetParentTests")
struct SheetParentTests {
    private func shownWindow() -> NSWindow {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 80, height: 60),
                         styleMask: [.titled], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.orderFrontRegardless()
        return w
    }

    @Test("a hidden window is not a sheet parent")
    func hiddenWindowIsSkipped() {
        let w = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        #expect(SheetParent.pick(from: [w]) == nil)
        #expect(SheetParent.pick(from: [nil]) == nil)
    }

    @Test("an ignored window is skipped in favour of the next suitable one")
    func ignoredWindowIsSkipped() {
        let indicator = shownWindow()
        let content = shownWindow()
        defer { indicator.close(); content.close(); FocusKit.ignoredForIdle = { _ in false } }
        FocusKit.ignoredForIdle = { $0 === indicator }
        #expect(SheetParent.pick(from: [indicator, content]) === content)
        #expect(SheetParent.pick(from: [indicator]) == nil)
        FocusKit.ignoredForIdle = { _ in false }
        #expect(SheetParent.pick(from: [indicator, content]) === indicator)
    }
}
