import SwiftUI

/// Shown once, the first time Perch runs: the three things to know, and
/// Accessibility if Perch doesn't have it yet. One line each.
struct WelcomeView: View {
    @ObservedObject var permissions: Permissions
    let onDone: () -> Void

    static let shownKey = "welcomeShown"

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                step("Click empty menu bar", "Hidden icons")
                step("Right-click it", "Arrange")
                step("⌘Space, an icon's name", "Open it")
            }
            .font(.system(size: 13))

            HStack {
                if !permissions.hasAccessibility {
                    Text("Perch needs Accessibility first.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 12)
                    Button("Allow…") { permissions.requestAccessibility() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                } else {
                    Spacer()
                    Button("Done", action: onDone)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(16)
        .fixedSize()
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
        )
        .onAppear { permissions.refresh() }
    }

    private func step(_ how: String, _ what: String) -> some View {
        GridRow {
            Text(how).foregroundStyle(.secondary)
            Text(what)
        }
    }
}
