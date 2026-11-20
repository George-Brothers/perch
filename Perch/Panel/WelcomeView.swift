import AppKit
import SwiftUI

/// The Guide: shown the first time Perch runs, and again from Settings → Guide.
/// Topics are listed on the left; pick any one to learn it, with a button on
/// most to try it right away. Next steps through them in order, for a first run.
@MainActor
final class WelcomeWindowController {
    static let shownKey = "welcomeShown"

    private let makeContent: (@escaping () -> Void) -> AnyView
    private var window: NSWindow?
    /// Runs when the window closes, however it was closed.
    var onClose: (() -> Void)?
    private var closeObserver: NSObjectProtocol?

    init(makeContent: @escaping (_ close: @escaping () -> Void) -> AnyView) {
        self.makeContent = makeContent
    }

    var isOpen: Bool { window?.isVisible == true }

    func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: makeContent { [weak self] in self?.window?.close() })
            let window = NSWindow(contentViewController: hosting)
            window.title = "Perch Guide"
            window.styleMask = [.titled, .closable]
            window.titleVisibility = .hidden
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: WelcomeView.size.width, height: WelcomeView.size.height))
            window.center()
            closeObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.onClose?() }
            }
            self.window = window
        } else if let window, !window.isVisible {
            // Start from Welcome each time.
            window.contentViewController = NSHostingController(
                rootView: makeContent { [weak self] in self?.window?.close() }
            )
            window.center()
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
    }
}

struct WelcomeView: View {
    @ObservedObject var permissions: Permissions
    @ObservedObject var preferences: Preferences
    let onShowHiddenIcons: () -> Void
    let onOpenArrange: () -> Void
    let onOpenSettings: () -> Void
    let onDone: () -> Void

    /// The topic list, then the topic itself.
    static let sidebarWidth: CGFloat = 190
    static let pageWidth: CGFloat = 640
    static let size = CGSize(width: sidebarWidth + 1 + pageWidth, height: 530)

    enum Page: Int, CaseIterable {
        case hello, access, hidden, arrange, spotlight, settings

        var title: String {
            switch self {
            case .hello: "Welcome"
            case .access: "Accessibility"
            case .hidden: "Hidden Icons"
            case .arrange: "Arrange"
            case .spotlight: "Spotlight"
            case .settings: "Settings"
            }
        }

        var symbol: String {
            switch self {
            case .hello: "hand.wave"
            case .access: "lock.shield"
            case .hidden: "eye.slash"
            case .arrange: "arrow.left.and.right"
            case .spotlight: "magnifyingglass"
            case .settings: "gearshape"
            }
        }
    }

    @State private var page: Page = .hello

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            topic
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .animation(.easeInOut(duration: 0.2), value: page)
        .onAppear { permissions.refresh() }
    }

    // MARK: - Topics

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Page.allCases, id: \.self) { each in
                Button { page = each } label: {
                    HStack(spacing: 8) {
                        Image(systemName: each.symbol)
                            .font(.system(size: 13))
                            .frame(width: 20)
                            .foregroundStyle(each == page ? Color.white : Color.accentColor)
                        Text(each.title)
                            .font(.system(size: 13))
                        Spacer(minLength: 0)
                        if each == .access {
                            // Whether it still needs doing.
                            Circle()
                                .fill(permissions.hasAccessibility ? Color.green : Color.orange)
                                .frame(width: 7, height: 7)
                        }
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 30)
                    .foregroundStyle(each == page ? Color.white : Color.primary)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(each == page ? Color.accentColor : Color.clear)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.top, 14)
        .frame(width: Self.sidebarWidth)
        .frame(maxHeight: .infinity)
        .background(Color.primary.opacity(0.03))
    }

    private var topic: some View {
        VStack(spacing: 0) {
            ZStack {
                LinearGradient(colors: [Color.accentColor.opacity(0.18), Color.accentColor.opacity(0.04)],
                               startPoint: .top, endPoint: .bottom)
                illustration
                    .id(page)
                    .transition(.opacity)
            }
            .frame(height: 210)

            VStack(alignment: .leading, spacing: 12) {
                content
                    .id(page)
                    .transition(.opacity)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 36)
            .padding(.top, 24)
            .frame(maxWidth: .infinity, alignment: .leading)

            footer
        }
        .frame(width: Self.pageWidth)
    }

    // MARK: - Pages

    @ViewBuilder
    private var content: some View {
        switch page {
        case .hello:
            title("Welcome to Perch")
            para("Perch keeps your menu bar organized. Icons that don't fit, or that you choose to hide, stay out of view and remain one click away.")
            para("Perch works with the menu bar macOS already provides. It never moves your pointer, and your apps never restart. Pick any topic on the left to see how it works, or choose Get Started to go through them in order.")

        case .access:
            title("Allow Accessibility access")
            para("Perch uses Accessibility to locate menu bar icons, reposition them, and open hidden ones. It uses this access for nothing else and never controls your pointer or keyboard.")
            HStack(spacing: 12) {
                if permissions.hasAccessibility {
                    Label("Accessibility access granted", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.system(size: 13, weight: .medium))
                } else {
                    Button("Allow Accessibility…") { permissions.requestAccessibility() }
                        .buttonStyle(.borderedProminent)
                    Text("Turn on Perch in the list that opens, then return here.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 4)

        case .hidden:
            title("View hidden icons")
            para("Click any empty area of the menu bar to show Perch's bar, which holds every icon that is hidden or doesn't fit. Click an icon to open its menu in place.")
            para("Click the empty area again, or anywhere else, to close it.")
            tryButton("Show Hidden Icons", action: onShowHiddenIcons)

        case .arrange:
            title("Arrange your menu bar")
            para("Right-click any empty area of the menu bar to open Arrange. It shows your menu bar as one strip: hidden icons are dimmed, left of the line, and the icons in your menu bar are to its right. Drag an icon across the line to hide or show it, or drag the line itself.")
            para("Order sets priority. When the menu bar runs out of space, icons on the left move to Hidden first. Changes take effect when you close Arrange, and Apple's icons briefly redraw. In Settings, you can have Arrange open over the menu bar instead.")
            tryButton("Open Arrange", action: onOpenArrange)

        case .spotlight:
            title("Search with Spotlight")
            para("Press ⌘Space and type the name of any menu bar icon, such as Wi-Fi, Battery or an app. Choose the result to open its menu, even if the icon is hidden.")
            para("Perch also adds Shortcuts actions for showing hidden icons and opening Arrange.")

        case .settings:
            title("Settings")
            para("To open Settings, click the gear in Arrange. You can also press ⌘, while Arrange is open, or open Perch from the Applications folder.")
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
                GridRow {
                    Text("Open at login").foregroundStyle(.secondary)
                    LoginToggle()
                }
                GridRow {
                    Text("In the menu bar").foregroundStyle(.secondary)
                    Picker("", selection: $preferences.barItem) {
                        ForEach(PerchBarItem.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .fixedSize()
                }
            }
            .font(.system(size: 13))
            .padding(.top, 2)
            Text(barItemNote)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            tryButton("Open Settings", action: onOpenSettings)
        }
    }

    private var barItemNote: String {
        switch preferences.barItem {
        case .none: "Nothing: Perch adds no item to the menu bar. Click any empty area to use it."
        case .line: "Line: a thin line marks where hidden icons begin. Clicking it works like clicking empty space."
        case .icon: "Icon: a small Perch icon in the menu bar that you can click."
        }
    }

    private func title(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 22, weight: .semibold))
            .padding(.bottom, 2)
    }

    private func para(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func tryButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(label, action: action)
            .controlSize(.regular)
            .padding(.top, 4)
    }

    // MARK: - Footer

    /// Next, for going through every topic in order. Nothing makes you.
    private var footer: some View {
        HStack {
            Spacer()
            if page == .settings {
                Button("Done", action: onDone)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            } else {
                Button(nextTitle) { move(1) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .controlSize(.large)
        .padding(.horizontal, 36)
        .padding(.vertical, 20)
    }

    private var nextTitle: String {
        let next = Page(rawValue: page.rawValue + 1)?.title ?? ""
        switch page {
        case .hello: return "Get Started"
        case .access where !permissions.hasAccessibility: return "Later"
        default: return "Next: \(next)"
        }
    }

    private func move(_ step: Int) {
        if let next = Page(rawValue: page.rawValue + step) { page = next }
    }

    // MARK: - Pictures

    @ViewBuilder
    private var illustration: some View {
        switch page {
        case .hello:
            VStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 96, height: 96)
                MiniMenuBar(highlightEmpty: false)
            }
        case .access:
            Image(systemName: permissions.hasAccessibility ? "checkmark.shield.fill" : "hand.raised.fill")
                .font(.system(size: 64, weight: .light))
                .foregroundStyle(permissions.hasAccessibility ? Color.green : Color.accentColor)
                .contentTransition(.symbolEffect(.replace))
        case .hidden:
            VStack(spacing: 8) {
                MiniMenuBar(highlightEmpty: true)
                MiniDrawer()
                    .padding(.leading, 230)
            }
        case .arrange:
            MiniArrange()
        case .spotlight:
            MiniSpotlight()
        case .settings:
            MiniSettings(barItem: preferences.barItem)
        }
    }
}

/// Launch at login, as a plain switch.
private struct LoginToggle: View {
    @State private var on = LaunchAtLogin.isEnabled || LaunchAtLogin.needsApproval

    var body: some View {
        Toggle("", isOn: Binding(get: { on }, set: { value in
            try? LaunchAtLogin.setEnabled(value)
            on = LaunchAtLogin.isEnabled || LaunchAtLogin.needsApproval
        }))
        .labelsHidden()
        .toggleStyle(.switch)
        .controlSize(.small)
    }
}

// MARK: - Drawings of Perch, for the tour

/// A small menu bar: app menus on the left, icons on the right, and
/// optionally the empty space in between marked as the place to click.
private struct MiniMenuBar: View {
    let highlightEmpty: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "apple.logo").font(.system(size: 11))
            Text("Finder").font(.system(size: 11, weight: .bold))
            ForEach(["File", "Edit", "View"], id: \.self) { Text($0).font(.system(size: 11)) }
            ZStack {
                if highlightEmpty {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                        .background(RoundedRectangle(cornerRadius: 5).fill(Color.accentColor.opacity(0.12)))
                    Image(systemName: "cursorarrow.click")
                        .font(.system(size: 15))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .frame(width: 130, height: 20)
            ForEach(["wifi", "battery.75percent", "switch.2"], id: \.self) {
                Image(systemName: $0).font(.system(size: 11))
            }
            Text("9:41").font(.system(size: 11))
        }
        .padding(.horizontal, 14)
        .frame(height: 28)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .shadow(color: .black.opacity(0.08), radius: 3, y: 1)
    }
}

/// Perch's bar, hanging under the menu bar.
private struct MiniDrawer: View {
    var body: some View {
        HStack(spacing: 14) {
            ForEach(["cloud", "camera.viewfinder", "waveform", "chart.bar.fill"], id: \.self) {
                Image(systemName: $0).font(.system(size: 12))
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 28)
        .perchSurface(Capsule(style: .continuous))
        .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
    }
}

/// Arrange: one strip, hidden icons dimmed left of the line, with an icon
/// being dragged across it.
private struct MiniArrange: View {
    private let shown = ["chart.bar.fill", "wifi", "battery.75percent"]
    private let hidden = ["cloud", "camera.viewfinder"]

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: "gearshape")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            ForEach(hidden, id: \.self) { Image(systemName: $0).font(.system(size: 12)).opacity(0.5) }
            Capsule().fill(Color.white.opacity(0.5)).frame(width: 2, height: 16)
            ForEach(shown, id: \.self) { Image(systemName: $0).font(.system(size: 12)) }
        }
        .padding(.horizontal, 16)
        .frame(height: 36)
        .perchSurface(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: .black.opacity(0.2), radius: 5, y: 2)
        .overlay(alignment: .topLeading) {
            // An icon on its way across the line, into Hidden.
            HStack(spacing: 2) {
                Image(systemName: "arrow.down.left")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                Image(systemName: "waveform")
                    .font(.system(size: 12))
                    .frame(width: 26, height: 22)
                    .background(Color(white: 0.24), in: RoundedRectangle(cornerRadius: 6))
                    .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
            }
            .offset(x: 118, y: 30)
        }
        .padding(.bottom, 24)
    }
}

/// Spotlight, finding a menu bar icon.
private struct MiniSpotlight: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                Text("Wi-Fi").font(.system(size: 17))
                Spacer()
                Text("⌘Space").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .frame(height: 42)
            Divider()
            HStack(spacing: 10) {
                Image(systemName: "wifi")
                    .frame(width: 26, height: 26)
                    .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
                VStack(alignment: .leading, spacing: 1) {
                    Text("Wi-Fi").font(.system(size: 13, weight: .medium))
                    Text("Menu bar icon · Perch").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(10)
            .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            .padding(6)
        }
        .frame(width: 340)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
    }
}

/// Settings, small, with where to find it.
private struct MiniSettings: View {
    let barItem: PerchBarItem

    var body: some View {
        HStack(spacing: 22) {
            VStack(alignment: .leading, spacing: 6) {
                Text("In Arrange")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize()
                // The left end of Arrange, with its gear.
                HStack(spacing: 6) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 12))
                        .foregroundStyle(.white)
                        .frame(width: 24, height: 24)
                        .background(Color.accentColor, in: Circle())
                    HStack(spacing: 10) {
                        ForEach(["cloud", "camera.viewfinder"], id: \.self) {
                            Image(systemName: $0).font(.system(size: 11)).opacity(0.5)
                        }
                        Capsule().fill(Color.white.opacity(0.5)).frame(width: 2, height: 14)
                        Image(systemName: "wifi").font(.system(size: 11))
                    }
                    .padding(.trailing, 6)
                }
                .padding(6)
                .perchSurface(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
            }

            Image(systemName: "arrow.right").foregroundStyle(.secondary)

            VStack(spacing: 0) {
                settingRow("Open at login") {
                    Capsule().fill(Color.accentColor).frame(width: 26, height: 15)
                        .overlay(alignment: .trailing) { Circle().fill(.white).frame(width: 13, height: 13).padding(1) }
                }
                Divider()
                settingRow("In the menu bar") { Text(barItem.title).font(.system(size: 11)).foregroundStyle(.secondary) }
                Divider()
                settingRow("Icon spacing") {
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.2)).frame(width: 60, height: 3)
                        Capsule().fill(Color.accentColor).frame(width: 34, height: 3)
                        Circle().fill(.white).frame(width: 12, height: 12)
                            .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
                            .offset(x: 28)
                    }
                }
            }
            .frame(width: 210)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .shadow(color: .black.opacity(0.12), radius: 5, y: 2)
        }
    }

    private func settingRow(_ title: String, @ViewBuilder trailing: () -> some View) -> some View {
        HStack {
            Text(title).font(.system(size: 11))
            Spacer()
            trailing()
        }
        .padding(.horizontal, 12)
        .frame(height: 30)
    }
}
