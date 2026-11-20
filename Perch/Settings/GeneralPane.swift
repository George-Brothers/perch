import SwiftUI

struct GeneralPane: View {
    @ObservedObject var preferences: Preferences

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

            Section("Clicking the Perch icon") {
                LabeledContent("Click", value: "Show or hide your hidden icons")
                LabeledContent("Option-click", value: preferences.archivedSectionEnabled
                    ? "Also show archived icons"
                    : "Also show archived icons (turn on Archived in Sections)")
                LabeledContent("Right-click", value: "Open the Perch menu")
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: refreshLoginState)
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
