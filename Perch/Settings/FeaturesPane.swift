import SwiftUI

/// Optional features, each with its own switch.
struct FeaturesPane: View {
    @ObservedObject var preferences: Preferences
    @ObservedObject var permissions: Permissions
    let engine: LayoutEngine
    @State private var explainingDrawer = false
    @State private var spacing = Double(MenuBarSpacing.current)
    @State private var appliedSpacing = MenuBarSpacing.current

    var body: some View {
        Form {
            Section {
                Toggle(isOn: drawerBinding) {
                    Text("Exact icon pictures")
                    Text("Show hidden icons in Perch's bar as they look in the menu bar, instead of app icons. Needs Screen Recording; Perch asks only if you turn this on.")
                }
                if preferences.drawerEnabled && !permissions.hasScreenRecording {
                    LabeledContent {
                        HStack {
                            Button("Open System Settings") { permissions.requestScreenRecording() }
                            Button("Restart Perch") { permissions.relaunch() }
                        }
                    } label: {
                        Text("Waiting for Screen Recording")
                        Text("Turn Perch on in Screen Recording, then restart Perch. Until then, Perch's bar shows app icons.")
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
                LabeledContent {
                    Button("Apply") { applySpacing() }
                        .disabled(Int(spacing.rounded()) == appliedSpacing || MenuBarSpacing.isApplying)
                } label: {
                    Text("Apple's icons change right away")
                    Text("Other apps' icons change the next time each app opens. Perch never restarts your apps.")
                }
            }
        }
        .formStyle(.grouped)
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

    private func applySpacing() {
        let value = Int(spacing.rounded())
        MenuBarSpacing.set(value)
        appliedSpacing = value
        MenuBarSpacing.apply()
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
            Text("Allow Screen Recording for exact pictures?")
                .font(.title3.weight(.semibold))
            VStack(alignment: .leading, spacing: 8) {
                Text("To draw other apps' menu bar icons in Perch's bar exactly, Perch needs Screen Recording permission.")
                Text("Perch takes pictures of menu bar icons while they're on screen, so its bar can show them later. The pictures stay in memory and are never saved or sent.")
                Text("Don't want that? Leave this off. Perch works the same and shows app icons instead.")
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
