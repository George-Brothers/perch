import SwiftUI

/// Shown once, the first time Perch runs: the three things to know, and
/// Accessibility if Perch doesn't have it yet.
struct WelcomeView: View {
    @ObservedObject var permissions: Permissions
    let onDone: () -> Void

    static let shownKey = "welcomeShown"

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Perch is in your menu bar")
                .font(.system(size: 15, weight: .semibold))

            VStack(alignment: .leading, spacing: 10) {
                step("cursorarrow.click", "Click empty space in the menu bar to see icons that don't fit.")
                step("contextualmenu.and.cursorarrow", "Right-click it to put your icons in order.")
                step("magnifyingglass", "Press ⌘Space and type an icon's name to open it.")
            }

            HStack {
                if !permissions.hasAccessibility {
                    Text("Perch needs Accessibility to see your icons.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 12)
                    Button("Allow…") { permissions.requestAccessibility() }
                        .buttonStyle(.borderedProminent)
                } else {
                    Spacer()
                    Button("Done", action: onDone)
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(18)
        .frame(width: 330, alignment: .leading)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
        )
        .onAppear { permissions.refresh() }
    }

    private func step(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 20)
            Text(text)
                .font(.system(size: 13))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
