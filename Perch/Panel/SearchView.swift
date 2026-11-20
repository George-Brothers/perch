import SwiftUI

/// What you've typed and which result is picked. Reset each time search opens.
@MainActor
final class SearchModel: ObservableObject {
    @Published var query = ""
    @Published var selection = 0
    /// Bumped on every open so the field takes focus again.
    @Published private(set) var session = 0

    func reset() {
        query = ""
        selection = 0
        session += 1
    }
}

/// Type a few letters of an icon's name and press Return to open it.
struct SearchView: View {
    @ObservedObject var model: SearchModel
    @ObservedObject var engine: LayoutEngine
    let onOpen: (MenuBarItem) -> Void
    @FocusState private var focused: Bool

    private var results: [MenuBarItem] {
        let all = engine.items
            .filter { $0.section != .notShowing }
            .sorted { $0.frame.minX > $1.frame.minX }
        let query = model.query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return all }
        // Names that start with what you typed come first, then any match.
        let starts = all.filter { $0.searchText.hasPrefix(query) }
        let contains = all.filter { !$0.searchText.hasPrefix(query) && $0.searchText.contains(query) }
        return starts + contains
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
                TextField("Search menu bar", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .focused($focused)
                    .onSubmit(openSelection)
                    .onKeyPress(.downArrow) { moveSelection(1); return .handled }
                    .onKeyPress(.upArrow) { moveSelection(-1); return .handled }
            }
            .padding(.horizontal, 14)
            .frame(height: 44)

            if !results.isEmpty {
                Divider()
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 1) {
                            ForEach(Array(results.enumerated()), id: \.element.id) { index, item in
                                SearchRow(item: item, selected: index == clampedSelection)
                                .id(item.id)
                                .onTapGesture { onOpen(item) }
                                .onHover { if $0 { model.selection = index } }
                            }
                        }
                        .padding(6)
                    }
                    .frame(maxHeight: 300)
                    .fixedSize(horizontal: false, vertical: true)
                    .onChange(of: clampedSelection) { _, index in
                        if results.indices.contains(index) { proxy.scrollTo(results[index].id) }
                    }
                }
            } else if !model.query.isEmpty {
                Divider()
                Text("No icons match")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
        }
        .frame(width: 320)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
        )
        .onChange(of: model.query) { _, _ in model.selection = 0 }
        .onChange(of: model.session) { _, _ in focused = true }
        .onAppear { focused = true }
    }

    private var clampedSelection: Int {
        min(max(model.selection, 0), max(results.count - 1, 0))
    }

    private func moveSelection(_ delta: Int) {
        guard !results.isEmpty else { return }
        model.selection = (clampedSelection + delta + results.count) % results.count
    }

    private func openSelection() {
        guard results.indices.contains(clampedSelection) else { return }
        onOpen(results[clampedSelection])
    }
}

private struct SearchRow: View {
    let item: MenuBarItem
    let selected: Bool

    var body: some View {
        HStack(spacing: 10) {
            ItemIcon(item: item)
                .frame(width: 18, height: 18)
                .frame(width: 22)
            Text(item.displayName)
                .font(.system(size: 13))
                .lineLimit(1)
            Spacer(minLength: 6)
            if item.section == .hidden {
                Text("Hidden")
                    .font(.system(size: 11))
                    .foregroundStyle(selected ? Color.white.opacity(0.8) : Color.secondary)
            }
        }
        .foregroundStyle(selected ? Color.white : Color.primary)
        .padding(.horizontal, 8)
        .frame(height: 30)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(selected ? Color.accentColor : .clear)
        )
        .contentShape(Rectangle())
    }
}

extension MenuBarItem {
    /// Lowercased words to match against: the name, the app and the label.
    var searchText: String {
        [displayName, appName, label ?? ""].joined(separator: " ").lowercased()
    }
}
