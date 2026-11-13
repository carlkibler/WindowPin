import AppKit
import ApplicationServices

/// Where along a window's title bar a pin badge can sit without covering one
/// of the window's own controls.
///
/// The badge belongs in the top-right corner, but plenty of apps keep a
/// button there: Safari's tab overview, Chrome's tab search, Finder's search
/// field. So before placing it, ask the app what lies under each spot along the
/// title bar, working leftwards from the corner, and take the first spot clear
/// of anything clickable.
enum TitleBarSlot {

    /// What lies under one point of the title bar.
    enum Probe {
        /// Title text, toolbar background, the window itself: safe to cover.
        case free
        /// A button, field, tab or other control.
        case taken
        /// The app did not answer. Stop asking it.
        case failed
    }

    /// Distance from the window's right edge to the badge when nothing is in the way.
    static let margin: CGFloat = 8
    /// Spacing between the points asked about.
    static let step: CGFloat = 4
    /// Never ask more than this many points about one window.
    static let maxProbes = 64

    /// The distance from the window's right edge to the badge's right edge, or
    /// nil if no clear spot was found and the badge should take the corner as
    /// before.
    ///
    /// - Parameters:
    ///   - side: the badge's width.
    ///   - width: the window's width. The badge stays in its right half.
    ///   - probe: what lies under the point this far from the window's right edge.
    static func inset(side: CGFloat, width: CGFloat, probe: (CGFloat) -> Probe) -> CGFloat? {
        // A spot is clear when every point across the badge's width is.
        let span = Int((side / step).rounded(.down))
        let limit = min(width / 2, 400)
        var memo: [Int: Probe] = [:]
        var asked = 0

        func result(_ k: Int) -> Probe {
            if let known = memo[k] { return known }
            guard asked < maxProbes else { return .failed }
            asked += 1
            let p = probe(margin + CGFloat(k) * step)
            memo[k] = p
            return p
        }

        var start = 0
        scan: while margin + CGFloat(start) * step + side <= limit {
            // Check the far side first: when it is taken, the scan can skip
            // straight past it.
            for k in stride(from: start + span, through: start, by: -1) {
                switch result(k) {
                case .failed: return nil
                case .taken:
                    start = k + 1
                    continue scan
                case .free: break
                }
            }
            return margin + CGFloat(start) * step
        }
        return nil
    }
}

/// Finds and remembers a clear spot for the badge on each window, asking the
/// window's app through Accessibility.
final class TitleBarSlotFinder {

    private struct Entry {
        let size: CGSize
        let spot: BadgeSpot
    }

    private var cache: [UInt32: Entry] = [:]

    /// Roles a click is meant for. Covering one of these takes its clicks.
    private static let controls: Set<String> = [
        kAXButtonRole, kAXTextFieldRole, kAXTextAreaRole, kAXPopUpButtonRole,
        kAXMenuButtonRole, kAXCheckBoxRole, kAXRadioButtonRole, kAXRadioGroupRole,
        kAXComboBoxRole, kAXSliderRole, kAXIncrementorRole, kAXDisclosureTriangleRole,
        "AXLink", "AXTab", "AXSegmentedControl",
    ]

    /// Roles that end the walk up from a hit: past these, everything is the
    /// window's own surface.
    private static let surfaces: Set<String> = [
        kAXWindowRole, kAXToolbarRole, kAXApplicationRole, kAXSheetRole, kAXDrawerRole,
    ]

    /// Where on the window to place the badge.
    ///
    /// Asking is done once per window size, so moving a window costs nothing.
    /// While a mouse button is held, a window being resized keeps its last
    /// answer instead of being asked again on every step of the drag.
    func spot(pid: pid_t, windowID: UInt32, frame: NSRect, side: CGFloat) -> BadgeSpot {
        if let entry = cache[windowID] {
            if entry.size == frame.size || NSEvent.pressedMouseButtons != 0 { return entry.spot }
        }
        // A failure is remembered too: an app that is not answering should not
        // be asked again ten times a second.
        let spot = measure(pid: pid, windowID: windowID, frame: frame, side: side)
        cache[windowID] = Entry(size: frame.size, spot: spot)
        return spot
    }

    /// The last answer for a window, without asking again.
    func knownSpot(windowID: UInt32) -> (size: CGSize, spot: BadgeSpot)? {
        cache[windowID].map { ($0.size, $0.spot) }
    }

    /// Drop what is known about every window but these.
    func retain(_ windowIDs: Set<UInt32>) {
        cache = cache.filter { windowIDs.contains($0.key) }
    }

    private func measure(pid: pid_t, windowID: UInt32, frame: NSRect, side: CGFloat) -> BadgeSpot {
        guard let primary = NSScreen.screens.first else { return .corner }
        let app = AXUIElementCreateApplication(pid)
        // On the main thread: never wait long on a slow app.
        AXUIElementSetMessagingTimeout(app, 0.1)
        // Accessibility positions are top-left based, from the primary screen.
        let windowTop = primary.frame.height - frame.maxY

        // Line the badge up with the close button. Its middle is the line a
        // title bar's contents are centred on, however tall the bar is: a plain
        // title bar, a tall unified toolbar, a browser's tab strip.
        var top = BadgeSpot.corner.top
        if let window = WindowLevelManager.axWindow(pid: pid, windowID: windowID),
           let mid = Self.closeButtonMidY(of: window) {
            top = BadgeSpot.top(centredOn: mid - windowTop, side: side)
        }
        let y = Float(windowTop + top + side / 2)
        var log: [String] = []

        let inset = TitleBarSlot.inset(side: side, width: frame.width) { fromRight in
            let x = Float(frame.maxX - fromRight)
            var hit: AXUIElement?
            let err = AXUIElementCopyElementAtPosition(app, x, y, &hit)
            switch err {
            case .success:
                guard let hit else { return .free }
                let (probe, role) = Self.classify(hit)
                if probe == .taken { log.append("\(Int(fromRight)):\(role)") }
                return probe
            case .noValue, .attributeUnsupported:
                return .free
            default:
                log.append("\(Int(fromRight)):err\(err.rawValue)")
                return .failed
            }
        }
        wplog("titlebar slot wid=\(windowID) pid=\(pid) width=\(Int(frame.width)) top=\(Int(top)) inset=\(inset.map { "\(Int($0))" } ?? "default") taken=[\(log.joined(separator: " "))]")
        return BadgeSpot(right: inset ?? TitleBarSlot.margin, top: top)
    }

    /// The vertical middle of a window's close button, in screen coordinates.
    private static func closeButtonMidY(of window: AXUIElement) -> CGFloat? {
        var ref: AnyObject?
        guard AXUIElementCopyAttributeValue(window, kAXCloseButtonAttribute as CFString, &ref) == .success,
              let button = WindowLevelManager.element(from: ref) else { return nil }
        var pos: AnyObject?, size: AnyObject?
        guard AXUIElementCopyAttributeValue(button, kAXPositionAttribute as CFString, &pos) == .success,
              AXUIElementCopyAttributeValue(button, kAXSizeAttribute as CFString, &size) == .success,
              let p = WindowLevelManager.point(from: pos), let s = WindowLevelManager.size(from: size),
              s.height > 0 else { return nil }
        return p.y + s.height / 2
    }

    /// Whether a hit element is a control, looking up through its parents, as
    /// the hit is often a button's image or label rather than the button.
    private static func classify(_ element: AXUIElement) -> (TitleBarSlot.Probe, String) {
        var current: AXUIElement? = element
        for _ in 0..<5 {
            guard let el = current, let role = string(el, kAXRoleAttribute) else { break }
            if controls.contains(role) { return (.taken, role) }
            if surfaces.contains(role) { return (.free, role) }
            var parent: AnyObject?
            guard AXUIElementCopyAttributeValue(el, kAXParentAttribute as CFString, &parent) == .success else { break }
            current = WindowLevelManager.element(from: parent)
        }
        return (.free, "")
    }

    private static func string(_ el: AXUIElement, _ attribute: String) -> String? {
        var ref: AnyObject?
        guard AXUIElementCopyAttributeValue(el, attribute as CFString, &ref) == .success else { return nil }
        return ref as? String
    }
}

/// Where a badge sits on its window.
struct BadgeSpot: Equatable {
    /// Distance from the window's right edge to the badge's right edge.
    var right: CGFloat
    /// Distance from the window's top edge to the badge's top edge.
    var top: CGFloat

    /// The top-right corner, for a window that cannot be asked.
    static let corner = BadgeSpot(right: TitleBarSlot.margin, top: 4)

    /// The badge's top edge for its middle to sit `mid` below the window's
    /// top edge. A close button reported somewhere odd keeps the badge within
    /// the title bar region rather than following it down the window.
    static func top(centredOn mid: CGFloat, side: CGFloat) -> CGFloat {
        guard mid.isFinite, mid > side / 2, mid < 48 else { return corner.top }
        return (mid - side / 2).rounded()
    }

    /// The same spot on a copy of the window drawn at another size.
    func scaled(by factor: CGFloat) -> BadgeSpot {
        BadgeSpot(right: right * factor, top: top * factor)
    }
}
