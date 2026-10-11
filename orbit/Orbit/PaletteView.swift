import SwiftUI

/// ⌘K: search everything (text + on-device semantic search) and run commands from the keyboard.
struct PaletteView: View {
    @Environment(Store.self) private var store
    @State private var text = ""
    @State private var index = 0
    @State private var semantic: [UUID] = []
    @FocusState private var focused: Bool

    struct Entry: Identifiable {
        let id: String
        let title: String
        let subtitle: String
        let icon: String
        let tint: Color
        let run: () -> Void
    }

    var body: some View {
        let entries = self.entries
        ZStack(alignment: .top) {
            Color.black.opacity(0.16).ignoresSafeArea().onTapGesture { close() }
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Image(systemName: "magnifyingglass").font(.title3).foregroundStyle(.secondary)
                    TextField("Search your vault or run a command", text: $text)
                        .textFieldStyle(.plain)
                        .font(.title3)
                        .focused($focused)
                        .onSubmit { run(entries, index) }
                    Text("esc").font(.caption.monospaced()).foregroundStyle(.tertiary)
                }
                .padding(18)
                Divider()
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(Array(entries.enumerated()), id: \.element.id) { i, entry in
                                row(entry, active: i == index)
                                    .id(i)
                                    .onTapGesture { run(entries, i) }
                                    .onHover { if $0 { index = i } }
                            }
                        }
                        .padding(8)
                    }
                    .frame(maxHeight: 400)
                    .onChange(of: index) { _, i in proxy.scrollTo(i) }
                }
            }
            .frame(maxWidth: 660)
            .glassEffect(.regular, in: .rect(cornerRadius: 24, style: .continuous))
            .shadow(color: .black.opacity(0.25), radius: 40, y: 24)
            .padding(.top, 80)
            .padding(.horizontal, 16)
            .onKeyPress(.downArrow) { index = min(index + 1, max(entries.count - 1, 0)); return .handled }
            .onKeyPress(.upArrow) { index = max(index - 1, 0); return .handled }
            .onKeyPress(.escape) { close(); return .handled }
        }
        .onAppear { focused = true }
        .onChange(of: text) { index = 0 }
        .task(id: text) {
            semantic = []
            guard text.count >= 3 else { return }
            try? await Task.sleep(for: .milliseconds(220))
            guard !Task.isCancelled else { return }
            semantic = await store.brain.search(text).map(\.id)
        }
    }

    private func row(_ entry: Entry, active: Bool) -> some View {
        HStack(spacing: 12) {
            Glyph(symbol: entry.icon, tint: entry.tint, size: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.title).font(.body.weight(.medium)).lineLimit(1)
                if !entry.subtitle.isEmpty { Text(entry.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer()
            if active { Image(systemName: "return").font(.caption).foregroundStyle(.secondary) }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(active ? Color.accentColor.opacity(0.16) : .clear, in: .rect(cornerRadius: 12, style: .continuous))
        .contentShape(.rect)
    }

    // MARK: Entries

    private var entries: [Entry] {
        let query = text.trimmingCharacters(in: .whitespaces)
        let live = store.items.values.filter { !$0.trashed }
        let found: [Item]
        if query.isEmpty {
            found = Array(live.sorted { $0.updated > $1.updated }.prefix(6))
        } else {
            found = Array(live.filter { $0.matches(query) }
                .sorted { (score($0, query), $0.updated) > (score($1, query), $1.updated) }
                .prefix(10))
        }
        let ids = Set(found.map(\.id))
        let similar = semantic.filter { !ids.contains($0) }.compactMap { store.items[$0] }.filter { !$0.trashed }.prefix(5)
        let matching = commands.filter { query.isEmpty || $0.title.localizedStandardContains(query) }
        return found.map { entry($0, semantic: false) } + similar.map { entry($0, semantic: true) } + matching.prefix(query.isEmpty ? 6 : 8)
    }

    private func score(_ item: Item, _ query: String) -> Int {
        let title = item.display
        if title.localizedStandardRange(of: query)?.lowerBound == title.startIndex { return 3 }
        if title.localizedStandardContains(query) { return 2 }
        return item.tags.contains { $0.localizedStandardContains(query) } ? 1 : 0
    }

    private func entry(_ item: Item, semantic: Bool) -> Entry {
        let place = store.space(item.space)?.name ?? "Inbox"
        return Entry(id: item.id.uuidString, title: item.display,
                     subtitle: semantic ? "Similar meaning · \(place)" : "\(item.kind.label) · \(place)",
                     icon: item.symbol, tint: item.kind.tint) {
            store.selection = [item.id]
            if item.kind == .mindmap { store.focused = item.id }
        }
    }

    private var commands: [Entry] {
        var list: [Entry] = Kind.allCases.filter { $0 != .file }.map { kind in
            Entry(id: "new-\(kind.rawValue)", title: "New \(kind.label)", subtitle: "Create", icon: "plus", tint: kind.tint) { store.create(kind) }
        }
        list += [
            Entry(id: "import", title: "Import Files or Chat Exports…", subtitle: "Claude & ChatGPT conversations.json supported", icon: "square.and.arrow.down", tint: .indigo) { store.showImporter = true },
            Entry(id: "sort", title: "Auto-Sort Inbox", subtitle: "On-device AI", icon: "wand.and.sparkles", tint: .purple) { store.autoSort() },
            Entry(id: "overview", title: "Go to Overview", subtitle: "", icon: "square.grid.2x2", tint: .blue) { store.scope = .overview; store.focused = nil },
            Entry(id: "inbox", title: "Go to Inbox", subtitle: "", icon: "tray", tint: .blue) { store.scope = .inbox; store.focused = nil },
            Entry(id: "questions", title: "Go to Open Questions", subtitle: "", icon: "questionmark.bubble", tint: .orange) { store.scope = .questions; store.focused = nil },
        ]
        list += store.meta.spaces.map { space in
            Entry(id: "space-\(space.id)", title: "Go to \(space.name)", subtitle: "Space", icon: space.icon, tint: space.color) {
                store.scope = .space(space.id)
                store.focused = nil
            }
        }
        list += Mode.allCases.map { mode in
            Entry(id: "mode-\(mode.rawValue)", title: "Show as \(mode.rawValue.capitalized)", subtitle: "View", icon: mode.icon, tint: .teal) {
                if store.scope == .overview { store.scope = .all }
                store.mode = mode
                store.focused = nil
            }
        }
        list.append(Entry(id: "lock", title: "Lock Vault", subtitle: "⌘L", icon: "lock.fill", tint: .green) { store.lock(manual: true) })
        return list
    }

    private func run(_ entries: [Entry], _ i: Int) {
        guard entries.indices.contains(i) else { return }
        close()
        entries[i].run()
    }

    private func close() { store.showPalette = false }
}
