import SwiftUI

struct SettingsView: View {
    @ObservedObject var navigation: SettingsNavigation
    @ObservedObject var preferences: Preferences
    @ObservedObject var permissions: Permissions
    @ObservedObject var menuBar: MenuBarController

    var body: some View {
        NavigationSplitView {
            List(SettingsPane.allCases, selection: $navigation.pane) { pane in
                NavigationLink(value: pane) {
                    Label(pane.title, systemImage: pane.symbol)
                }
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 240)
        } detail: {
            detail(for: navigation.pane ?? .general)
                .navigationTitle((navigation.pane ?? .general).title)
        }
    }

    @ViewBuilder
    private func detail(for pane: SettingsPane) -> some View {
        switch pane {
        case .general: GeneralPane(preferences: preferences, permissions: permissions)
        case .sections: SectionsPane(preferences: preferences, menuBar: menuBar)
        case .autoHide: AutoHidePane(preferences: preferences)
        case .about: AboutPane()
        }
    }
}
