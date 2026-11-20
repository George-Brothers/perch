import SwiftUI

struct AutoHidePane: View {
    @ObservedObject var preferences: Preferences

    var body: some View {
        Form {
            Section {
                Toggle("Hide icons again automatically", isOn: $preferences.autoRehideEnabled)
            } footer: {
                Text("Perch waits while a menu is open or your pointer is in the menu bar.")
                    .foregroundStyle(.secondary)
            }

            Section("Hide them") {
                LabeledContent {
                    HStack {
                        Slider(value: $preferences.rehideDelay, in: 3...60)
                            .frame(minWidth: 160)
                        Text("\(Int(preferences.rehideDelay.rounded())) s")
                            .monospacedDigit()
                            .frame(width: 40, alignment: .trailing)
                    }
                } label: {
                    Text("After")
                }
                Toggle("When I click outside the menu bar", isOn: $preferences.rehideOnClickOutside)
                Toggle("When I switch to another app", isOn: $preferences.rehideOnAppSwitch)
            }
            .disabled(!preferences.autoRehideEnabled)
        }
        .formStyle(.grouped)
    }
}
