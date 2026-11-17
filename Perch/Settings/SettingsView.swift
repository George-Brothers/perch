import SwiftUI

struct SettingsView: View {
    @ObservedObject var navigation: SettingsNavigation
    let preferences: Preferences
    let permissions: Permissions
    let engine: LayoutEngine

    var body: some View {
        NavigationSplitView {
            List(SettingsPane.allCases, selection: $navigation.pane) { pane in
                NavigationLink(value: pane) {
                    Label(pane.title, systemImage: pane.symbol)
                }
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 170, max: 220)
        } detail: {
            detail(for: navigation.pane ?? .general)
                .navigationTitle((navigation.pane ?? .general).title)
        }
    }

    @ViewBuilder
    private func detail(for pane: SettingsPane) -> some View {
        switch pane {
        case .general: GeneralPane(preferences: preferences, permissions: permissions)
        case .icons: IconsPane(engine: engine, preferences: preferences, permissions: permissions)
        case .about: AboutPane()
        }
    }
}

struct IconsPane: View {
    let engine: LayoutEngine
    let preferences: Preferences
    let permissions: Permissions

    var body: some View {
        Form {
            Section {
                ArrangeList(engine: engine, preferences: preferences, permissions: permissions)
            } footer: {
                Text("**Always** stays in the menu bar. **Auto** stays when there's room and hides when there isn't. **Hide** shows when you click Perch's icon.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { engine.refresh() }
    }
}
