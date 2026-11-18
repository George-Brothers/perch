import SwiftUI

struct SettingsView: View {
    @ObservedObject var navigation: SettingsNavigation
    let preferences: Preferences
    let permissions: Permissions
    let engine: LayoutEngine
    let images: IconImages

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
        case .features: FeaturesPane(preferences: preferences, permissions: permissions, engine: engine)
        case .icons: IconsPane(engine: engine, preferences: preferences, permissions: permissions, images: images)
        case .about: AboutPane()
        }
    }
}

struct IconsPane: View {
    let engine: LayoutEngine
    let preferences: Preferences
    let permissions: Permissions
    let images: IconImages

    var body: some View {
        Form {
            Section {
                ArrangeShelves(engine: engine, preferences: preferences, permissions: permissions, images: images)
                    .padding(.vertical, 4)
            } footer: {
                Text("Drag icons between shelves. Perch moves them in the menu bar for you.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            Task {
                let items = await engine.rescan()
                if preferences.drawerEnabled {
                    await images.capture(items.filter { $0.section != .notShowing })
                }
            }
        }
    }
}
