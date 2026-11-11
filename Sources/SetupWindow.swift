import AppKit
import SwiftUI

/// The window that walks through the two permissions WindowPin needs, and
/// shows each one turn green as it is granted.
///
/// It is shown the first time WindowPin runs, at every launch while either
/// permission is missing, and when a pin is refused for want of Screen
/// Recording. Before this, a refused pin opened System Settings every time,
/// and nothing in WindowPin said which of the two was missing or that one of
/// them can need a restart to take effect.
enum SetupWindow {

    private static var window: NSWindow?
    private static let shownKey = "didShowSetup"

    static var isAccessibilityGranted: Bool { AXIsProcessTrusted() }
    static var isScreenRecordingGranted: Bool { CGPreflightScreenCaptureAccess() }
    static var isMissingPermission: Bool { !isAccessibilityGranted || !isScreenRecordingGranted }

    /// Whether to show the window as WindowPin starts: on its first run, as a
    /// welcome, and afterwards only while something is missing.
    static var shouldShowAtLaunch: Bool {
        isMissingPermission || !UserDefaults.standard.bool(forKey: shownKey)
    }

    /// - Parameter shortcut: the current shortcut, for the closing line.
    static func show(shortcut: String) {
        UserDefaults.standard.set(true, forKey: shownKey)
        if let window {
            JorvikWindowHelper.showOnActiveSpace(window)
            return
        }
        let controller = NSHostingController(rootView: SetupView(shortcut: shortcut) {
            SetupWindow.window?.close()
        })
        let w = NSWindow(contentViewController: controller)
        w.title = "WindowPin Setup"
        w.styleMask = [.titled, .closable]
        w.isReleasedWhenClosed = false
        w.setContentSize(controller.view.fittingSize)
        window = w
        JorvikWindowHelper.showOnActiveSpace(w)
    }

    /// Quit and start again, which is when macOS applies a Screen Recording
    /// grant made while the app was running.
    static func relaunch() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        // The path is passed as an argument, not pasted into the command.
        task.arguments = ["-c", "sleep 0.5; /usr/bin/open \"$0\"", Bundle.main.bundlePath]
        try? task.run()
        NSApp.terminate(nil)
    }
}

private struct SetupView: View {
    let shortcut: String
    let close: () -> Void

    @StateObject private var accessibility = JorvikPermissionWatcher.accessibility()
    @StateObject private var screenRecording = JorvikPermissionWatcher.screenRecording()

    // Whether each has been asked for before, on this Mac. macOS shows its own
    // prompt once; after that the only way to grant is in System Settings, so
    // the button takes the user there instead of appearing to do nothing.
    @AppStorage("askedAccessibility") private var askedAccessibility = false
    @AppStorage("askedScreenRecording") private var askedScreenRecording = false

    private var allGranted: Bool { accessibility.isGranted && screenRecording.isGranted }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 56, height: 56)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(allGranted ? "WindowPin is ready" : "Set up WindowPin")
                        .font(.title2.weight(.semibold))
                        .accessibilityAddTraits(.isHeader)
                    Text("WindowPin keeps a window in view above your other apps. macOS asks your permission for the two things that takes.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            PermissionRow(
                symbol: "keyboard",
                title: "Accessibility",
                reason: "For the keyboard shortcut, the pin buttons on windows, and bringing a pinned window forward when you click its pin.",
                granted: accessibility.isGranted,
                buttonTitle: askedAccessibility ? "Open System Settings" : "Allow\u{2026}",
                action: {
                    if askedAccessibility {
                        JorvikPermissionWatcher.openSettings(pane: .accessibility)
                    } else {
                        askedAccessibility = true
                        JorvikPermissionWatcher.promptForAccessibility()
                    }
                }
            )

            PermissionRow(
                symbol: "rectangle.dashed.badge.record",
                title: "Screen Recording",
                reason: "A pin is a live picture of the window. WindowPin films only the windows you pin, only while their pins are showing, and nothing is saved or sent anywhere.",
                granted: screenRecording.isGranted,
                buttonTitle: askedScreenRecording ? "Open System Settings" : "Allow\u{2026}",
                action: {
                    if askedScreenRecording {
                        JorvikPermissionWatcher.openSettings(pane: .screenRecording)
                    } else {
                        askedScreenRecording = true
                        // Shows the system's prompt the first time ever, and
                        // adds WindowPin to the list in System Settings.
                        _ = CGRequestScreenCaptureAccess()
                    }
                },
                note: askedScreenRecording && !screenRecording.isGranted
                    ? ("Already switched it on? macOS applies it when WindowPin restarts.", "Restart WindowPin", SetupWindow.relaunch)
                    : nil
            )
            // The window is kept, not released, when closed, so without this
            // the two watchers would go on checking once a second for good.
            .jorvikPollsWhileVisible(accessibility, screenRecording)

            Divider()

            HStack(alignment: .center) {
                if allGranted {
                    Text(shortcut == "Not set"
                         ? "Click the pin in a window's title bar to keep it on top."
                         : "Press \(shortcut), or click the pin in a window's title bar, to keep that window on top.")
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("You can come back to this from the WindowPin menu, or by opening WindowPin again.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 16)
                Button(allGranted ? "Done" : "Later", action: close)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 520)
        .onExitCommand(perform: close)
    }
}

private struct PermissionRow: View {
    let symbol: String
    let title: String
    let reason: String
    let granted: Bool
    let buttonTitle: String
    let action: () -> Void
    /// A line under the row with a button of its own: text, button title, action.
    var note: (String, String, () -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: symbol)
                    .font(.title2)
                    .frame(width: 30)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                // The text takes all the width the status or button leaves.
                // With a spacer beside it the two shared the row, and the
                // text wrapped well short of the room it had.
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.headline)
                    Text(reason)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if granted {
                    // Only the tick is green. Green text is too faint to
                    // read on a light window.
                    Label {
                        Text("Allowed")
                    } icon: {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    }
                    .font(.callout.weight(.medium))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(title): allowed")
                } else {
                    Button(buttonTitle, action: action)
                        // "Allow…" alone says nothing out of the row's context.
                        .accessibilityLabel("\(buttonTitle.replacingOccurrences(of: "\u{2026}", with: "")), for \(title)")
                }
            }
            if let note {
                HStack(spacing: 10) {
                    Text(note.0)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Button(note.1, action: note.2)
                        .controlSize(.small)
                }
                .padding(.leading, 42)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
        // An edge as well as a tint, so the rows still read as rows with
        // Increase Contrast on.
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color(nsColor: .separatorColor)))
        .accessibilityElement(children: .contain)
    }
}
