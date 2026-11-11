import CoreGraphics
import Foundation

/// The key and modifiers the global shortcut is bound to, and the test a key
/// press is put through.
struct HotkeyBinding: Equatable {
    var keyCode: Int64
    var modifiers: CGEventFlags

    /// Caps lock, fn and the keypad flag ride along on real events and must
    /// not stop a match, so only these four are compared.
    static let relevant: CGEventFlags = [.maskCommand, .maskControl, .maskShift, .maskAlternate]

    /// A cleared shortcut is stored as key code 0 with no modifiers, and **key
    /// code 0 is the letter A**. Without this test a bare A would match it
    /// (0 == 0, and an empty flag set equals an empty flag set), toggle the pin
    /// and be swallowed.
    var isSet: Bool { keyCode != 0 || !modifiers.intersection(Self.relevant).isEmpty }

    enum Match {
        /// Not the shortcut: the key press goes on to the focused app.
        case none
        /// The shortcut: run the action and keep the key press from the app.
        case fire
        /// The shortcut held down. Keep the repeats from the app, but do not
        /// run the action again, or holding the keys a moment too long pins
        /// and unpins the window several times.
        case swallow
    }

    func match(keyCode: Int64, flags: CGEventFlags, isRepeat: Bool) -> Match {
        guard isSet, keyCode == self.keyCode,
              flags.intersection(Self.relevant) == modifiers.intersection(Self.relevant) else { return .none }
        return isRepeat ? .swallow : .fire
    }
}

/// The global shortcut, as an event tap on a thread of its own.
///
/// The tap is an active one: every key press in the system waits for its
/// callback to return. On the main run loop that meant every key press waited
/// on whatever the main thread was doing, and WindowPin's main thread makes
/// Accessibility calls that can block for up to a second each on an app that
/// has hung. With a thread of its own the callback only compares a few
/// integers, so nothing WindowPin does can hold up typing.
final class HotkeyTap {

    static let shared = HotkeyTap()

    /// Run on the main thread when the shortcut is pressed. Set once, before
    /// `install()`.
    var action: (() -> Void)?

    private let lock = NSLock()
    // Everything below is guarded by `lock`: the tap's thread reads it.
    private var port: CFMachPort?
    private var runLoop: CFRunLoop?
    private var currentBinding = HotkeyBinding(keyCode: 35, modifiers: [.maskCommand, .maskControl])
    private var suspended = false

    var binding: HotkeyBinding {
        get { lock.withLock { currentBinding } }
        set { lock.withLock { currentBinding = newValue } }
    }

    /// While suspended every key press passes straight through, so the
    /// shortcut recorder can be given the shortcut that is already set. The
    /// tap itself stays enabled, which leaves "the tap is disabled" meaning
    /// only one thing: the system switched it off.
    var isSuspended: Bool {
        get { lock.withLock { suspended } }
        set { lock.withLock { suspended = newValue } }
    }

    var isInstalled: Bool { lock.withLock { port != nil } }

    /// Create the tap and start its thread. Fails without Accessibility.
    func install() -> Bool {
        if isInstalled { return true }

        // Tap location & position chosen to play nicely with keystroke
        // rewriters like HyperKey and Karabiner-Elements that synthesise
        // "Hyper" (shift+ctrl+opt+cmd) from a single physical key. At
        // .cgSessionEventTap with .headInsertEventTap we'd see the raw
        // event (e.g. Caps Lock + key) before the rewriter transforms
        // it, never matching the user's Hyper-bound shortcut.
        // .cgAnnotatedSessionEventTap is the latest tap layer — after
        // HID-level and session-level rewriters — and .tailAppendEventTap
        // runs us last in our level's chain. Real-modifier bindings
        // (cmd+opt+arrows etc.) keep working because they don't need a
        // rewriter; only Hyper-derived shortcuts ever depended on the
        // rewriter running first.
        guard let tap = CGEvent.tapCreate(
            tap: .cgAnnotatedSessionEventTap,
            place: .tailAppendEventTap,
            options: .defaultTap,
            eventsOfInterest: 1 << CGEventType.keyDown.rawValue,
            callback: hotkeyTapCallback,
            userInfo: nil
        ) else { return false }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        let ready = DispatchSemaphore(value: 0)
        var threadLoop: CFRunLoop?
        let thread = Thread {
            threadLoop = CFRunLoopGetCurrent()
            CFRunLoopAddSource(threadLoop, source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            ready.signal()
            CFRunLoopRun()
        }
        thread.name = "WindowPin hotkey tap"
        thread.qualityOfService = .userInteractive
        thread.start()
        // Wait for the run loop to exist, so `uninstall()` always has one to stop.
        ready.wait()

        lock.withLock {
            port = tap
            runLoop = threadLoop
        }
        return true
    }

    /// Remove the tap and end its thread.
    func uninstall() {
        let (tap, loop): (CFMachPort?, CFRunLoop?) = lock.withLock {
            defer { port = nil; runLoop = nil }
            return (port, runLoop)
        }
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let loop { CFRunLoopStop(loop) }
    }

    /// Whether the installed tap can still deliver key presses.
    ///
    /// Revoking Accessibility, or removing and re-adding the app in System
    /// Settings, leaves a tap that is invalid or that the system has switched
    /// off and will not switch back on. Neither announces itself. A tap that
    /// is merely off is given one chance to come back first.
    var isHealthy: Bool {
        guard let tap = lock.withLock({ port }) else { return false }
        guard CFMachPortIsValid(tap) else { return false }
        if !CGEvent.tapIsEnabled(tap: tap) {
            CGEvent.tapEnable(tap: tap, enable: true)
            return CGEvent.tapIsEnabled(tap: tap)
        }
        return true
    }

    /// Runs on the tap's thread, for every key press in the system. Keep it to
    /// a lock and a comparison.
    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let (tap, binding, suspended) = lock.withLock { (port, currentBinding, self.suspended) }

        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard type == .keyDown, !suspended else { return Unmanaged.passUnretained(event) }

        switch binding.match(keyCode: event.getIntegerValueField(.keyboardEventKeycode),
                             flags: event.flags,
                             isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0) {
        case .none:
            return Unmanaged.passUnretained(event)
        case .swallow:
            return nil
        case .fire:
            DispatchQueue.main.async { [weak self] in self?.action?() }
            return nil
        }
    }
}

/// The tap's callback must be a C function, so it only hands over.
private func hotkeyTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    HotkeyTap.shared.handle(type: type, event: event)
}
