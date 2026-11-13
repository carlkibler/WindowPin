import AppKit
import ApplicationServices

/// A record of what kinds of windows people focus, to decide which ones should
/// never get a pin badge (Open and Save panels, alerts, password prompts)
/// from what macOS actually reports rather than from memory.
///
/// Off by default, and local only: nothing leaves the machine. Turn on with
///   defaults write <bundle id> windowSurvey -bool true
/// and each window is written once, when first focused, to
///   ~/Library/Logs/WindowPin/window-survey.tsv
/// Window titles are not recorded, only whether a window has one.
enum WindowSurvey {

    static let key = "windowSurvey"
    static var isOn: Bool { UserDefaults.standard.bool(forKey: key) }

    /// Window subroles the badge would be hidden for under the proposed rule.
    static let hiddenSubroles: Set<String> = [
        "AXDialog", "AXSystemDialog", "AXFloatingWindow", "AXSystemFloatingWindow",
    ]
    /// System processes that show windows on behalf of other apps.
    static let hiddenOwners: Set<String> = [
        "SecurityAgent", "CoreServicesUIAgent", "screencaptureui",
        "com.apple.appkit.xpc.openAndSavePanelService", "Open and Save Panel Service",
        "universalAccessAuthWarn", "UserNotificationCenter",
    ]

    private static let path = wpLogDirectory.appendingPathComponent("window-survey.tsv").path
    /// Windows already written: by window number, or for a window that will
    /// not give its number, by app and kind.
    private static var seen: Set<String> = []
    private static let columns = [
        "time", "app", "owner", "role", "subrole", "modal", "size", "layer",
        "close", "titled", "would_hide", "badge_size_ok",
    ]
    private static var headerChecked = false
    private static let timeFormat = ISO8601DateFormatter()

    /// Record a focused window, once per window.
    static func record(_ window: AXUIElement, windowID: UInt32?, app: NSRunningApplication) {
        guard isOn else { return }
        if let windowID, seen.contains("w\(windowID)") { return }
        let role = string(window, kAXRoleAttribute) ?? "-"
        let subrole = string(window, kAXSubroleAttribute) ?? "-"
        let appID = app.bundleIdentifier ?? app.localizedName ?? "-"
        let key = windowID.map { "w\($0)" } ?? "\(appID)|\(role)|\(subrole)"
        guard !seen.contains(key) else { return }
        if seen.count > 5000 { seen.removeAll() }
        seen.insert(key)

        if !headerChecked {
            headerChecked = true
            if !FileManager.default.fileExists(atPath: path) {
                wpAppend(columns.joined(separator: "\t") + "\n", to: path)
            }
        }

        var modal: AnyObject?
        let isModal = AXUIElementCopyAttributeValue(window, kAXModalAttribute as CFString, &modal) == .success
            ? ((modal as? Bool) == true ? "yes" : "no") : "-"
        var close: AnyObject?
        let hasClose = AXUIElementCopyAttributeValue(window, kAXCloseButtonAttribute as CFString, &close) == .success
            && close != nil
        let titled = !(string(window, kAXTitleAttribute) ?? "").isEmpty

        // The window list says who really draws the window, which for an Open
        // or Save panel in a sandboxed app is not the app itself.
        let info = windowID.flatMap {
            (CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID($0)) as? [[String: Any]])?.first
        }
        // No window number: the badge can never be placed on it anyway.
        let ownerName = info?[kCGWindowOwnerName as String] as? String ?? (windowID == nil ? "no-window-id" : "-")
        let layer = info?[kCGWindowLayer as String] as? Int ?? -1
        let bounds = info?[kCGWindowBounds as String] as? [String: CGFloat] ?? [:]
        let w = Int(bounds["Width"] ?? 0), h = Int(bounds["Height"] ?? 0)
        let fullScreen = NSScreen.screens.contains {
            Int($0.frame.width) == w && Int($0.frame.height) == h
        }

        let wouldHide = hiddenSubroles.contains(subrole) || role == kAXSheetRole
            || hiddenOwners.contains(ownerName) || hiddenOwners.contains(appID)
        let sizeOK = w >= 200 && h >= 120 && layer == 0 && !fullScreen

        let fields = [
            timeFormat.string(from: Date()), appID, ownerName, role, subrole, isModal,
            "\(w)x\(h)", "\(layer)", hasClose ? "yes" : "no", titled ? "yes" : "no",
            wouldHide ? "yes" : "no", sizeOK ? "yes" : "no",
        ]
        // Tabs and newlines in a name would break the columns.
        wpAppend(fields.map { $0.replacingOccurrences(of: "\t", with: " ")
                                .replacingOccurrences(of: "\n", with: " ") }
                    .joined(separator: "\t") + "\n", to: path)
    }

    private static func string(_ el: AXUIElement, _ attribute: String) -> String? {
        var ref: AnyObject?
        guard AXUIElementCopyAttributeValue(el, attribute as CFString, &ref) == .success else { return nil }
        return ref as? String
    }
}
