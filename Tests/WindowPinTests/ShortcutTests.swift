import AppKit
import XCTest
@testable import WindowPin

/// Pure logic that is reachable without changing Sources/. The crop maths in
/// `WindowOverlay` (`clampedCrop`, the resize handling) is private to an
/// NSPanel subclass and is not covered here.
@MainActor
final class ShortcutTests: XCTestCase {

    func testDefaultShortcutDisplaysAsControlCommandP() {
        // Modifiers are drawn in the macOS order: control, option, shift, command.
        XCTAssertEqual(AppDelegate().shortcutDisplayString(), "⌃⌘P")
    }

    func testModifierOrderIsControlOptionShiftCommand() {
        let delegate = AppDelegate()
        delegate.shortcutModifiers = [.command, .shift, .option, .control]
        delegate.shortcutKeyCode = 49
        XCTAssertEqual(delegate.shortcutDisplayString(), "⌃⌥⇧⌘Space")
    }

    func testClearedShortcutSaysNotSet() {
        let delegate = AppDelegate()
        delegate.shortcutKeyCode = 0
        delegate.shortcutModifiers = []
        XCTAssertEqual(delegate.shortcutDisplayString(), "Not set")
    }

    func testKeyCodeZeroWithModifiersIsTheLetterA() {
        let delegate = AppDelegate()
        delegate.shortcutKeyCode = 0
        delegate.shortcutModifiers = [.command]
        XCTAssertEqual(delegate.shortcutDisplayString(), "⌘A")
    }

    func testBareFunctionKeyDisplays() {
        let delegate = AppDelegate()
        delegate.shortcutKeyCode = 122
        delegate.shortcutModifiers = []
        XCTAssertEqual(delegate.shortcutDisplayString(), "F1")
    }

    func testUnknownKeyCodeIsShownRatherThanDropped() {
        let delegate = AppDelegate()
        delegate.shortcutKeyCode = 200
        delegate.shortcutModifiers = [.command]
        XCTAssertEqual(delegate.shortcutDisplayString(), "⌘?200")
    }

    func testHotkeyRoundTripsThroughJSON() throws {
        let hotkey = JorvikHotkey(actionTitle: "Toggle Pin", keyCode: 35,
                                  modifiers: [.command, .control], activeContext: .anywhere)
        let decoded = try JSONDecoder().decode(JorvikHotkey.self,
                                               from: JSONEncoder().encode(hotkey))
        XCTAssertEqual(decoded, hotkey)
        XCTAssertEqual(NSEvent.ModifierFlags(rawValue: decoded.modifiers), [.command, .control])
    }
}
