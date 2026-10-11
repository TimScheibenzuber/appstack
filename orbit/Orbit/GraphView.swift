import SwiftUI

/// Force-directed layout (d3-style). Positions live outside observation so frames don't invalidate SwiftUI;
/// only `running` is observed, which pauses the timeline once the layout has settled.
@Observable
final class GraphModel {
    enum Role { case space, project, item }
    enum Link { case tree, explicit, semantic }

    struct Node {
        let id: UUID
        let role: Role
        let color: Color
        let radius: Double
    }

    private(set) var running = false
    @ObservationIgnored private(set) var nodes: [Node] = []
    @ObservationIgnored private(set) var edges: [(a: Int, b: Int, link: Link)] = []
    @ObservationIgnored private(set) var neighbours: [Set<Int>] = []
    @ObservationIgnored var pos: [SIMD2<Double>] = []
    @ObservationIgnored var dragging: Int?
    @ObservationIgnored private var vel: [SIMD2<Double>] = []
    @ObservationIgnored private var alpha = 1.0

    func load(nodes: [Node], edges: [(UUID, UUID, Link)]) {
        let old = Dictionary(zip(self.nodes.map(\.id), pos), uniquingKeysWith: { a, _ in a })
        let index = Dictionary(nodes.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
        self.nodes = nodes
        self.edges = edges.compactMap { a, b, link in
            guard let i = index[a], let j = index[b], i != j else { return nil }
            return (i, j, link)
        }
        neighbours = Array(repeating: [], count: nodes.count)
        for e in self.edges {
            neighbours[e.a].insert(e.b)
            neighbours[e.b].insert(e.a)
        }
        var fresh = 0
        pos = nodes.indices.map { i in
            if let p = old[nodes[i].id] { return p }
            fresh += 1
            if let j = neighbours[i].first(where: { old[nodes[$0].id] != nil }), let p = old[nodes[j].id] {
                return p + SIMD2(.random(in: -30...30), .random(in: -30...30))
            }
            let angle = Double(i) * 2.39996, r = 22 * Double(i + 1).squareRoot()   // golden-angle spiral
            return SIMD2(cos(angle) * r, sin(angle) * r)
        }
        vel = Array(repeating: .zero, count: nodes.count)
        if fresh > 0 { heat(old.isEmpty ? 1 : 0.5) }
    }

    func heat(_ value: Double) {
        alpha = max(alpha, value)
        if !running { running = true }
    }

    func step() {
        guard alpha > 0.005 else {
            if running { Task { @MainActor in self.running = false } }
            return
        }
        let n = nodes.count
        var force = [SIMD2<Double>](repeating: .zero, count: n)
        let charge = nodes.map { $0.role == .space ? 320.0 : $0.role == .project ? 160 : 45 }
        for i in 0..<n {
            for j in (i + 1)..<n {
                var d = pos[i] - pos[j]
                var d2 = (d * d).sum()
                if d2 < 0.01 { d = SIMD2(0.1, -0.1); d2 = 0.02 }
                force[i] += d * (charge[j] / d2)
                force[j] -= d * (charge[i] / d2)
            }
            force[i] -= pos[i] * 0.035
        }
        for e in edges {
            let d = pos[e.b] - pos[e.a]
            let length = max((d * d).sum().squareRoot(), 0.01)
            let hub = nodes[e.a].role != .item && nodes[e.b].role != .item
            let (rest, strength): (Double, Double) = switch e.link {
            case .tree: hub ? (150, 0.35) : (60, 0.45)
            case .explicit: (90, 0.3)
            case .semantic: (120, 0.08)
            }
            let f = d * ((length - rest) / length * strength * 0.5)
            force[e.a] += f
            force[e.b] -= f
        }
        for i in 0..<n where i != dragging {
            vel[i] = (vel[i] + force[i] * alpha) * 0.6
            pos[i] += vel[i]
        }
        alpha *= 0.978
    }

    func hit(_ p: SIMD2<Double>, scale: Double) -> Int? {
        var best: (Int, Double)?
        for (i, q) in pos.enumerated() {
            let d = ((q - p) * (q - p)).sum().squareRoot()
            let reach = nodes[i].radius + 8 / scale
            if d <= reach, d < (best?.1 ?? .infinity) { best = (i, d) }
        }
        return best?.0
    }
}

struct GraphView: View {
    @Environment(Store.self) private var store
    @State private var model = GraphModel()
    @State private var zoom = 1.0
    @State private var pan = CGSize.zero
    @State private var panStart: CGSize?
    @State private var hover: Int?
    @State private var semantic = true
    @GestureState private var pinch = 1.0

    private let cap = 300

    var body: some View {
        let selection = store.selection
        GeometryReader { geo in
            let center = CGPoint(x: geo.size.width / 2 + pan.width, y: geo.size.height / 2 + pan.height)
            let scale = zoom * pinch
            TimelineView(.animation(paused: !model.running)) { _ in
                Canvas { context, _ in
                    model.step()
                    draw(context, center: center, scale: scale, selection: selection)
                }
            }
            .contentShape(.rect)
            .gesture(drag(center: center, scale: scale))
            .simultaneousGesture(MagnifyGesture()
                .updating($pinch) { value, state, _ in state = value.magnification }
                .onEnded { zoom = clamp(zoom * $0.magnification) })
            .onTapGesture(coordinateSpace: .local) { point in tap(point, center: center, scale: scale) }
            .onContinuousHover { phase in
                if case .active(let point) = phase {
                    let h = model.hit(toModel(point, center, scale), scale: scale)
                    if h != hover { hover = h }
                } else if hover != nil {
                    hover = nil
                }
            }
        }
        .overlay(alignment: .topLeading) { legend }
        .overlay(alignment: .bottomTrailing) { controls }
        .overlay {
            if store.visible.isEmpty {
                ContentUnavailableView("Empty Orbit", systemImage: "circle.hexagongrid", description: Text("Items in this scope appear here as a living graph."))
            }
        }
        .task(id: signature) { rebuild() }
    }

    // MARK: Data

    /// Changes when nodes or edges change, independent of sort order.
    private var signature: Int {
        var sig = store.brain.vectors.count &* 31 &+ (semantic ? 1 : 0)
        for item in store.visible.prefix(cap) {
            var h = Hasher()
            h.combine(item.id)
            h.combine(item.space)
            h.combine(item.project)
            h.combine(item.links)
            sig ^= h.finalize()
        }
        var m = Hasher()
        m.combine(store.meta.spaces)
        m.combine(store.meta.projects)
        return sig ^ m.finalize()
    }

    private func rebuild() {
        let items = Array(store.visible.prefix(cap))
        let ids = Set(items.map(\.id))
        let spaces = Set(items.compactMap(\.space)), projects = Set(items.compactMap(\.project))
        var nodes: [GraphModel.Node] = []
        var edges: [(UUID, UUID, GraphModel.Link)] = []
        for space in store.meta.spaces where spaces.contains(space.id) {
            nodes.append(.init(id: space.id, role: .space, color: space.color, radius: 15))
        }
        for project in store.meta.projects where projects.contains(project.id) {
            nodes.append(.init(id: project.id, role: .project, color: store.space(project.space)?.color ?? .gray, radius: 9))
            edges.append((project.id, project.space, .tree))
        }
        for item in items {
            nodes.append(.init(id: item.id, role: .item, color: store.space(item.space)?.color ?? .gray,
                               radius: 4.5 + min(Double(item.links.count), 6) * 0.7))
            if let p = item.project, projects.contains(p) { edges.append((item.id, p, .tree)) }
            else if let s = item.space { edges.append((item.id, s, .tree)) }
            for link in item.links where ids.contains(link) { edges.append((item.id, link, .explicit)) }
        }
        if semantic {
            for (a, b) in store.brain.pairs(among: items.map(\.id), k: 2, minScore: 0.55) { edges.append((a, b, .semantic)) }
        }
        model.load(nodes: nodes, edges: edges)
    }

    private func label(_ node: GraphModel.Node) -> String {
        switch node.role {
        case .space: store.space(node.id)?.name ?? ""
        case .project: store.project(node.id)?.name ?? ""
        case .item: store.items[node.id]?.display ?? ""
        }
    }

    // MARK: Drawing

    private func draw(_ context: GraphicsContext, center: CGPoint, scale: Double, selection: Set<UUID>) {
        let m = model
        func point(_ i: Int) -> CGPoint { CGPoint(x: center.x + m.pos[i].x * scale, y: center.y + m.pos[i].y * scale) }
        let focus = hover ?? m.nodes.firstIndex { selection.contains($0.id) }
        let lit = focus.map { m.neighbours[$0].union([$0]) }

        var tree = Path(), explicit = Path(), similar = Path(), active = Path()
        for e in m.edges {
            let (a, b) = (point(e.a), point(e.b))
            if let focus, e.a == focus || e.b == focus {
                active.move(to: a); active.addLine(to: b)
                continue
            }
            switch e.link {
            case .tree: tree.move(to: a); tree.addLine(to: b)
            case .explicit: explicit.move(to: a); explicit.addLine(to: b)
            case .semantic: similar.move(to: a); similar.addLine(to: b)
            }
        }
        let dim = lit == nil ? 1.0 : 0.35
        context.stroke(tree, with: .color(.secondary.opacity(0.25 * dim)), lineWidth: 1)
        context.stroke(similar, with: .color(.purple.opacity(0.35 * dim)), style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
        context.stroke(explicit, with: .color(.accentColor.opacity(0.7 * dim)), lineWidth: 1.5)
        context.stroke(active, with: .color(.accentColor), lineWidth: 2)

        for (i, node) in m.nodes.enumerated() {
            let p = point(i)
            let r = node.radius * max(0.75, scale.squareRoot())
            let rect = CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)
            let faded = lit.map { !$0.contains(i) } ?? false
            if selection.contains(node.id) || i == hover {
                context.fill(Circle().path(in: rect.insetBy(dx: -5, dy: -5)), with: .color(node.color.opacity(0.3)))
            }
            context.fill(Circle().path(in: rect), with: .color(node.color.opacity(faded ? 0.25 : 1)))
            if node.role != .item {
                context.stroke(Circle().path(in: rect.insetBy(dx: -3, dy: -3)), with: .color(node.color.opacity(faded ? 0.15 : 0.45)), lineWidth: 1.5)
            }
            let showLabel = node.role != .item || scale > 1.6 || (lit?.contains(i) ?? false)
            if showLabel && !faded {
                let font: Font = node.role == .space ? .headline : node.role == .project ? .subheadline.weight(.medium) : .caption
                context.draw(Text(label(node)).font(font).foregroundStyle(.primary), at: CGPoint(x: p.x, y: p.y + r + 4), anchor: .top)
            }
        }
    }

    // MARK: Interaction

    private func toModel(_ p: CGPoint, _ center: CGPoint, _ scale: Double) -> SIMD2<Double> {
        SIMD2((p.x - center.x) / scale, (p.y - center.y) / scale)
    }

    private func drag(center: CGPoint, scale: Double) -> some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { value in
                if panStart == nil && model.dragging == nil {
                    if let i = model.hit(toModel(value.startLocation, center, scale), scale: scale) { model.dragging = i } else { panStart = pan }
                }
                if let i = model.dragging {
                    model.pos[i] = toModel(value.location, center, scale)
                    model.heat(0.25)
                } else if let start = panStart {
                    pan = CGSize(width: start.width + value.translation.width, height: start.height + value.translation.height)
                }
            }
            .onEnded { _ in
                model.dragging = nil
                panStart = nil
            }
    }

    private func tap(_ point: CGPoint, center: CGPoint, scale: Double) {
        guard let i = model.hit(toModel(point, center, scale), scale: scale) else {
            store.selection = []
            return
        }
        let node = model.nodes[i]
        withAnimation(.snappy) {
            switch node.role {
            case .space: store.scope = .space(node.id)
            case .project: store.scope = .project(node.id)
            case .item: store.selection = [node.id]
            }
        }
    }

    private func clamp(_ z: Double) -> Double { min(max(z, 0.25), 4) }

    private var legend: some View {
        HStack(spacing: 14) {
            Label("Space", systemImage: "circle.circle.fill")
            Label("Item", systemImage: "circle.fill").imageScale(.small)
            Label("Link", systemImage: "line.diagonal").foregroundStyle(.tint)
            if semantic { Label("Similar", systemImage: "line.diagonal").foregroundStyle(.purple) }
            Text("\(model.nodes.count) nodes").foregroundStyle(.secondary).monospacedDigit()
        }
        .font(.caption)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: .capsule)
        .padding(16)
    }

    private var controls: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 8) {
                Button { zoom = clamp(zoom / 1.35) } label: { Image(systemName: "minus.magnifyingglass") }
                Button { zoom = 1; pan = .zero } label: { Image(systemName: "scope") }
                Button { zoom = clamp(zoom * 1.35) } label: { Image(systemName: "plus.magnifyingglass") }
                Toggle(isOn: $semantic) { Image(systemName: "sparkles") }
                    .toggleStyle(.button)
                    .help("Show semantic similarity (on-device embeddings)")
            }
            .buttonStyle(.glass)
        }
        .padding(16)
    }
}
