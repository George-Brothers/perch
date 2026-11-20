import SwiftUI

struct AboutPane: View {
    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "Version \(short) (\(build))"
    }

    var body: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 112, height: 112)
            Text("Perch")
                .font(.largeTitle.weight(.semibold))
            Text(version)
                .foregroundStyle(.secondary)
            Text("A light menu bar manager for macOS.")
                .padding(.top, 4)
            Text("Free and open source under the MIT License.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Quit Perch") { NSApp.terminate(nil) }
                .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
