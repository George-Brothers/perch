import SwiftUI

/// Optional features, each with its own switch.
struct FeaturesPane: View {
    @ObservedObject var preferences: Preferences
    @ObservedObject var permissions: Permissions
    let engine: LayoutEngine
    @State private var explainingDrawer = false
    @State private var spacing = Double(MenuBarSpacing.current)
    @State private var appliedSpacing = MenuBarSpacing.current
    @State private var confirmingReopen = false
    @State private var appsToReopen: [NSRunningApplication] = []

    var body: some View {
        Form {
            Section {
                Toggle(isOn: drawerBinding) {
                    Text("Hidden icons drawer")
                    Text("Click Perch's menu bar icon and hidden icons drop down in a small bar under the menu bar. Needs Screen Recording; Perch asks only if you turn this on.")
                }
                if preferences.drawerEnabled && !permissions.hasScreenRecording {
                    LabeledContent {
                        HStack {
                            Button("Open System Settings") { permissions.requestScreenRecording() }
                            Button("Restart Perch") { permissions.relaunch() }
                        }
                    } label: {
                        Text("Waiting for Screen Recording")
                        Text("Turn Perch on in Screen Recording, then restart Perch. Until then, hidden icons show in the menu bar.")
                    }
                }
            }

            Section {
                Toggle(isOn: $preferences.searchEnabled) {
                    Text("Search shortcut")
                    Text("Press it anywhere, type part of an icon's name, and press Return to open it.")
                }
                if preferences.searchEnabled {
                    LabeledContent {
                        ShortcutRecorder(shortcut: $preferences.searchShortcut, recording: $preferences.isRecordingShortcut)
                    } label: {
                        Text("Shortcut")
                        if preferences.searchShortcutTaken {
                            Text("Another app already uses this shortcut. Pick a different one.")
                                .foregroundStyle(.red)
                        }
                    }
                }
            }

            Section {
                LabeledContent {
                    HStack(spacing: 8) {
                        Text("Tight").font(.caption).foregroundStyle(.secondary)
                        Slider(value: $spacing, in: Double(MenuBarSpacing.range.lowerBound)...Double(MenuBarSpacing.range.upperBound), step: 1)
                            .frame(minWidth: 160)
                        Text("Default").font(.caption).foregroundStyle(.secondary)
                    }
                } label: {
                    Text("Icon spacing")
                    Text("Fit more icons in the menu bar.")
                }
                SpacingPreview(spacing: CGFloat(spacing.rounded()))
                LabeledContent("Reopens apps with menu bar icons") {
                    Button("Apply…") {
                        Task {
                            // The list you confirm is exactly the list Perch reopens.
                            appsToReopen = MenuBarSpacing.appsToReopen(await engine.rescan())
                            confirmingReopen = true
                        }
                    }
                        .disabled(Int(spacing.rounded()) == appliedSpacing || MenuBarSpacing.isApplying)
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Reopen menu bar apps?", isPresented: $confirmingReopen) {
            Button("Reopen Apps") { applySpacing() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Perch will quit and reopen \(reopenList) so they use the new spacing. Save any work in them first.")
        }
        .onAppear {
            permissions.refresh()
            // Settings stays alive between openings; drop an edit that was never applied.
            appliedSpacing = MenuBarSpacing.current
            spacing = Double(appliedSpacing)
        }
        .sheet(isPresented: $explainingDrawer) {
            DrawerPermissionSheet(
                onContinue: {
                    explainingDrawer = false
                    preferences.drawerEnabled = true
                    permissions.requestScreenRecording()
                },
                onCancel: { explainingDrawer = false }
            )
        }
    }

    private var reopenList: String {
        let names = Set(appsToReopen.compactMap(\.localizedName)).sorted()
        return (names + ["Control Center", "Perch"]).joined(separator: ", ")
    }

    private func applySpacing() {
        let value = Int(spacing.rounded())
        MenuBarSpacing.set(value)
        appliedSpacing = value
        MenuBarSpacing.reopenMenuBarApps(appsToReopen)
    }

    /// Turning the drawer on explains the permission first, unless Perch already has it.
    private var drawerBinding: Binding<Bool> {
        Binding(
            get: { preferences.drawerEnabled },
            set: { on in
                if on && !permissions.hasScreenRecording {
                    explainingDrawer = true
                } else {
                    preferences.drawerEnabled = on
                }
            }
        )
    }
}

/// Explains why the drawer needs Screen Recording, before macOS asks.
private struct DrawerPermissionSheet: View {
    let onContinue: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: "menubar.dock.rectangle")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.tint)
            Text("Allow Screen Recording for the drawer?")
                .font(.title3.weight(.semibold))
            VStack(alignment: .leading, spacing: 8) {
                Text("To draw other apps' menu bar icons in the drawer, Perch needs Screen Recording permission.")
                Text("Perch takes pictures of menu bar icons while they're on screen, so the drawer can show them later. The pictures stay in memory and are never saved or sent.")
                Text("Don't want that? Leave the drawer off. Perch works the same without it and shows hidden icons in the menu bar instead.")
                    .foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Not Now", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Continue", action: onContinue)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 4)
        }
        .padding(22)
        .frame(width: 400)
    }
}

/// A few menu bar style icons drawn with the chosen spacing.
private struct SpacingPreview: View {
    let spacing: CGFloat
    private let symbols = ["wifi", "battery.75percent", "speaker.wave.2.fill", "moon.fill", "magnifyingglass"]

    var body: some View {
        HStack(spacing: spacing) {
            ForEach(symbols, id: \.self) { Image(systemName: $0) }
        }
        .font(.system(size: 13, weight: .medium))
        .frame(height: 24)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(0.05)))
        .animation(.snappy(duration: 0.15), value: spacing)
    }
}

/// Click, then press the shortcut you want. Escape cancels.
private struct ShortcutRecorder: View {
    @Binding var shortcut: Shortcut
    @Binding var recording: Bool
    @State private var monitor: Any?
    @State private var resignObserver: NSObjectProtocol?

    var body: some View {
        Button {
            recording ? stop() : start()
        } label: {
            Text(recording ? "Type shortcut…" : shortcut.displayString)
                .font(.system(size: 12, weight: .medium).monospaced())
                .frame(minWidth: 90)
        }
        .buttonStyle(.bordered)
        .tint(recording ? .accentColor : nil)
        .onDisappear(perform: stop)
    }

    private func start() {
        recording = true
        // Clicking away from Settings stops recording.
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: NSApp.keyWindow, queue: .main
        ) { _ in
            MainActor.assumeIsolated { stop() }
        }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { // Escape
                stop()
                return nil
            }
            let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
            // A shortcut needs at least one of ⌘ ⌥ ⌃ so plain typing never triggers it.
            guard !modifiers.intersection([.command, .option, .control]).isEmpty else {
                NSSound.beep()
                return nil
            }
            shortcut = Shortcut(keyCode: UInt32(event.keyCode), modifiers: modifiers)
            stop()
            return nil
        }
    }

    private func stop() {
        if recording { recording = false }
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
    }
}
