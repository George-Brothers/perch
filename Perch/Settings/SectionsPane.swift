import SwiftUI

struct SectionsPane: View {
    @ObservedObject var preferences: Preferences
    @ObservedObject var menuBar: MenuBarController

    var body: some View {
        Form {
            if menuBar.layoutProblem {
                Section {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.title3)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Perch's dividers are out of order")
                                .font(.headline)
                            Text("The bird ended up left of its own │ line, so Perch would hide itself. Nothing is hidden until you fix this. Reset puts the bird back next to Control Center.")
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Reset") { menuBar.resetPositions() }
                    }
                    .padding(.vertical, 4)
                }
            }

            Section {
                MenuBarDiagram(showsArchived: preferences.archivedSectionEnabled)
                    .padding(.vertical, 8)
            }

            Section("Choose what stays in the menu bar") {
                InstructionRow(number: 1, text: "Click the bird to show your hidden icons and the │ line.")
                InstructionRow(number: 2, text: "Hold ⌘ and drag each icon you always want to see to the right of the │ line.")
                InstructionRow(number: 3, text: "Click the bird again. Everything left of the line hides.")
                if preferences.archivedSectionEnabled {
                    InstructionRow(number: 4, text: "Icons left of the ┆ line are archived. Option-click the bird to see them too.")
                }
                Text("Perch starts with every icon hidden and sits next to Control Center, so the notch can't cover it. New apps add their icons on the far left, so they start out hidden too.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle(isOn: $preferences.archivedSectionEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Archived section")
                        Text("For icons you rarely need. Adds a ┆ line beside the │ line. Icons left of it stay hidden until you Option-click the bird.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Reset divider positions")
                        Text("Puts the bird and its lines back next to Control Center. Your other icons stay put.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Reset") { menuBar.resetPositions() }
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct InstructionRow: View {
    let number: Int
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number)")
                .font(.callout.weight(.semibold).monospacedDigit())
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Circle().fill(Color.accentColor))
            Text(text)
        }
    }
}

/// A drawing of the menu bar that labels each section.
private struct MenuBarDiagram: View {
    let showsArchived: Bool

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                if showsArchived {
                    group(symbols: ["externaldrive", "printer"], label: "Archived", tint: .secondary)
                    divider(dashed: true)
                }
                group(symbols: ["cloud", "music.note", "waveform"], label: "Hidden", tint: .orange)
                divider(dashed: false)
                group(symbols: ["cpu", "wifi", "battery.75percent"], label: "Shown", tint: .green)
                VStack(spacing: 6) {
                    Image(systemName: "bird.fill")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                        .frame(height: 22)
                    Text("Perch").font(.caption.weight(.semibold)).foregroundStyle(Color.accentColor)
                }
                Spacer(minLength: 0)
                Image(systemName: "switch.2")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(height: 22)
                    .padding(.bottom, 18)
                Text("Tue 10:41")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(height: 22)
                    .padding(.bottom, 18)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
            )
        }
    }

    private func group(symbols: [String], label: String, tint: Color) -> some View {
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                ForEach(symbols, id: \.self) { name in
                    Image(systemName: name)
                        .font(.system(size: 13, weight: .medium))
                }
            }
            .frame(height: 22)
            .padding(.horizontal, 8)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(tint.opacity(0.14))
            )
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint)
        }
    }

    private func divider(dashed: Bool) -> some View {
        VStack(spacing: 6) {
            Rectangle()
                .fill(.clear)
                .frame(width: 2, height: 18)
                .overlay(
                    Path { path in
                        path.move(to: CGPoint(x: 1, y: 0))
                        path.addLine(to: CGPoint(x: 1, y: 18))
                    }
                    .stroke(Color.primary.opacity(0.7),
                            style: StrokeStyle(lineWidth: dashed ? 2 : 1.5, lineCap: .round,
                                               dash: dashed ? [0.5, 3.5] : []))
                )
                .frame(height: 22)
            Text(" ").font(.caption)
        }
    }
}
