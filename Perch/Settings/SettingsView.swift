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
                ArrangeBar(engine: engine, preferences: preferences, permissions: permissions,
                           images: images, maxWidth: 560)
                    .padding(.vertical, 4)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            engine.hold(true, for: .settings)
            Task { await images.refresh?() }
        }
        // Moves made here wait until you leave the pane or close Settings.
        .onDisappear { engine.hold(false, for: .settings) }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { note in
            if (note.object as? NSWindow)?.title == SettingsWindowController.title { engine.hold(false, for: .settings) }
        }
    }
}
