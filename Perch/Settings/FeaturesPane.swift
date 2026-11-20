import SwiftUI

/// Optional features, each with its own switch.
struct FeaturesPane: View {
    @ObservedObject var preferences: Preferences
    @ObservedObject var permissions: Permissions
    @State private var explainingDrawer = false

    var body: some View {
        Form {
            Section {
                Toggle(isOn: drawerBinding) {
                    Text("Hidden icons drawer")
                    Text("Click the bird and hidden icons drop down in a small bar under the menu bar, so nothing in it has to move.")
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
            } footer: {
                Text("The drawer needs Screen Recording permission to draw other apps' icons. Everything else in Perch works without it.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { permissions.refresh() }
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
                Text("Perch only looks at menu bar icons, only when you open the drawer. Nothing is saved or sent anywhere.")
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
