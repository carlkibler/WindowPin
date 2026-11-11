import AppKit

struct PinnedWindow: Hashable {
    let windowID: UInt32
    let ownerPID: pid_t
    let ownerName: String
    let windowTitle: String

    /// Display label for the menu: "Safari — GitHub" or "Terminal" if no title.
    var displayLabel: String {
        if windowTitle.isEmpty {
            return ownerName
        }
        let maxLen = 40
        let title = windowTitle.count > maxLen
            ? String(windowTitle.prefix(maxLen)) + "…"
            : windowTitle
        return "\(ownerName) — \(title)"
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(windowID)
    }

    static func == (lhs: PinnedWindow, rhs: PinnedWindow) -> Bool {
        lhs.windowID == rhs.windowID
    }
}

final class PinnedWindowTracker {

    private(set) var pinnedWindows: Set<PinnedWindow> = []
    private var overlays: [UInt32: WindowOverlay] = [:]
    private var pollTimer: Timer?
    /// Runs only while a pin is cropped. See `updateCroppedLayering`.
    private var layeringTimer: Timer?
    private var activationObserver: NSObjectProtocol?
    private var terminationObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    private var screensObserver: NSObjectProtocol?

    /// Called whenever the pinned set changes.
    var onChange: (() -> Void)?
    /// Called when a pin was taken down because Screen Recording was refused
    /// after the pin was made, so the user can be told why it went.
    var onCaptureDenied: ((PinnedWindow) -> Void)?
    /// Called when a pin was refused because Screen Recording is not granted.
    var onNeedsScreenRecording: (() -> Void)?

    init() {
        observeAppActivation()
        observeAppTermination()
        observeWakeAndDisplays()
    }

    deinit {
        pollTimer?.invalidate()
        if let obs = activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
        }
        if let obs = terminationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
        }
    }

    // MARK: - Public API



    func overlay(for windowID: UInt32) -> WindowOverlay? { overlays[windowID] }

    func isPinned(windowID: UInt32) -> Bool {
        pinnedWindows.contains(where: { $0.windowID == windowID })
    }

    func pin(window: ForeignWindow) {
        let pw = PinnedWindow(
            windowID: window.windowID,
            ownerPID: window.ownerPID,
            ownerName: window.ownerName,
            windowTitle: window.windowTitle
        )
        guard !pinnedWindows.contains(pw) else { return }
        guard hasScreenRecording() else { return }

        pinnedWindows.insert(pw)

        let overlay = WindowOverlay(
            windowID: CGWindowID(window.windowID),
            pid: window.ownerPID
        )
        overlay.onCropChange = { [weak self] in self?.cropsChanged() }
        overlay.onCaptureDenied = { [weak self] in
            wplog("pin: capture refused, unpinning wid=\(pw.windowID)")
            self?.unpin(windowID: pw.windowID)
            self?.onCaptureDenied?(pw)
        }
        overlays[window.windowID] = overlay
        wplog("pin: overlay created for wid=\(window.windowID)")

        // A pin normally starts out of sight, because its window is the one
        // in use, and comes up when the user switches to another app. Pinned
        // from the menu while its app is not the active one, there is no
        // switch coming to bring it up, so it comes up now.
        if NSWorkspace.shared.frontmostApplication?.processIdentifier != window.ownerPID {
            overlay.bringToFront()
        }

        pinsChanged()
    }

    /// Whether Screen Recording is granted. If not, the owner is told, and
    /// shows the setup window, which asks for it and says why.
    ///
    /// This used to ask for itself: the system's prompt the first time, and
    /// System Settings thrown open on every refused pin after that, from a
    /// shortcut that works in any app.
    private func hasScreenRecording() -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        wplog("pin: Screen Recording not granted")
        onNeedsScreenRecording?()
        return false
    }

    func unpin(windowID: UInt32) {
        guard let pw = pinnedWindows.first(where: { $0.windowID == windowID }) else { return }
        overlays[windowID]?.hideOverlay()
        overlays[windowID] = nil
        pinnedWindows.remove(pw)
        pinsChanged()
    }

    func unpinAll() {
        for (_, overlay) in overlays {
            overlay.hideOverlay()
        }
        overlays.removeAll()
        pinnedWindows.removeAll()
        pinsChanged()
    }

    func updateCaptureRate() {
        for (_, overlay) in overlays {
            overlay.applyCaptureRate()
        }
    }

    func updateAllSpaces() {
        for (_, overlay) in overlays {
            overlay.updateCollectionBehavior()
        }
    }

    func toggle(window: ForeignWindow) {
        if isPinned(windowID: window.windowID) {
            unpin(windowID: window.windowID)
        } else {
            pin(window: window)
        }
    }

    // MARK: - App activation observer

    private func observeAppActivation() {
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self = self, !self.pinnedWindows.isEmpty else { return }

            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let activatedPID = app.processIdentifier
            let myPID = ProcessInfo.processInfo.processIdentifier
            guard activatedPID != myPID else { return }

            // For each pinned window:
            // - If the activated app owns this window → drop overlay behind (user is using real window)
            // - Otherwise → raise overlay to front (user switched away, keep pinned content visible)
            for pw in self.pinnedWindows {
                if let overlay = self.overlays[pw.windowID] {
                    if overlay.isCropped {
                        self.updateLayering(of: overlay)
                    } else if pw.ownerPID == activatedPID {
                        overlay.sendBehind()
                    } else {
                        overlay.bringToFront()
                    }
                    // A pin that stayed up through this switch but has lost
                    // its stream gets it back here.
                    overlay.reviveStreamIfNeeded()
                }
            }
        }
    }

    // MARK: - Sleep and display changes

    /// Sleep and a change of displays can each end a pin's stream. The stream
    /// restarts itself a few times and then gives up, which a long sleep
    /// outlasts, leaving the pin on a frozen frame.
    private func observeWakeAndDisplays() {
        let revive: (Notification) -> Void = { [weak self] _ in
            // A moment for the displays to settle; a stream started at once
            // is as likely to be stopped again.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                self?.overlays.values.forEach { $0.reviveStreamIfNeeded() }
            }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main, using: revive)
        screensObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main, using: revive)
    }

    // MARK: - Cropped pins

    /// A cropped pin goes behind only while its own window is the one in use,
    /// not whenever its app is active (see `WindowOverlay.isTargetInUse`).
    /// Switching windows inside one app raises no notification, so while any
    /// pin is cropped its layering is checked on a timer. Half a second matches
    /// how often a visible pin already follows its window.
    private static let layeringInterval: TimeInterval = 0.5

    private func cropsChanged() {
        let anyCropped = overlays.values.contains { $0.isCropped }
        if anyCropped, layeringTimer == nil {
            layeringTimer = Timer.scheduledTimer(withTimeInterval: Self.layeringInterval,
                                                 repeats: true) { [weak self] _ in
                self?.updateCroppedLayering()
            }
        } else if !anyCropped {
            layeringTimer?.invalidate()
            layeringTimer = nil
        }
    }

    private func updateCroppedLayering() {
        // The last cropped pin may have been unpinned or closed since.
        guard overlays.values.contains(where: { $0.isCropped }) else {
            cropsChanged()
            return
        }
        // WindowPin itself in front (its menu or settings) changes nothing,
        // as with app activation.
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier
                != ProcessInfo.processInfo.processIdentifier else { return }
        for overlay in overlays.values where overlay.isCropped {
            updateLayering(of: overlay)
        }
    }

    private func updateLayering(of overlay: WindowOverlay) {
        // Act only on a change: this runs twice a second, and bringToFront
        // logs each call it skips.
        let inUse = overlay.isTargetInUse
        if inUse, overlay.isPinVisible {
            overlay.sendBehind()
        } else if !inUse, !overlay.isPinVisible {
            overlay.bringToFront()
        }
    }

    // MARK: - Polling for closed windows

    /// Tell the owner the pinned set changed, and look for closed windows only
    /// while there are pins to lose. With nothing pinned WindowPin has no
    /// timer running at all.
    private func pinsChanged() {
        if pinnedWindows.isEmpty {
            pollTimer?.invalidate()
            pollTimer = nil
        } else if pollTimer == nil {
            pollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
                self?.pruneClosedWindows()
            }
        }
        onChange?()
    }

    private func pruneClosedWindows() {
        guard !pinnedWindows.isEmpty else { return }
        let existing = WindowDetector.allWindowIDs()
        let removed = pinnedWindows.filter { !existing.contains($0.windowID) }
        guard !removed.isEmpty else { return }
        for pw in removed {
            overlays[pw.windowID]?.hideOverlay()
            overlays[pw.windowID] = nil
            pinnedWindows.remove(pw)
        }
        pinsChanged()
    }

    // MARK: - App termination

    private func observeAppTermination() {
        terminationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self = self,
                  let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let pid = app.processIdentifier
            let removed = self.pinnedWindows.filter { $0.ownerPID == pid }
            guard !removed.isEmpty else { return }
            for pw in removed {
                self.overlays[pw.windowID]?.hideOverlay()
                self.overlays[pw.windowID] = nil
                self.pinnedWindows.remove(pw)
            }
            self.pinsChanged()
        }
    }
}
