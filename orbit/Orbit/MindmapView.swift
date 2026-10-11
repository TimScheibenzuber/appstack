import SwiftUI

/// Balanced horizontal tree: first-level branches alternate right and left, subtrees stack by leaf count.
struct MindLayout {
    struct Link {
        let id: UUID
        let from: CGPoint
        let to: CGPoint
        let branch: Int
        let depth: Int
    }

    private(set) var points: [UUID: CGPoint] = [:]
    private(set) var depth: [UUID: Int] = [:]
    private(set) var branch: [UUID: Int] = [:]
    private(set) var links: [Link] = []
    private(set) var size = CGSize(width: 800, height: 500)

    init(_ nodes: [MindNode]) {
        guard let root = nodes.first(where: { $0.parent == nil }) else { return }
        let children = Dictionary(grouping: nodes.filter { $0.parent != nil }, by: { $0.parent! }).mapValues { $0.map(\.id) }
        let dx: CGFloat = 230, dy: CGFloat = 54
        var leaves: [UUID: Int] = [:]
        func count(_ id: UUID) -> Int {
            let c = max(1, (children[id] ?? []).reduce(0) { $0 + count($1) })
            leaves[id] = c
            return c
        }
        _ = count(root.id)

        var pts: [UUID: CGPoint] = [root.id: .zero], dep: [UUID: Int] = [root.id: 0], br: [UUID: Int] = [:]
        func place(_ id: UUID, _ d: Int, _ side: CGFloat, _ top: CGFloat, _ b: Int) {
            pts[id] = CGPoint(x: side * CGFloat(d) * dx, y: top + CGFloat(leaves[id] ?? 1) * dy / 2)
            dep[id] = d
            br[id] = b
            var y = top
            for c in children[id] ?? [] {
                place(c, d + 1, side, y, b)
                y += CGFloat(leaves[c] ?? 1) * dy
            }
        }
        let first = children[root.id] ?? []
        for side: CGFloat in [1, -1] {
            let group = first.enumerated().filter { ($0.offset % 2 == 0) == (side > 0) }
            var y = -CGFloat(group.reduce(0) { $0 + (leaves[$1.element] ?? 1) }) * dy / 2
            for (i, c) in group {
                place(c, 1, side, y, i)
                y += CGFloat(leaves[c] ?? 1) * dy
            }
        }

        let xs = pts.values.map(\.x), ys = pts.values.map(\.y)
        let minX = xs.min()! - 200, minY = ys.min()! - 80
        size = CGSize(width: max(xs.max()! - minX + 200, 700), height: max(ys.max()! - minY + 80, 420))
        let shifted = pts.mapValues { CGPoint(x: $0.x - minX, y: $0.y - minY) }
        points = shifted
        depth = dep
        branch = br
        links = nodes.compactMap { n in
            guard let p = n.parent, let a = shifted[p], let b = shifted[n.id] else { return nil }
            return Link(id: n.id, from: a, to: b, branch: br[n.id] ?? 0, depth: dep[n.id] ?? 1)
        }
    }
}

/// Curved connector whose endpoints animate together with the nodes.
struct Branch: Shape {
    var from: CGPoint
    var to: CGPoint

    var animatableData: AnimatablePair<CGPoint.AnimatableData, CGPoint.AnimatableData> {
        get { AnimatablePair(from.animatableData, to.animatableData) }
        set { from.animatableData = newValue.first; to.animatableData = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        Path { p in
            let mid = (from.x + to.x) / 2
            p.move(to: from)
            p.addCurve(to: to, control1: CGPoint(x: mid, y: from.y), control2: CGPoint(x: mid, y: to.y))
        }
    }
}

struct MindmapView: View {
    @Environment(Store.self) private var store
    let id: UUID
    @State private var selected: UUID?
    @State private var editing: UUID?
    @State private var zoom = 1.0
    @State private var thinking = false
    @GestureState private var pinch = 1.0
    @FocusState private var canvasFocus: Bool
    @FocusState private var fieldFocus: UUID?

    private var nodes: [MindNode] { store.items[id]?.nodes ?? [] }
    private var root: MindNode? { nodes.first { $0.parent == nil } }

    var body: some View {
        let nodes = self.nodes
        let layout = MindLayout(nodes)
        let scale = zoom * pinch
        ScrollView([.horizontal, .vertical]) {
            ZStack(alignment: .topLeading) {
                ForEach(layout.links, id: \.id) { link in
                    Branch(from: link.from, to: link.to)
                        .stroke(Palette.color(link.branch).opacity(0.75),
                                style: StrokeStyle(lineWidth: link.depth == 1 ? 3 : 2, lineCap: .round))
                }
                ForEach(nodes) { node in
                    nodeView(node, depth: layout.depth[node.id] ?? 0, branch: layout.branch[node.id] ?? 0)
                        .position(layout.points[node.id] ?? .zero)
                }
            }
            .frame(width: layout.size.width, height: layout.size.height)
            .scaleEffect(scale, anchor: .topLeading)
            .frame(width: layout.size.width * scale, height: layout.size.height * scale, alignment: .topLeading)
            .animation(.spring(duration: 0.45, bounce: 0.2), value: nodes)
        }
        .defaultScrollAnchor(.center)
        .contentShape(.rect)
        .onTapGesture { editing = nil; canvasFocus = true }
        .focusable()
        .focused($canvasFocus)
        .focusEffectDisabled()
        .onKeyPress(.tab) { addChild(); return .handled }
        .onKeyPress(.return) {
            guard editing == nil else { return .ignored }
            addSibling()
            return .handled
        }
        .onKeyPress(.delete) {
            guard editing == nil else { return .ignored }
            remove()
            return .handled
        }
        .onKeyPress(.space) {
            guard editing == nil, let selected else { return .ignored }
            editing = selected
            return .handled
        }
        .simultaneousGesture(MagnifyGesture()
            .updating($pinch) { value, state, _ in state = value.magnification }
            .onEnded { zoom = min(max(zoom * $0.magnification, 0.3), 3) })
        .overlay(alignment: .bottom) { toolbar }
        .onAppear {
            selected = root?.id
            canvasFocus = true
        }
    }

    private func nodeView(_ node: MindNode, depth: Int, branch: Int) -> some View {
        let color = depth == 0 ? Color.accentColor : Palette.color(branch)
        let isSelected = selected == node.id
        return Group {
            if editing == node.id {
                TextField("Idea", text: text(node.id))
                    .textFieldStyle(.plain)
                    .focused($fieldFocus, equals: node.id)
                    .onSubmit { editing = nil; canvasFocus = true }
                    .onAppear { fieldFocus = node.id }
                    .frame(minWidth: 80)
                    .fixedSize()
            } else {
                Text(node.text.isEmpty ? "Idea" : node.text).lineLimit(2).frame(maxWidth: 220)
            }
        }
        .font(depth == 0 ? .title3.bold() : depth == 1 ? .headline : .callout)
        .foregroundStyle(depth == 0 ? Color.white : Color.primary)
        .padding(.horizontal, depth == 0 ? 22 : 14)
        .padding(.vertical, depth == 0 ? 12 : 8)
        .background {
            if depth == 0 {
                Capsule().fill(color.gradient).shadow(color: color.opacity(0.45), radius: 14, y: 6)
            } else {
                Capsule().fill(.background).overlay(Capsule().fill(color.opacity(depth == 1 ? 0.2 : 0.1)))
            }
        }
        .overlay { Capsule().strokeBorder(color, lineWidth: isSelected ? 2.5 : (depth == 1 ? 1 : 0)) }
        .scaleEffect(isSelected ? 1.06 : 1)
        .animation(.snappy(duration: 0.2), value: isSelected)
        .onTapGesture {
            if selected == node.id { editing = node.id } else { selected = node.id; editing = nil; canvasFocus = true }
        }
        .transition(.scale(scale: 0.6).combined(with: .opacity))
    }

    private var toolbar: some View {
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 10) {
                Button(action: addChild) { Label("Child", systemImage: "arrow.turn.down.right") }.help("Add child (Tab)")
                Button(action: addSibling) { Label("Sibling", systemImage: "arrow.down.to.line") }.help("Add sibling (Return)")
                Button(action: remove) { Label("Delete", systemImage: "trash") }.disabled(selected == nil || selected == root?.id)
                Button { Task { await expand() } } label: {
                    if thinking { ProgressView().controlSize(.small) } else { Label("Expand with AI", systemImage: "sparkles") }
                }
                .help("Suggest sub-ideas with on-device Apple Intelligence")
                Button { zoom = max(zoom / 1.25, 0.3) } label: { Image(systemName: "minus.magnifyingglass") }
                Button { zoom = min(zoom * 1.25, 3) } label: { Image(systemName: "plus.magnifyingglass") }
            }
            .labelStyle(.titleAndIcon)
            .buttonStyle(.glass)
        }
        .padding(18)
    }

    // MARK: Editing

    private func text(_ nodeID: UUID) -> Binding<String> {
        Binding(get: { nodes.first { $0.id == nodeID }?.text ?? "" }, set: { value in
            store.modify([id]) { item in
                guard let i = item.nodes.firstIndex(where: { $0.id == nodeID }) else { return }
                item.nodes[i].text = value
                if item.nodes[i].parent == nil { item.title = value }
            }
        })
    }

    private func mutate(_ change: @escaping (inout [MindNode]) -> Void) {
        store.modify([id]) { change(&$0.nodes) }
    }

    private func addChild() {
        guard let parent = selected ?? root?.id else { return }
        let node = MindNode(text: "", parent: parent)
        mutate { $0.append(node) }
        selected = node.id
        editing = node.id
    }

    private func addSibling() {
        guard let current = selected, let parent = nodes.first(where: { $0.id == current })?.parent else { return addChild() }
        let node = MindNode(text: "", parent: parent)
        mutate { nodes in nodes.insert(node, at: (nodes.firstIndex { $0.id == current } ?? nodes.count - 1) + 1) }
        selected = node.id
        editing = node.id
    }

    private func remove() {
        guard let current = selected, let node = nodes.first(where: { $0.id == current }), node.parent != nil else { return }
        var doomed: Set<UUID> = [current]
        var grew = true
        while grew {
            grew = false
            for n in nodes where !doomed.contains(n.id) && n.parent.map({ doomed.contains($0) }) == true {
                doomed.insert(n.id)
                grew = true
            }
        }
        mutate { $0.removeAll { doomed.contains($0.id) } }
        selected = node.parent
        editing = nil
    }

    private func expand() async {
        guard AI.isAvailable else { return store.notify("Expanding needs Apple Intelligence.") }
        guard let target = selected ?? root?.id, let node = nodes.first(where: { $0.id == target }) else { return }
        var path: [String] = []
        var cursor: MindNode? = node
        while let c = cursor {
            path.insert(c.text, at: 0)
            cursor = c.parent.flatMap { p in nodes.first { $0.id == p } }
        }
        thinking = true
        defer { thinking = false }
        guard let ideas = try? await AI.ideas(path: path), !ideas.isEmpty else { return store.notify("No ideas this time.") }
        withAnimation(.spring(duration: 0.5, bounce: 0.25)) {
            mutate { nodes in nodes += ideas.prefix(6).map { MindNode(text: $0, parent: target) } }
        }
    }
}
