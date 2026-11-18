import SwiftUI

struct GeneralPane: View {
    @ObservedObject var preferences: Preferences
    @ObservedObject var permissions: Permissions

    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var needsApproval = LaunchAtLogin.needsApproval
    @State private var loginError: String?

    var body: some View {
        Form {
            Section {
                Toggle("Open Perch when you log in", isOn: Binding(get: { launchAtLogin }, set: setLaunchAtLogin))
                if needsApproval {
                    LabeledContent("macOS needs your OK in Login Items") {
                        Button("Open Login Items") { LaunchAtLogin.openLoginItemsSettings() }
                    }
                }
                if let loginError {
                    Text(loginError).font(.callout).foregroundStyle(.red)
                }
            }

            Section {
                Picker("In the menu bar", selection: $preferences.barItem) {
                    ForEach(PerchBarItem.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                if preferences.barItem == .icon {
                    Picker("Icon", selection: $preferences.iconStyle) {
                        ForEach(PerchIconStyle.allCases) { style in
                            Label(style.title, systemImage: style.symbolName(revealed: false)).tag(style)
                        }
                    }
                }
            } footer: {
                Text(barItemFooter).foregroundStyle(.secondary)
            }

            Section {
                Toggle("Hide icons again automatically", isOn: $preferences.autoRehideEnabled)
                if preferences.autoRehideEnabled {
                    LabeledContent("After") {
                        HStack {
                            Slider(value: $preferences.rehideDelay, in: 5...60)
                                .frame(minWidth: 140)
                            Text("\(Int(preferences.rehideDelay.rounded())) s")
                                .monospacedDigit()
                                .frame(width: 36, alignment: .trailing)
                        }
                    }
                    Toggle("Also when I click outside the menu bar", isOn: $preferences.rehideOnClickOutside)
                }
            } footer: {
                Text("Perch waits while a menu is open.")
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Accessibility") {
                    if permissions.hasAccessibility {
                        Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Button("Allow…") { permissions.requestAccessibility() }
                    }
                }
            } footer: {
                Text("Lets Perch see and move your menu bar icons.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            refreshLoginState()
            permissions.refresh()
        }
    }

    private var barItemFooter: String {
        let click = "Click empty space in the menu bar to show or hide icons. Right-click it to arrange them."
        switch preferences.barItem {
        case .none:
            return permissions.hasAccessibility
                ? click
                : "Perch's icon stays until Perch has Accessibility, which it needs to notice clicks on empty space."
        case .line: return "A thin line, which you can click like the icon. " + click
        case .icon: return click
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
