import SwiftUI
import QuickLook
import UniformTypeIdentifiers

struct EditorView: View {
    @Environment(Store.self) private var store
    let id: UUID
    var wide = false
    @State private var preview = false
    @State private var newTag = ""
    @State private var linking = false

    var body: some View {
        let item = store.binding(id)
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header(item)
                Text("Created \(item.wrappedValue.created.formatted(date: .abbreviated, time: .omitted)) · edited \(item.wrappedValue.updated.formatted(.relative(presentation: .named)))")
                    .font(.caption).foregroundStyle(.tertiary)
                    .padding(.top, -10)
                meta(item.wrappedValue)
                if let s = store.suggestion(for: item.wrappedValue) { suggestion(s.space, s.project) }
                if !item.wrappedValue.summary.isEmpty {
                    Label(item.wrappedValue.summary, systemImage: "sparkle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.accentColor.opacity(0.08), in: .rect(cornerRadius: 12))
                }
                tags(item)
                content(item)
                links(item.wrappedValue)
                related(item.wrappedValue)
            }
            .padding(wide ? 32 : 18)
            .frame(maxWidth: wide ? 860 : .infinity, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    // MARK: Header & metadata

    private func header(_ item: Binding<Item>) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Menu {
                    Picker("Kind", selection: item.kind) {
                        ForEach(Kind.allCases) { Label($0.label, systemImage: $0.icon).tag($0) }
                    }
                } label: {
                    Glyph(symbol: item.wrappedValue.symbol, tint: item.wrappedValue.kind.tint, size: 34)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()

                Spacer()

                Button { Task { await store.enrich(id) } } label: {
                    if store.isWorking(id) { ProgressView().controlSize(.small) } else { Image(systemName: "wand.and.sparkles") }
                }
                .buttonStyle(.glass)
                .help("Title, summarize and tag with on-device AI")

                Button { item.wrappedValue.pinned.toggle() } label: {
                    Image(systemName: item.wrappedValue.pinned ? "pin.fill" : "pin")
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.glass)

                Menu {
                    if !wide { Button("Open in Focus") { store.focused = id } }
                    if item.wrappedValue.trashed {
                        Button("Restore") { item.wrappedValue.trashed = false }
                        Button("Delete Forever", role: .destructive) { store.deleteForever([id]) }
                    } else {
                        Button("Move to Trash", role: .destructive) { store.trash([id]) }
                    }
                } label: { Image(systemName: "ellipsis") }
                .menuIndicator(.hidden)
                .buttonStyle(.glass)
                .fixedSize()
            }

            TextField("Title", text: item.title, axis: .vertical)
                .font(wide ? .largeTitle.bold() : .title2.bold())
                .textFieldStyle(.plain)
                .lineLimit(1...4)
        }
    }

    private func meta(_ item: Item) -> some View {
        HStack(spacing: 8) {
            Menu {
                ItemMenu(ids: [id])
            } label: {
                if let space = store.space(item.space) {
                    Label(store.project(item.project).map { "\(space.name) › \($0.name)" } ?? space.name, systemImage: space.icon)
                } else {
                    Label("Inbox", systemImage: "tray")
                }
            }
            .fixedSize()
            Menu {
                ForEach(Status.allCases) { status in
                    Button { store.modify([id]) { $0.status = status } } label: { Label(status.label, systemImage: status.icon) }
                }
            } label: {
                Label(item.status.label, systemImage: item.status.icon)
            }
            .fixedSize()
            Spacer(minLength: 0)
        }
        .font(.callout)
        .buttonStyle(.glass)
        .controlSize(.small)
    }

    private func suggestion(_ space: Space, _ project: Project?) -> some View {
        HStack {
            Image(systemName: "wand.and.sparkles").foregroundStyle(space.color)
            Text("Belongs in **\(space.name)\(project.map { " › " + $0.name } ?? "")**?").font(.callout)
            Spacer()
            Button("Move") { store.move([id], to: space.id, project: project?.id) }.buttonStyle(.glassProminent).controlSize(.small)
        }
        .padding(10)
        .glassEffect(.regular.tint(space.color.opacity(0.25)), in: .rect(cornerRadius: 14))
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    private func tags(_ item: Binding<Item>) -> some View {
        FlowLayout(spacing: 6) {
            ForEach(item.wrappedValue.tags, id: \.self) { tag in
                TagChip(text: tag) { item.wrappedValue.tags.removeAll { $0 == tag } }
            }
            TextField("Add tag", text: $newTag)
                .textFieldStyle(.plain)
                .font(.caption)
                .frame(width: 80)
                .onSubmit {
                    let tag = newTag.lowercased().trimmingCharacters(in: .whitespaces)
                    if !tag.isEmpty && !item.wrappedValue.tags.contains(tag) { item.wrappedValue.tags.append(tag) }
                    newTag = ""
                }
        }
    }

    // MARK: Content per kind

    @ViewBuilder private func content(_ item: Binding<Item>) -> some View {
        switch item.wrappedValue.kind {
        case .file:
            FileCard(item: item.wrappedValue)
            section("Notes") { bodyEditor(item, minHeight: 120) }
        case .chat:
            Picker("Mode", selection: $preview) {
                Text("Conversation").tag(true)
                Text("Edit").tag(false)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .onAppear { preview = !item.wrappedValue.body.isEmpty }
            if preview { Transcript(turns: Importer.turns(in: item.wrappedValue.body)) } else { bodyEditor(item, minHeight: 320) }
        case .mindmap:
            MindmapOutline(nodes: item.wrappedValue.nodes)
            Button { store.focused = id } label: { Label("Open Map", systemImage: "arrow.up.left.and.arrow.down.right") }
                .buttonStyle(.glassProminent)
        case .note, .question:
            HStack {
                Picker("Mode", selection: $preview) {
                    Text("Write").tag(false)
                    Text("Read").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer()
                if item.wrappedValue.kind == .question {
                    Button { Task { await store.suggestAnswer(id) } } label: { Label("Suggest Answer", systemImage: "sparkles") }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                }
            }
            if preview {
                Text(markdown(item.wrappedValue.body)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            } else {
                bodyEditor(item, minHeight: wide ? 420 : 260)
            }
        }
    }

    private func bodyEditor(_ item: Binding<Item>, minHeight: CGFloat) -> some View {
        TextEditor(text: item.body)
            .font(wide ? .title3 : .body)
            .scrollContentBackground(.hidden)
            .padding(10)
            .frame(minHeight: minHeight)
            .background(.quinary.opacity(0.6), in: .rect(cornerRadius: 12))
    }

    private func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }

    // MARK: Links & related

    private func links(_ item: Item) -> some View {
        let outgoing = item.links.compactMap { store.items[$0] }.filter { !$0.trashed }
        let incoming = store.backlinks(id).filter { !item.links.contains($0.id) }
        return section("Links", trailing: AnyView(
            Button { linking = true } label: { Image(systemName: "plus") }
                .buttonStyle(.plain)
                .popover(isPresented: $linking) { LinkPicker(source: id) }
        )) {
            if outgoing.isEmpty && incoming.isEmpty {
                Text("Link related items to see them connected in the graph.").font(.caption).foregroundStyle(.tertiary)
            }
            ForEach(outgoing + incoming) { other in
                RelatedRow(item: other, detail: outgoing.contains(other) ? "linked" : "links here", actionIcon: "link.badge.minus") {
                    store.unlink(id, other.id)
                }
            }
        }
    }

    @ViewBuilder private func related(_ item: Item) -> some View {
        let hits = store.brain.similar(to: id, limit: 5).compactMap { hit in store.items[hit.id].map { ($0, hit.score) } }
            .filter { !item.links.contains($0.0.id) && !$0.0.trashed }
        if !hits.isEmpty {
            section("Related") {
                ForEach(hits, id: \.0.id) { hit in
                    RelatedRow(item: hit.0, detail: "\(Int(hit.1 * 100))% similar", actionIcon: "link.badge.plus") {
                        store.link(id, hit.0.id)
                    }
                }
            }
        }
    }

    private func section<Content: View>(_ title: String, trailing: AnyView? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                trailing
            }
            content()
        }
    }
}

struct RelatedRow: View {
    @Environment(Store.self) private var store
    let item: Item
    let detail: String
    let actionIcon: String
    let action: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Thumb(item: item, size: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.display).font(.callout).lineLimit(1)
                Text(detail).font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer()
            Button(action: action) { Image(systemName: actionIcon) }.buttonStyle(.plain).foregroundStyle(.secondary)
        }
        .contentShape(.rect)
        .onTapGesture { withAnimation(.snappy) { store.selection = [item.id] } }
    }
}

struct LinkPicker: View {
    @Environment(Store.self) private var store
    let source: UUID
    @State private var query = ""

    var body: some View {
        let candidates = store.items.values
            .filter { !$0.trashed && $0.id != source && (query.isEmpty || $0.matches(query)) }
            .sorted { $0.updated > $1.updated }
            .prefix(30)
        VStack(spacing: 0) {
            TextField("Search items to link", text: $query).textFieldStyle(.roundedBorder).padding(10)
            List(Array(candidates)) { item in
                Button { store.link(source, item.id) } label: {
                    HStack {
                        Thumb(item: item, size: 22)
                        Text(item.display).lineLimit(1)
                    }
                }
                .buttonStyle(.plain)
            }
            .listStyle(.plain)
        }
        .frame(width: 320, height: 380)
    }
}

/// Chat transcript as message bubbles.
struct Transcript: View {
    let turns: [Importer.Turn]

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 10) {
            ForEach(Array(turns.enumerated()), id: \.offset) { _, turn in
                let mine = turn.role == .user
                HStack {
                    if mine { Spacer(minLength: 40) }
                    Text((try? AttributedString(markdown: turn.text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(turn.text))
                        .textSelection(.enabled)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .foregroundStyle(mine ? Color.white : Color.primary)
                        .background(mine ? AnyShapeStyle(Color.accentColor.gradient) : AnyShapeStyle(HierarchicalShapeStyle.quinary),
                                    in: .rect(cornerRadius: 18, style: .continuous))
                    if !mine { Spacer(minLength: 40) }
                }
            }
        }
    }
}

struct FileCard: View {
    @Environment(Store.self) private var store
    let item: Item
    @State private var url: URL?
    @State private var preview: URL?
    @State private var showText = false

    var body: some View {
        if let file = item.file {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 14) {
                    Thumb(item: item, size: 84)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(file.name).font(.headline).lineLimit(2)
                        Text("\(UTType(file.type)?.localizedDescription ?? "File") · \(Int64(file.size).formatted(.byteCount(style: .file)))")
                            .font(.caption).foregroundStyle(.secondary)
                        Label("Stored encrypted", systemImage: "lock.fill").font(.caption2).foregroundStyle(.green)
                    }
                }
                HStack {
                    Button { Task { preview = await store.decrypted(item.id) } } label: { Label("Quick Look", systemImage: "eye") }
                    #if os(macOS)
                    Button { Task { if let u = await store.decrypted(item.id) { NSWorkspace.shared.open(u) } } } label: {
                        Label("Open", systemImage: "arrow.up.forward.app")
                    }
                    #endif
                    if let url {
                        ShareLink(item: url) { Label("Share", systemImage: "square.and.arrow.up") }
                    } else {
                        Button { Task { url = await store.decrypted(item.id) } } label: { Label("Export", systemImage: "square.and.arrow.up") }
                    }
                }
                .buttonStyle(.glass)
                .controlSize(.small)
                if let text = file.text, !text.isEmpty {
                    DisclosureGroup("Extracted text", isExpanded: $showText) {
                        Text(text.prefix(4000)).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(.callout)
                }
            }
            .quickLookPreview($preview)
        }
    }
}

/// Indented outline of a mindmap for the inspector.
struct MindmapOutline: View {
    let nodes: [MindNode]

    var body: some View {
        let rows = flatten()
        VStack(alignment: .leading, spacing: 5) {
            ForEach(rows.prefix(40), id: \.node.id) { row in
                HStack(spacing: 6) {
                    Circle().fill(row.depth == 0 ? Color.accentColor : Palette.color(row.branch)).frame(width: 6, height: 6)
                    Text(row.node.text.isEmpty ? "Idea" : row.node.text)
                        .font(row.depth == 0 ? .callout.bold() : .callout)
                }
                .padding(.leading, CGFloat(row.depth) * 16)
            }
            if rows.count > 40 { Text("+\(rows.count - 40) more").font(.caption).foregroundStyle(.tertiary) }
        }
    }

    private func flatten() -> [(node: MindNode, depth: Int, branch: Int)] {
        let children = Dictionary(grouping: nodes.filter { $0.parent != nil }, by: { $0.parent! })
        var out: [(node: MindNode, depth: Int, branch: Int)] = []
        func walk(_ node: MindNode, _ depth: Int, _ branch: Int) {
            out.append((node, depth, branch))
            for (i, child) in (children[node.id] ?? []).enumerated() { walk(child, depth + 1, depth == 0 ? i : branch) }
        }
        if let root = nodes.first(where: { $0.parent == nil }) { walk(root, 0, 0) }
        return out
    }
}

/// Wrapping row layout for tags.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(proposal.width ?? .infinity, subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (subview, point) in zip(subviews, arrange(bounds.width, subviews).points) {
            subview.place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y), proposal: .unspecified)
        }
    }

    private func arrange(_ width: CGFloat, _ subviews: Subviews) -> (size: CGSize, points: [CGPoint]) {
        var points: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0, widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width { x = 0; y += row + spacing; row = 0 }
            points.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            row = max(row, size.height)
            widest = max(widest, x - spacing)
        }
        return (CGSize(width: widest, height: y + row), points)
    }
}
