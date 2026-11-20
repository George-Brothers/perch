import AppKit
import SwiftUI

/// Setup: what plays the first time Perch opens. Four steps in order:
/// welcome, Accessibility, a few choices, and where to go next. Everything
/// it explains in more depth lives in the Guide.
struct SetupView: View {
    @ObservedObject var permissions: Permissions
    @ObservedObject var preferences: Preferences
    let onOpenGuide: () -> Void
    let onDone: () -> Void

    static let size = CGSize(width: 620, height: 560)

    enum Step: Int, CaseIterable {
        case welcome, access, choices, ready
    }

    @State private var step: Step

    /// Setup that comes back after you allow Accessibility picks up there.
    init(permissions: Permissions, preferences: Preferences, startAt: Step = .welcome,
         onOpenGuide: @escaping () -> Void, onDone: @escaping () -> Void) {
        self.permissions = permissions
        self.preferences = preferences
        self.onOpenGuide = onOpenGuide
        self.onDone = onDone
        _step = State(initialValue: startAt)
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                LinearGradient(colors: [Color.accentColor.opacity(0.18), Color.accentColor.opacity(0.03)],
                               startPoint: .top, endPoint: .bottom)
                hero
                    .id(step)
                    .transition(.opacity)
            }
            .frame(height: 250)

            VStack(spacing: 12) {
                content
                    .id(step)
                    .transition(.opacity)
                Spacer(minLength: 0)
            }
            .multilineTextAlignment(.center)
            .padding(.horizontal, 64)
            .padding(.top, 28)
            .frame(maxWidth: .infinity)

            footer
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .animation(.easeInOut(duration: 0.25), value: step)
        .onAppear { permissions.refresh() }
    }

    // MARK: - Steps

    @ViewBuilder
    private var hero: some View {
        switch step {
        case .welcome:
            IntroAnimation()
        case .access:
            Image(systemName: permissions.hasAccessibility ? "checkmark.shield.fill" : "hand.raised.fill")
                .font(.system(size: 64, weight: .light))
                .foregroundStyle(permissions.hasAccessibility ? Color.green : Color.accentColor)
                .contentTransition(.symbolEffect(.replace))
        case .choices:
            MiniMenuBar(highlightEmpty: false, mark: preferences.barItem, iconStyle: preferences.iconStyle)
                .animation(.easeInOut(duration: 0.2), value: preferences.barItem)
        case .ready:
            VStack(alignment: .trailing, spacing: 8) {
                MiniMenuBar(highlightEmpty: true, mark: preferences.barItem, iconStyle: preferences.iconStyle)
                MiniDrawer().padding(.trailing, 120)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case .welcome:
            title("Welcome to Perch")
            para("Perch tucks away the menu bar icons you don't need and keeps every one of them a click away. Setup takes about a minute.")

        case .access:
            title("Allow Accessibility access")
            para("Perch uses Accessibility to find your menu bar icons, move them and open hidden ones. It uses this access for nothing else, and it never controls your pointer or keyboard.")
            if permissions.hasAccessibility {
                Label("Accessibility access granted", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.system(size: 13, weight: .medium))
                    .padding(.top, 4)
            } else {
                VStack(spacing: 6) {
                    Button("Allow Accessibility…") { permissions.requestAccessibility() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                    Text("Turn on Perch in the list that opens, then come back here.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 4)
            }

        case .choices:
            title("Make it yours")
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
                GridRow {
                    Text("Open at login").foregroundStyle(.secondary).gridColumnAlignment(.trailing)
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
                GridRow {
                    Text("Arrange opens").foregroundStyle(.secondary)
                    Picker("", selection: $preferences.arrangeStyle) {
                        ForEach(ArrangeStyle.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .fixedSize()
                }
            }
            .font(.system(size: 13))
            .multilineTextAlignment(.leading)
            .padding(.top, 4)
            para(barItemNote)
                .padding(.top, 4)

        case .ready:
            title("Perch is ready")
            VStack(alignment: .leading, spacing: 10) {
                tip("cursorarrow.click", "Click any empty part of the menu bar to see hidden icons.")
                tip("contextualmenu.and.cursorarrow", "Right-click it to arrange your icons and choose which to hide.")
                tip("book", "The Guide explains everything else. It's in Settings any time.")
            }
            .multilineTextAlignment(.leading)
            .padding(.top, 4)
        }
    }

    private var barItemNote: String {
        switch preferences.barItem {
        case .none: "Perch adds nothing to the menu bar. Click any empty part of it to use Perch. You can change all of this in Settings."
        case .line: "A thin line marks where hidden icons begin. You can change all of this in Settings."
        case .icon: "A small Perch icon you can click. You can change all of this in Settings."
        }
    }

    private func title(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 24, weight: .semibold))
            .padding(.bottom, 2)
    }

    private func para(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func tip(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 15))
                .foregroundStyle(Color.accentColor)
                .frame(width: 24)
            Text(text)
                .font(.system(size: 13))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            if step != .welcome {
                Button("Back") { move(-1) }
            }
            Spacer()
            switch step {
            case .welcome:
                Button("Continue") { move(1) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            case .access:
                if !permissions.hasAccessibility {
                    Button("Not Now") { move(1) }
                }
                Button("Continue") { move(1) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!permissions.hasAccessibility)
            case .choices:
                Button("Continue") { move(1) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            case .ready:
                Button("Open the Guide") {
                    onDone()
                    onOpenGuide()
                }
                Button("Done", action: onDone)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .controlSize(.large)
        .overlay {
            // Where you are.
            HStack(spacing: 7) {
                ForEach(Step.allCases, id: \.self) { each in
                    Circle()
                        .fill(each == step ? Color.primary.opacity(0.7) : Color.primary.opacity(0.18))
                        .frame(width: 6, height: 6)
                }
            }
            .allowsHitTesting(false)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 20)
    }

    private func move(_ by: Int) {
        if let next = Step(rawValue: step.rawValue + by) { step = next }
    }
}

/// The opening: a crowded menu bar whose extra icons tuck away into Perch's
/// bar, giving the app menus their room back.
private struct IntroAnimation: View {
    @Namespace private var namespace
    @State private var showsIcon = false
    @State private var tucked = false

    private let extra = ["cloud", "camera.viewfinder", "waveform", "chart.bar.fill", "doc.on.clipboard", "timer"]
    private let kept = ["wifi", "battery.75percent", "switch.2"]

    var body: some View {
        VStack(spacing: 18) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 84, height: 84)
                .scaleEffect(showsIcon ? 1 : 0.8)
                .opacity(showsIcon ? 1 : 0)

            VStack(alignment: .trailing, spacing: 8) {
                bar
                drawer
            }
        }
        .task {
            withAnimation(.spring(duration: 0.6)) { showsIcon = true }
            try? await Task.sleep(for: .seconds(1.6))
            withAnimation(.spring(duration: 0.9, bounce: 0.2)) { tucked = true }
        }
    }

    private var bar: some View {
        HStack(spacing: 10) {
            Image(systemName: "apple.logo").font(.system(size: 11))
            Text("Finder").font(.system(size: 11, weight: .bold)).lineLimit(1).layoutPriority(1)
            ForEach(["File", "Edit", "View", "Go", "Window", "Help"], id: \.self) {
                Text($0).font(.system(size: 11)).lineLimit(1)
            }
            Spacer(minLength: 0)
            if !tucked {
                ForEach(extra, id: \.self) { icon($0) }
            }
            ForEach(kept, id: \.self) { icon($0).layoutPriority(1) }
            Text("9:41").font(.system(size: 11)).layoutPriority(1)
        }
        .padding(.horizontal, 14)
        .frame(width: 460, height: 28)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .shadow(color: .black.opacity(0.08), radius: 3, y: 1)
    }

    private var drawer: some View {
        HStack(spacing: 10) {
            if tucked {
                ForEach(extra, id: \.self) { icon($0) }
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 28)
        .perchSurface(Capsule(style: .continuous))
        .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
        .opacity(tucked ? 1 : 0)
        .padding(.trailing, 70)
    }

    private func icon(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 12))
            .matchedGeometryEffect(id: symbol, in: namespace)
            .layoutPriority(1)
    }
}
