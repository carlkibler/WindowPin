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
    /// Keeps badges off the window's own title-bar buttons.
    private let slots = TitleBarSlotFinder()

    // Nothing here runs on a timer while nothing is happening. A badge only
    // has to move when a window does, and every way a window can change says
    // so: the active app changes, the app reports a window focused, moved or
    // resized, a mouse button goes down (the start of every drag), the Space
    // changes, or a pin is made or removed. Each of those calls `refresh`,
    // which follows closely for a second and then stops. A click is the
    // exception, being by far the most common and usually nothing to do with
    // a window moving: it gets one check, and is followed only for as long as
    // the button stays down.
    //
    // This used to be one timer, ten times a second, for as long as WindowPin
    // was running, which kept an app that is idle nearly all day awake.

    /// Runs ten times a second, only for a moment after something changed and
    /// while a mouse button is held.
    private var followTimer: Timer?
    private var followUntil = Date.distantPast
    private var followTicks = 0
    /// Runs twice a second, only while something is pinned: a showing pin
    /// follows its window on a timer of its own, and its badge follows it.
    private var pinnedTimer: Timer?

    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var mouseMonitor: Any?
    /// Accessibility notifications from the active app.
    private var appObserver: AXObserver?
    private var observedPID: pid_t = 0

    init(tracker: PinnedWindowTracker, toggle: @escaping (ForeignWindow) -> Void) {
        self.tracker = tracker
        self.toggle = toggle

        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification,
                     NSWorkspace.activeSpaceDidChangeNotification,
                     NSWorkspace.didHideApplicationNotification,
                     NSWorkspace.didUnhideApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification] {
            observe(workspace, name)
        }
        observe(.default, NSApplication.didChangeScreenParametersNotification)
        // The two switches in Settings.
        observe(.default, UserDefaults.didChangeNotification)

        // Mouse buttons need no permission to watch, unlike keys. Clicks on
        // WindowPin's own windows are not reported here; a click on a badge
        // changes the pinned set, which refreshes by itself.
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseUp]
        ) { [weak self] _ in self?.refresh(following: false) }

        refresh()
    }

    deinit {
        followTimer?.invalidate()
        pinnedTimer?.invalidate()
        observers.forEach { $0.0.removeObserver($0.1) }
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        stopObservingApp()
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name) {
        observers.append((center, center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            self?.refresh()
        }))
    }

    // MARK: - Update

    /// Bring the badges up to date now, and follow closely for the next
    /// second: what was just reported is often the start of something still
    /// going on, such as a drag, an animated resize, or a pin fading in.
    ///
    /// - Parameter following: false for a mouse button going down or up, which
    ///   is followed only while the button is held. If the click did move a
    ///   window, the app says so, and that report is followed as usual.
    func refresh(following: Bool = true) {
        observeFrontmostApp()
        readFocusedWindow()
        update()

        if following { followUntil = Date().addingTimeInterval(1) }
        if followTimer == nil, following || NSEvent.pressedMouseButtons != 0 {
            followTicks = 0
            // Common modes, so it keeps up during a drag.
            let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.follow() }
            RunLoop.main.add(t, forMode: .common)
            followTimer = t
        }

        let anyPinned = Self.showsPinned && !tracker.pinnedWindows.isEmpty
        if anyPinned, pinnedTimer == nil {
            let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.update() }
            t.tolerance = 0.1
            RunLoop.main.add(t, forMode: .common)
            pinnedTimer = t
        } else if !anyPinned {
            pinnedTimer?.invalidate()
            pinnedTimer = nil
        }
    }

    private func follow() {
        guard Date() < followUntil || NSEvent.pressedMouseButtons != 0 else {
            followTimer?.invalidate()
            followTimer = nil
            return
        }
        followTicks += 1
        // Asking the front app for its focused window is an Accessibility call,
        // so do it a few times a second rather than every tick.
        if followTicks % 3 == 0 { readFocusedWindow() }
        update()
    }

    private func update() {
        updatePinnedBadges()
        updateFocusedBadge()
    }

    private func readFocusedWindow() {
        focusedWindow = Self.showsFocused ? Self.focusedForeignWindow() : nil
    }

    // MARK: - The active app's window changes

    /// Ask the active app to report when its focused window changes and when
    /// a window moves, is resized or is minimised. Registered on the app, the
    /// notifications cover all its windows. This is what catches a change
    /// made from the keyboard, where no mouse button goes down.
    private func observeFrontmostApp() {
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        let pid = app.processIdentifier
        guard pid != observedPID else { return }
        stopObservingApp()
        guard pid != ProcessInfo.processInfo.processIdentifier else { return }

        var created: AXObserver?
        guard AXObserverCreate(pid, badgeAXCallback, &created) == .success, let observer = created else { return }
        let element = AXUIElementCreateApplication(pid)
        // Registering waits on the app, on the main thread: never long.
        AXUIElementSetMessagingTimeout(element, 0.1)
        let context = Unmanaged.passUnretained(self).toOpaque()
        var registered = false
        for name in [kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification,
                     kAXWindowMovedNotification, kAXWindowResizedNotification,
                     kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification] {
            if AXObserverAddNotification(observer, element, name as CFString, context) == .success {
                registered = true
            }
        }
        // Nothing registered: no Accessibility yet, or the app is not
        // answering. Leave it unrecorded so the next refresh tries again.
        guard registered else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        appObserver = observer
        observedPID = pid
    }

    private func stopObservingApp() {
        if let appObserver {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(appObserver), .commonModes)
        }
        appObserver = nil
        observedPID = 0
    }

    private func updatePinnedBadges() {
        let pinned = Self.showsPinned ? tracker.pinnedWindows : []
        let ids = Set(pinned.map(\.windowID))
        for (id, badge) in pinnedBadges where !ids.contains(id) {
            badge.orderOut(nil)
            pinnedBadges[id] = nil
        }
        // Only what is pinned or focused needs its spot remembered.
        slots.retain(ids.union(focusedWindow.map { [$0.windowID] } ?? []))
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
                    badge.show(on: overlay.frame, at: overlaySpot(pw.windowID, overlay),
                               level: overlay.level, above: overlay.windowNumber)
                } else {
                    badge.orderOut(nil)
                }
            } else if let frame = Self.onScreenFrame(of: pw.windowID) {
                let spot = slots.spot(pid: pw.ownerPID, windowID: pw.windowID, frame: frame, side: BadgePanel.side)
                badge.show(on: frame, at: spot, level: .normal, above: Int(pw.windowID))
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
        let spot = slots.spot(pid: fw.ownerPID, windowID: fw.windowID, frame: frame, side: BadgePanel.side)
        focusedBadge.show(on: frame, at: spot, level: .normal, above: Int(fw.windowID))
    }

    /// The floating pin shows the window scaled to its own size, so a spot
    /// found on the window scales with it. A cropped pin shows only part of the
    /// window and its corner is somewhere else entirely, so it keeps the corner.
    private func overlaySpot(_ windowID: UInt32, _ overlay: WindowOverlay) -> BadgeSpot {
        guard overlay.crop == nil, let known = slots.knownSpot(windowID: windowID),
              known.size.width > 0 else { return .corner }
        var spot = known.spot.scaled(by: overlay.frame.width / known.size.width)
        spot.right = min(max(spot.right, TitleBarSlot.margin), overlay.frame.width - BadgePanel.side * 2)
        spot.top = max(spot.top, 0)
        return spot
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

/// Accessibility notifications arrive at a C function, on the main run loop.
private func badgeAXCallback(_ observer: AXObserver, _ element: AXUIElement,
                             _ notification: CFString, _ context: UnsafeMutableRawPointer?) {
    guard let context else { return }
    Unmanaged<PinBadgeController>.fromOpaque(context).takeUnretainedValue().refresh()
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

    /// Put the badge at `spot` on `frame`, just above window `above`.
    func show(on frame: NSRect, at spot: BadgeSpot, level: NSWindow.Level, above windowNumber: Int) {
        let origin = NSPoint(x: frame.maxX - Self.side - spot.right,
                             y: frame.maxY - Self.side - spot.top)
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
