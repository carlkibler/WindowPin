import SwiftUI
import ScreenCaptureKit

struct WindowPinSettingsContent: View {
    let tracker: PinnedWindowTracker
    let delegate: AppDelegate

    // @AppStorage (not computed Bindings) so SwiftUI's selection state stays in
    // sync with the store — a computed Binding here goes stale after the first
    // change and silently swallows every second interaction.
    @AppStorage("captureRate") private var captureRate: Double = 30.0
    // The default is the overlay's own, which is off on macOS 27 and later. A
    // literal `true` here drew the switch as on while nothing was stored and
    // the overlay was treating it as off.
    @AppStorage("forwardEvents") private var forwardEvents: Bool = WindowOverlay.forwardEvents
    @AppStorage("pinToAllSpaces") private var pinToAllSpaces: Bool = false
    @AppStorage(PinBadgeController.pinnedKey) private var badgePinned: Bool = true
    @AppStorage(PinBadgeController.focusedKey) private var badgeFocused: Bool = true

    /// Both kept current by JorvikKit — see `JorvikPermissionWatcher`. These two rows used
    /// to be read inline in `body`, so nothing ever caused them to re-render and granting
    /// either permission left the row still asking for it.
    @StateObject private var accessibility = JorvikPermissionWatcher.accessibility()
    @StateObject private var screenRecording = JorvikPermissionWatcher.screenRecording()

    /// What the switch above does, which is less on macOS 27: a click can no
    /// longer be sent into another app's window there (see
    /// `WindowOverlay.forwardEvents`), so only scrolling is passed on.
    private static var interactionCaption: String {
        if #available(macOS 27, *) {
            return "Scrolling on an overlay scrolls the pinned window. A click always switches to the real window."
        }
        return "Clicks and scrolls on an overlay are sent to the pinned window. \u{2318}-click an overlay to switch to the real window. When off, any click switches to the real window."
    }

    // Everything below is a plain grouped form: no fonts, sizes or spacing of
    // its own. A second `Text` in a label is the row's description, which the
    // form sets in its own secondary style.
    var body: some View {
        Section("Pinning") {
            JorvikShortcutRecorder(
                label: "Pin or unpin the window in use",
                keyCode: Binding(
                    get: { delegate.shortcutKeyCode },
                    set: { delegate.shortcutKeyCode = $0 }
                ),
                modifiers: Binding(
                    get: { delegate.shortcutModifiers },
                    set: { delegate.shortcutModifiers = $0 }
                ),
                displayString: { delegate.shortcutDisplayString() },
                onChanged: { delegate.saveShortcutAndUpdateTap() },
                onClear: {
                    // Pinning stays available from the menu, which falls back
                    // to the last foreign window, so clearing costs nothing but
                    // the shortcut itself.
                    delegate.shortcutKeyCode = 0
                    delegate.shortcutModifiers = []
                    delegate.saveShortcutAndUpdateTap()
                },
                onRecordingChanged: { delegate.setHotkeySuspended($0) }
            )
            Toggle("Show a pin button on pinned windows", isOn: $badgePinned)
            Toggle(isOn: $badgeFocused) {
                Text("Show a pin button on the window in use")
                Text("The button sits at the right of the title bar. Click it to pin or unpin that window.")
            }
        }

        Section("Overlays") {
            Picker(selection: $captureRate) {
                Text("0.5 fps").tag(0.5)
                Text("1 fps").tag(1.0)
                Text("2 fps").tag(2.0)
                Text("5 fps").tag(5.0)
                Text("10 fps").tag(10.0)
                Text("15 fps").tag(15.0)
                Text("30 fps").tag(30.0)
                Text("60 fps").tag(60.0)
            } label: {
                Text("Maximum frame rate")
                Text("An overlay is redrawn only when its window changes, so a high rate costs nothing while the window is still.")
            }
            .onChange(of: captureRate) { _, _ in
                tracker.updateCaptureRate()
            }

            Toggle(isOn: $forwardEvents) {
                Text("Interact through overlays")
                Text(Self.interactionCaption)
            }

            Toggle("Pin to all spaces", isOn: $pinToAllSpaces)
                .onChange(of: pinToAllSpaces) { _, _ in
                    tracker.updateAllSpaces()
                }
        }

        Section("Permissions") {
            LabeledContent {
                if accessibility.isGranted {
                    Label("Granted", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Button("Grant Access") {
                        JorvikPermissionWatcher.promptForAccessibility()
                    }
                }
            } label: {
                Text("Accessibility")
                Text("For the keyboard shortcut, the pin buttons, and bringing a pinned window to the front.")
            }
            // The Settings window is cached, so these watchers would otherwise poll for the
            // life of the app once Settings had been opened.
            .jorvikPollsWhileVisible(accessibility, screenRecording)

            LabeledContent {
                if screenRecording.isGranted {
                    Label("Granted", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Button("Grant Access") {
                        // The prompt only ever appears once; after a denial this silently
                        // records a request and returns false, so send them where they can
                        // actually flip it.
                        if !CGRequestScreenCaptureAccess() {
                            JorvikPermissionWatcher.openSettings(pane: .screenRecording)
                        }
                    }
                }
            } label: {
                Text("Screen Recording")
                Text("To show a pinned window's contents in its overlay.")
            }
        }

        MenuBarVisibilitySettings()

        Section("General") {
            JorvikLaunchAtLoginToggle()
            MenuBarPillToggle { delegate.updateIcon() }
        }
    }
}
