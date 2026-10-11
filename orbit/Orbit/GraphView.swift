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
    // Camera: screen offset of the layout origin from the view centre, and scale.
    @ObservationIgnored var zoom = 1.0
    @ObservationIgnored var offset = SIMD2<Double>.zero
    @ObservationIgnored var follow = true
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

    /// Redraws a few frames after a camera change while the layout is at rest.
    func nudge() { heat(0.0065) }

    /// Eases the camera toward a view that fits the whole layout.
    func frame(_ size: CGSize) {
        guard follow, let first = pos.first else { return }
        let lo = pos.reduce(first) { pointwiseMin($0, $1) }, hi = pos.reduce(first) { pointwiseMax($0, $1) }
        let extent = hi - lo + SIMD2(160, 120)
        let target = min(max(min(size.width / extent.x, size.height / extent.y), 0.25), 1.8)
        zoom += (target - zoom) * 0.12
        offset += (-(lo + hi) / 2 * zoom - offset) * 0.12
    }

    func toModel(_ p: CGPoint, in size: CGSize) -> SIMD2<Double> {
        SIMD2((p.x - size.width / 2 - offset.x) / zoom, (p.y - size.height / 2 - offset.y) / zoom)
    }

    func toScreen(_ i: Int, in size: CGSize) -> CGPoint {
        CGPoint(x: size.width / 2 + offset.x + pos[i].x * zoom, y: size.height / 2 + offset.y + pos[i].y * zoom)
    }

    func step() {
        guard alpha > 0.005 else {
            if running { Task { @MainActor in self.running = false } }
            return
        }
        let n = nodes.count
        var force = [SIMD2<Double>](repeating: .zero, count: n)
        let charge = nodes.map { $0.role == .space ? 480.0 : $0.role == .project ? 240 : 90 }
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
            case .tree: hub ? (170, 0.35) : (80, 0.45)
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
    @State private var hover: Int?
    @State private var semantic = true
    @State private var panStart: SIMD2<Double>?
    @State private var zoomStart: Double?

    private let cap = 300

    var body: some View {
        let selection = store.selection
        GeometryReader { geo in
            let size = geo.size
            TimelineView(.animation(paused: !model.running)) { _ in
                Canvas { context, size in
                    model.step()
                    model.frame(size)
                    draw(context, size: size, selection: selection)
                }
            }
            .contentShape(.rect)
            .gesture(drag(size))
            .simultaneousGesture(MagnifyGesture()
                .onChanged { value in
                    if zoomStart == nil { zoomStart = model.zoom }
                    model.follow = false
                    model.zoom = clamp((zoomStart ?? 1) * value.magnification)
                    model.nudge()
                }
                .onEnded { _ in zoomStart = nil })
            .onTapGesture(coordinateSpace: .local) { point in tap(point, size) }
            .onContinuousHover { phase in
                if case .active(let point) = phase {
                    let h = model.hit(model.toModel(point, in: size), scale: model.zoom)
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

    private func draw(_ context: GraphicsContext, size: CGSize, selection: Set<UUID>) {
        let m = model
        let scale = m.zoom
        func point(_ i: Int) -> CGPoint { m.toScreen(i, in: size) }
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
            let showLabel = node.role != .item || m.nodes.count <= 40 || scale > 1.4 || (lit?.contains(i) ?? false)
            if showLabel && !faded {
                let text = node.role == .item
                    ? Text(label(node)).font(.caption).foregroundStyle(.secondary)
                    : Text(label(node)).font(node.role == .space ? .headline : .subheadline.weight(.medium)).foregroundStyle(.primary)
                context.draw(text, at: CGPoint(x: p.x, y: p.y + r + 4), anchor: .top)
            }
        }
    }

    // MARK: Interaction

    private func drag(_ size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { value in
                if panStart == nil && model.dragging == nil {
                    model.follow = false
                    if let i = model.hit(model.toModel(value.startLocation, in: size), scale: model.zoom) { model.dragging = i } else { panStart = model.offset }
                }
                if let i = model.dragging {
                    model.pos[i] = model.toModel(value.location, in: size)
                    model.heat(0.25)
                } else if let start = panStart {
                    model.offset = start + SIMD2(value.translation.width, value.translation.height)
                    model.nudge()
                }
            }
            .onEnded { _ in
                model.dragging = nil
                panStart = nil
            }
    }

    private func tap(_ point: CGPoint, _ size: CGSize) {
        guard let i = model.hit(model.toModel(point, in: size), scale: model.zoom) else {
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

    private func zoom(by factor: Double) {
        model.follow = false
        model.zoom = clamp(model.zoom * factor)
        model.nudge()
    }

    private var legend: some View {
        HStack(spacing: 14) {
            Label("Space", systemImage: "circle.circle.fill")
            Label("Item", systemImage: "circle.fill").imageScale(.small)
            Label("Link", systemImage: "line.diagonal").foregroundStyle(.tint)
            if semantic { Label("Similar", systemImage: "line.diagonal").foregroundStyle(.purple) }
            Text("\(min(store.visible.count, cap)) items").foregroundStyle(.secondary).monospacedDigit()
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
                Button { zoom(by: 1 / 1.35) } label: { Image(systemName: "minus.magnifyingglass") }
                Button { model.follow = true; model.heat(0.06) } label: { Image(systemName: "scope") }
                    .help("Fit the whole graph")
                Button { zoom(by: 1.35) } label: { Image(systemName: "plus.magnifyingglass") }
                Toggle(isOn: $semantic) { Image(systemName: "sparkles") }
                    .toggleStyle(.button)
                    .help("Show semantic similarity (on-device embeddings)")
            }
            .buttonStyle(.glass)
        }
        .padding(16)
    }
}
