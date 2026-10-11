import SwiftUI

struct ItemListView: View {
    @Environment(Store.self) private var store

    var body: some View {
        @Bindable var store = store
        let items = store.visible
        List(selection: $store.selection) {
            if store.scope == .inbox && !items.isEmpty {
                Button { store.autoSort() } label: {
                    Label("Sort inbox into spaces with on-device AI", systemImage: "wand.and.sparkles")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
                .selectionDisabled()
            }
            ForEach(items) { item in
                ItemRow(item: item)
                    .tag(item.id)
                    .draggable(item.id.uuidString)
                    .swipeActions {
                        Button(role: .destructive) { store.trash([item.id]) } label: { Label("Trash", systemImage: "trash") }
                    }
            }
        }
        .contextMenu(forSelectionType: UUID.self) { ids in
            ItemMenu(ids: ids)
        } primaryAction: { ids in
            if let id = ids.first { store.focused = id }
        }
        .animation(.snappy(duration: 0.3), value: items.map(\.id))
        .overlay {
            if items.isEmpty {
                ContentUnavailableView {
                    Label(store.query.isEmpty ? "Nothing here yet" : "No matches", systemImage: store.query.isEmpty ? "sparkles" : "magnifyingglass")
                } description: {
                    Text(store.query.isEmpty ? "Capture a thought with ⌘N, or drop files and chat exports anywhere." : "Try another word or the semantic search in ⌘K.")
                }
            }
        }
        #if os(macOS)
        .onDeleteCommand { store.scope == .trash ? store.deleteForever(store.selection) : store.trash(store.selection) }
        #endif
    }
}

struct ItemRow: View {
    @Environment(Store.self) private var store
    let item: Item

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Thumb(item: item, size: 34)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(item.display).font(.body.weight(.semibold)).lineLimit(1)
                    if item.pinned { Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.orange) }
                    Spacer(minLength: 6)
                    if store.isWorking(item.id) { ProgressView().controlSize(.mini) }
                    Text(item.updated.formatted(.relative(presentation: .named))).font(.caption).foregroundStyle(.tertiary)
                }
                let snippet = item.snippet
                if !snippet.isEmpty {
                    Text(snippet).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                }
                HStack(spacing: 8) {
                    if item.status != .none {
                        Label(item.status.label, systemImage: item.status.icon).font(.caption).foregroundStyle(.secondary)
                    }
                    if let space = store.space(item.space) { SpaceTag(space: space) }
                    ForEach(item.tags.prefix(3), id: \.self) { TagChip(text: $0) }
                }
            }
        }
        .padding(.vertical, 5)
    }
}

/// Context menu shared by list, board and graph.
struct ItemMenu: View {
    @Environment(Store.self) private var store
    let ids: Set<UUID>

    var body: some View {
        if let id = ids.first, ids.count == 1 {
            Button("Open") { store.focused = id }
            Button("Enrich with AI") { Task { await store.enrich(id) } }
            Divider()
        }
        Menu("Move to") {
            Button("Inbox") { store.move(ids, to: nil) }
            ForEach(store.meta.spaces) { space in
                Button(space.name) { store.move(ids, to: space.id) }
                ForEach(store.projects(in: space.id)) { project in
                    Button("\(space.name) › \(project.name)") { store.move(ids, to: space.id, project: project.id) }
                }
            }
        }
        Menu("Status") {
            ForEach(Status.allCases) { status in
                Button { store.modify(ids) { $0.status = status } } label: { Label(status.label, systemImage: status.icon) }
            }
        }
        Button("Pin / Unpin") { store.modify(ids) { $0.pinned.toggle() } }
        Divider()
        if store.scope == .trash {
            Button("Restore") { store.modify(ids) { $0.trashed = false } }
            Button("Delete Forever", role: .destructive) { store.deleteForever(ids) }
        } else {
            Button("Move to Trash", role: .destructive) { store.trash(ids) }
        }
    }
}

struct BoardView: View {
    @Environment(Store.self) private var store
    @Namespace private var cards
    @State private var target: Status?

    var body: some View {
        let items = store.visible
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 14) {
                ForEach(Status.allCases) { status in
                    column(status, items.filter { $0.status == status })
                }
            }
            .padding(18)
        }
        .animation(.spring(duration: 0.4, bounce: 0.18), value: items.map(\.status))
    }

    private func column(_ status: Status, _ items: [Item]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: status.icon).foregroundStyle(.secondary)
                Text(status.label).font(.headline)
                Text("\(items.count)").font(.subheadline).foregroundStyle(.secondary).contentTransition(.numericText())
            }
            .padding(.horizontal, 4)
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(items) { item in
                        BoardCard(item: item, selected: store.selection.contains(item.id))
                            .matchedGeometryEffect(id: item.id, in: cards)
                            .onTapGesture { store.selection = [item.id] }
                            .draggable(item.id.uuidString)
                            .contextMenu { ItemMenu(ids: [item.id]) }
                    }
                }
                .padding(2)
            }
        }
        .padding(12)
        .frame(width: 290)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(target == status ? Color.accentColor.opacity(0.14) : Color.secondary.opacity(0.07),
                    in: .rect(cornerRadius: 20, style: .continuous))
        .dropDestination(for: String.self) { ids, _ in
            store.modify(Set(ids.compactMap(UUID.init(uuidString:)))) { $0.status = status }
            return true
        } isTargeted: { inside in
            withAnimation(.snappy(duration: 0.2)) { target = inside ? status : (target == status ? nil : target) }
        }
    }
}

struct BoardCard: View {
    @Environment(Store.self) private var store
    let item: Item
    let selected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Thumb(item: item, size: 24)
                Text(item.display).font(.subheadline.weight(.semibold)).lineLimit(2)
            }
            let snippet = item.snippet
            if !snippet.isEmpty { Text(snippet).font(.caption).foregroundStyle(.secondary).lineLimit(3) }
            HStack(spacing: 6) {
                if let space = store.space(item.space) { SpaceTag(space: space) }
                ForEach(item.tags.prefix(2), id: \.self) { TagChip(text: $0) }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: .rect(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(selected ? Color.accentColor : Color.secondary.opacity(0.15), lineWidth: selected ? 2 : 1))
        .hoverLift()
    }
}
