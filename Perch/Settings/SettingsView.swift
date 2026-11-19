import SwiftUI

/// Settings: one short page. Arranging icons lives in Arrange.
struct SettingsView: View {
    @ObservedObject var preferences: Preferences
    @ObservedObject var permissions: Permissions
    @ObservedObject var engine: LayoutEngine
    let onShowWelcome: () -> Void

    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var needsApproval = LaunchAtLogin.needsApproval
    @State private var loginError: String?
    @State private var explainingDrawer = false
    @State private var spacing = Double(MenuBarSpacing.current)
    @State private var appliedSpacing = MenuBarSpacing.current

    var body: some View {
        Form {
            if !permissions.hasAccessibility {
                Section {
                    LabeledContent {
                        Button("Allow…") { permissions.requestAccessibility() }
                    } label: {
                        Text("Accessibility")
                        Text("Perch needs it to see and move icons.")
                    }
                }
            }

            Section {
                Toggle("Open at login", isOn: Binding(get: { launchAtLogin }, set: setLaunchAtLogin))
                if needsApproval {
                    LabeledContent("macOS needs your OK") {
                        Button("Login Items…") { LaunchAtLogin.openLoginItemsSettings() }
                    }
                }
                if let loginError {
                    Text(loginError).foregroundStyle(.red)
                }
                Picker("In the menu bar", selection: $preferences.barItem) {
                    ForEach(PerchBarItem.allCases) { Text($0.title).tag($0) }
                }
                if preferences.barItem == .icon {
                    Picker("Icon", selection: $preferences.iconStyle) {
                        ForEach(PerchIconStyle.allCases) { style in
                            Label(style.title, systemImage: style.symbolName(revealed: false)).tag(style)
                        }
                    }
                }
                Picker("Arrange", selection: $preferences.arrangeStyle) {
                    ForEach(ArrangeStyle.allCases) { Text($0.title).tag($0) }
                }
                .help("Where Arrange opens when you right-click the menu bar.")
            }

            Section {
                Toggle("Exact icon pictures", isOn: drawerBinding)
                    .help("Show hidden icons as they look in the menu bar. Uses Screen Recording.")
                if preferences.drawerEnabled && !permissions.hasScreenRecording {
                    LabeledContent("Needs Screen Recording") {
                        Button("Open…") { permissions.requestScreenRecording() }
                        Button("Restart Perch") { permissions.relaunch() }
                    }
                }
                LabeledContent("Icon spacing") {
                    HStack(spacing: 10) {
                        // No step: macOS draws a tick for every one.
                        Slider(value: $spacing,
                               in: Double(MenuBarSpacing.range.lowerBound)...Double(MenuBarSpacing.range.upperBound))
                            .frame(width: 120)
                        Button("Apply") { applySpacing() }
                            .disabled(Int(spacing.rounded()) == appliedSpacing || MenuBarSpacing.isApplying
                                      || engine.isArranging || engine.hasQueuedMoves)
                    }
                }
                .help("Tighter fits more icons. Apple's icons change right away, others the next time their app opens.")
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack {
                Text("Perch \(version)")
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("Guide", action: onShowWelcome)
                    .buttonStyle(.link)
                    .foregroundStyle(.secondary)
                    .padding(.trailing, 14)
                Button("Quit") { NSApp.terminate(nil) }
                    .buttonStyle(.link)
                    .foregroundStyle(.secondary)
            }
            .font(.callout)
            .padding(.horizontal, 24)
            .padding(.bottom, 16)
        }
        .frame(width: 420)
        .onAppear {
            refreshLoginState()
            permissions.refresh()
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

    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    }

    private func applySpacing() {
        let value = Int(spacing.rounded())
        MenuBarSpacing.set(value)
        appliedSpacing = value
        MenuBarSpacing.apply()
    }

    /// Turning pictures on explains the permission first, unless Perch already has it.
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

    private func setLaunchAtLogin(_ enabled: Bool) {
        loginError = nil
        do {
            try LaunchAtLogin.setEnabled(enabled)
        } catch {
            loginError = "Couldn't change this: \(error.localizedDescription)"
        }
        refreshLoginState()
    }

    private func refreshLoginState() {
        launchAtLogin = LaunchAtLogin.isEnabled || LaunchAtLogin.needsApproval
        needsApproval = LaunchAtLogin.needsApproval
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
