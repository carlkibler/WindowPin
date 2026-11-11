import CoreGraphics
import XCTest
@testable import WindowPin

/// The test every key press in the system is put through.
final class HotkeyBindingTests: XCTestCase {

    private let controlCommandP = HotkeyBinding(keyCode: 35, modifiers: [.maskControl, .maskCommand])

    func testShortcutFires() {
        XCTAssertEqual(controlCommandP.match(keyCode: 35, flags: [.maskControl, .maskCommand], isRepeat: false), .fire)
    }

    func testHeldShortcutIsSwallowedButDoesNotFireAgain() {
        XCTAssertEqual(controlCommandP.match(keyCode: 35, flags: [.maskControl, .maskCommand], isRepeat: true), .swallow)
    }

    func testOtherKeysAndOtherModifiersPassThrough() {
        XCTAssertEqual(controlCommandP.match(keyCode: 36, flags: [.maskControl, .maskCommand], isRepeat: false), .none)
        XCTAssertEqual(controlCommandP.match(keyCode: 35, flags: [.maskCommand], isRepeat: false), .none)
        XCTAssertEqual(controlCommandP.match(keyCode: 35, flags: [.maskControl, .maskCommand, .maskShift], isRepeat: false), .none)
        XCTAssertEqual(controlCommandP.match(keyCode: 35, flags: [], isRepeat: false), .none)
    }

    func testCapsLockFnAndKeypadFlagsDoNotStopAMatch() {
        let flags: CGEventFlags = [.maskControl, .maskCommand, .maskAlphaShift, .maskSecondaryFn, .maskNumericPad]
        XCTAssertEqual(controlCommandP.match(keyCode: 35, flags: flags, isRepeat: false), .fire)
    }

    func testClearedShortcutNeverMatchesTheLetterA() {
        // Key code 0 is the letter A, and a cleared shortcut is stored as key
        // code 0 with no modifiers.
        let cleared = HotkeyBinding(keyCode: 0, modifiers: [])
        XCTAssertFalse(cleared.isSet)
        XCTAssertEqual(cleared.match(keyCode: 0, flags: [], isRepeat: false), .none)
    }

    func testCommandAIsARealShortcut() {
        let commandA = HotkeyBinding(keyCode: 0, modifiers: [.maskCommand])
        XCTAssertTrue(commandA.isSet)
        XCTAssertEqual(commandA.match(keyCode: 0, flags: [.maskCommand], isRepeat: false), .fire)
        XCTAssertEqual(commandA.match(keyCode: 0, flags: [], isRepeat: false), .none)
    }

    func testBareFunctionKeyIsARealShortcut() {
        let f5 = HotkeyBinding(keyCode: 96, modifiers: [])
        XCTAssertTrue(f5.isSet)
        XCTAssertEqual(f5.match(keyCode: 96, flags: [.maskSecondaryFn], isRepeat: false), .fire)
        XCTAssertEqual(f5.match(keyCode: 96, flags: [.maskCommand], isRepeat: false), .none)
    }
}
