import AppKit

/// Small pin buttons in the top-right corner of windows' title bars.
///
/// - On every pinned window, a solid pin: click it to unpin. It follows the
///   floating pin while that is showing, and the real window while you are in
///   its app.
/// - On the window you are working in, a faint pin: click it to pin that window.
///
/// Each badge is WindowPin's own small window, ordered just above the window it
/// belongs to, so anything covering that window covers the badge too. Both
/// kinds can be turned off in Settings.
final class PinBadgeController {

    static let pinnedKey = "badgePinnedWindows"
    static let focusedKey = "badgeFocusedWindow"

    static var showsPinned: Bool { UserDefaults.standard.object(forKey: pinnedKey) as? Bool ?? true }
    static var showsFocused: Bool { UserDefaults.standard.object(forKey: focusedKey) as? Bool ?? true }

    private let tracker: PinnedWindowTracker
    /// Pin or unpin a window, with the same feedback as the shortcut.
    private let toggle: (ForeignWindow) -> Void

    private var pinnedBadges: [UInt32: BadgePanel] = [:]
    private let focusedBadge = BadgePanel(pinned: false)
    private var focusedWindow: ForeignWindow?
    private var timer: Timer?
    private var tick = 0
    /// Ticks left to run at the full rate after something changed. See `update`.
    private var fastTicks = 0
    private var activationObserver: NSObjectProtocol?

    init(tracker: PinnedWindowTracker, toggle: @escaping (ForeignWindow) -> Void) {
        self.tracker = tracker
        self.toggle = toggle
        // Common modes, so it keeps up during a drag.
        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.update() }
        // Nothing here is to the tenth of a second, so let the system line the
        // wake-ups up with others.
        t.tolerance = 0.03
        RunLoop.main.add(t, forMode: .common)
        timer = t
        // Switching apps raises windows and brings pins up or sends them
        // behind, all of which a badge has to follow at once.
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.refresh() }
    }

    deinit {
        timer?.invalidate()
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
    }

    // MARK: - Update

    /// Bring the badges up to date now, and keep them close for the next
    /// second. Called when a window is pinned or unpinned and when the active
    /// app changes; a pin coming up for the first time takes a moment to
    /// appear, and its badge has to land on it when it does.
    func refresh() {
        fastTicks = 10
        updatePinnedBadges()
        updateFocusedBadge()
    }

    /// Ten times a second keeps a badge on a window being dragged, but a
    /// window is only dragged with a mouse button down. The rest of the time
    /// the badges are checked three times a second, which is as often as the
    /// focused window was being read anyway. This runs for as long as
    /// WindowPin does, so two ticks in three now cost next to nothing.
    private func update() {
        tick += 1
        let fast = fastTicks > 0 || NSEvent.pressedMouseButtons != 0
        if fastTicks > 0 { fastTicks -= 1 }
        guard fast || tick % 3 == 0 else { return }
        updatePinnedBadges()
        // Asking the front app for its focused window is an Accessibility call,
        // so do it a few times a second rather than every tick.
        if tick % 3 == 0 { focusedWindow = Self.showsFocused ? Self.focusedForeignWindow() : nil }
        updateFocusedBadge()
    }

    private func updatePinnedBadges() {
        let pinned = Self.showsPinned ? tracker.pinnedWindows : []
        let ids = Set(pinned.map(\.windowID))
        for (id, badge) in pinnedBadges where !ids.contains(id) {
            badge.orderOut(nil)
            pinnedBadges[id] = nil
        }
        for pw in pinned {
            let badge = pinnedBadges[pw.windowID] ?? {
                let b = BadgePanel(pinned: true)
                pinnedBadges[pw.windowID] = b
                return b
            }()
            badge.onClick = { [weak self] in
                self?.toggle(ForeignWindow(windowID: pw.windowID, ownerPID: pw.ownerPID,
                                           ownerName: pw.ownerName, windowTitle: pw.windowTitle))
            }
            // While the floating pin is showing it is what you see, and it may be
            // cropped or moved away from the real window, so the badge goes on it.
            if let overlay = tracker.overlay(for: pw.windowID), overlay.isPinVisible, overlay.isVisible {
                // A pin cropped down to a sliver would be mostly badge, and the
                // badge would take the clicks meant to move it or clear its
                // crop. Such a pin is unpinned from the menu instead.
                if overlay.frame.width >= BadgePanel.side * 3, overlay.frame.height >= BadgePanel.side * 2 {
                    badge.show(cornerOf: overlay.frame, level: overlay.level, above: overlay.windowNumber)
                } else {
                    badge.orderOut(nil)
                }
            } else if let frame = Self.onScreenFrame(of: pw.windowID) {
                badge.show(cornerOf: frame, level: .normal, above: Int(pw.windowID))
            } else {
                badge.orderOut(nil)
            }
        }
    }

    private func updateFocusedBadge() {
        guard let fw = focusedWindow, !tracker.isPinned(windowID: fw.windowID),
              let frame = Self.onScreenFrame(of: fw.windowID),
              frame.width >= 200, frame.height >= 120,
              // A window filling a whole display is full screen: a film, a
              // presentation, a game. There is no title bar for the badge to
              // sit in there, only the corner of the content.
              !NSScreen.screens.contains(where: { $0.frame == frame }) else {
            focusedBadge.orderOut(nil)
            return
        }
        focusedBadge.onClick = { [weak self] in
            // Full details (title and all) for the menu; the badge's own copy is minimal.
            let full = WindowDetector.getFrontmostForeignWindow()
            self?.toggle(full?.windowID == fw.windowID ? full! : fw)
        }
        focusedBadge.show(cornerOf: frame, level: .normal, above: Int(fw.windowID))
    }

    // MARK: - Windows

    /// The focused window of the frontmost app, if it is an ordinary window of
    /// another app.
    private static func focusedForeignWindow() -> ForeignWindow? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        // Several times a second, on the main thread: never wait long on a slow app.
        AXUIElementSetMessagingTimeout(axApp, 0.1)
        var ref: AnyObject?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &ref) == .success,
              let window = WindowLevelManager.element(from: ref),
              let wid = WindowLevelManager.windowID(of: window) else { return nil }
        return ForeignWindow(windowID: wid, ownerPID: app.processIdentifier,
                             ownerName: app.localizedName ?? "", windowTitle: "")
    }

    /// A window's frame in AppKit coordinates, if it is an ordinary on-screen window.
    private static func onScreenFrame(of windowID: UInt32) -> NSRect? {
        guard let info = (CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(windowID))
                          as? [[String: Any]])?.first,
              info[kCGWindowIsOnscreen as String] as? Bool == true,
              info[kCGWindowLayer as String] as? Int == 0,
              let b = info[kCGWindowBounds as String] as? [String: CGFloat],
              let primary = NSScreen.screens.first else { return nil }
        let h = b["Height"] ?? 0
        // Window-list bounds are top-left based; AppKit's are bottom-left from the primary screen.
        return NSRect(x: b["X"] ?? 0, y: primary.frame.height - (b["Y"] ?? 0) - h,
                      width: b["Width"] ?? 0, height: h)
    }
}

// MARK: - Badge window

private final class BadgePanel: NSPanel {

    static let side: CGFloat = 22
    var onClick: (() -> Void)?

    init(pinned: Bool) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: Self.side, height: Self.side),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = pinned
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isReleasedWhenClosed = false
        collectionBehavior = [.fullScreenAuxiliary, .transient, .ignoresCycle]
        contentView = BadgeView(pinned: pinned) { [weak self] in self?.onClick?() }
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Put the badge in the top-right corner of `frame`, just above window `above`.
    func show(cornerOf frame: NSRect, level: NSWindow.Level, above windowNumber: Int) {
        let origin = NSPoint(x: frame.maxX - Self.side - 8, y: frame.maxY - Self.side - 4)
        if self.frame.origin != origin { setFrameOrigin(origin) }
        if self.level != level { self.level = level }
        order(.above, relativeTo: windowNumber)
    }
}

private final class BadgeView: NSView {

    private let pinned: Bool
    private let action: () -> Void
    private var hovering = false { didSet { needsDisplay = true } }

    init(pinned: Bool, action: @escaping () -> Void) {
        self.pinned = pinned
        self.action = action
        super.init(frame: NSRect(x: 0, y: 0, width: BadgePanel.side, height: BadgePanel.side))
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
        toolTip = pinned ? "Unpin this window" : "Pin this window on top"
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // The click must work while another app is active, without activating WindowPin.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { action() }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func draw(_ dirtyRect: NSRect) {
        let circle = NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1))
        let fill: NSColor = pinned
            ? .systemOrange
            : NSColor.gray.withAlphaComponent(hovering ? 0.85 : 0.35)
        fill.setFill()
        circle.fill()

        let name = pinned || hovering ? "pin.fill" : "pin"
        let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
            .applying(.init(paletteColors: [.white]))
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else { return }
        let s = symbol.size
        symbol.draw(in: NSRect(x: (bounds.width - s.width) / 2, y: (bounds.height - s.height) / 2,
                               width: s.width, height: s.height))
    }
}
