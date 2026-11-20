import ServiceManagement

/// Wraps SMAppService so Perch can open when you log in.
enum LaunchAtLogin {
    static var status: SMAppService.Status { SMAppService.mainApp.status }

    static var isEnabled: Bool { status == .enabled }

    /// True when macOS registered Perch but wants the user to approve it in Login Items.
    static var needsApproval: Bool { status == .requiresApproval }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    static func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
