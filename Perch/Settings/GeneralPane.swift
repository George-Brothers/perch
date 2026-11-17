import SwiftUI

struct GeneralPane: View {
    @ObservedObject var preferences: Preferences
    @ObservedObject var permissions: Permissions

    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var needsApproval = LaunchAtLogin.needsApproval
    @State private var loginError: String?

    var body: some View {
        Form {
            Section("Startup") {
                Toggle("Open Perch when you log in", isOn: Binding(
                    get: { launchAtLogin },
                    set: setLaunchAtLogin
                ))
                if needsApproval {
                    HStack {
                        Text("macOS needs your OK in Login Items before this works.")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Open Login Items") { LaunchAtLogin.openLoginItemsSettings() }
                    }
                }
                if let loginError {
                    Text(loginError)
                        .font(.callout)
                        .foregroundStyle(.red)
                }
            }

            Section("Menu bar icon") {
                IconStylePicker(selection: $preferences.iconStyle)
            }

            Section("Clicking the bird") {
                Picker("Click", selection: $preferences.clickAction) {
                    ForEach(ClickAction.allCases) { action in
                        Text(action.title).tag(action)
                    }
                }
                LabeledContent("Option-click", value: preferences.clickAction == .openPanel
                    ? ClickAction.revealInBar.title
                    : ClickAction.openPanel.title)
                LabeledContent("Right-click", value: "Perch menu")
            }

            Section("Permissions") {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Accessibility")
                        Text("Lets Perch list your menu bar icons and open them for you.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if permissions.hasAccessibility {
                        Label("Allowed", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Button("Allow…") { permissions.requestAccessibility() }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            refreshLoginState()
            permissions.refresh()
        }
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

private struct IconStylePicker: View {
    @Binding var selection: PerchIconStyle

    var body: some View {
        HStack(spacing: 12) {
            ForEach(PerchIconStyle.allCases) { style in
                Button {
                    selection = style
                } label: {
                    VStack(spacing: 8) {
                        Image(systemName: style.symbolName(revealed: false))
                            .font(.system(size: 18, weight: .medium))
                            .frame(height: 24)
                        Text(style.title)
                            .font(.callout)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(selection == style ? Color.accentColor.opacity(0.15) : Color.primary.opacity(0.04))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(selection == style ? Color.accentColor : Color.primary.opacity(0.1),
                                          lineWidth: selection == style ? 2 : 1)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == style ? .isSelected : [])
            }
        }
        .padding(.vertical, 4)
    }
}
