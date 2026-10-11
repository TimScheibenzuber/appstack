import SwiftUI

struct SidebarView: View {
    @Environment(Store.self) private var store
    @State private var editing: Space?
    @State private var naming: Naming?
    @State private var name = ""
    #if os(iOS)
    @State private var settings = false
    #endif

    /// Target of the shared "name it" alert.
    enum Naming: Identifiable {
        case space, project(UUID), renameProject(Project)
        var id: String {
            switch self {
            case .space: "space"
            case .project(let id): "p" + id.uuidString
            case .renameProject(let p): "r" + p.id.uuidString
            }
        }
    }

    var body: some View {
        List(selection: Binding<Scope?>(get: { store.scope }, set: { if let s = $0 { store.scope = s; store.focused = nil } })) {
            Section {
                row(.overview, "Overview", "square.grid.2x2")
                row(.inbox, "Inbox", "tray", count: store.count(.inbox))
                row(.all, "All Items", "tray.full")
                row(.questions, "Open Questions", "questionmark.bubble", count: store.count(.questions))
                row(.pinned, "Pinned", "pin")
            }

            Section("Spaces") {
                ForEach(store.meta.spaces) { space in
                    Label { Text(space.name) } icon: { Image(systemName: space.icon).foregroundStyle(space.color) }
                        .badge(store.count(.space(space.id)))
                        .tag(Scope.space(space.id))
                        .dropDestination(for: String.self) { ids, _ in
                            store.move(Set(ids.compactMap(UUID.init(uuidString:))), to: space.id)
                            return true
                        }
                        .contextMenu {
                            Button("New Project…") { ask(.project(space.id)) }
                            Button("Edit Space…") { editing = space }
                            Divider()
                            Button("Delete Space", role: .destructive) { store.deleteSpace(space.id) }
                        }
                        .popover(isPresented: Binding(get: { editing?.id == space.id }, set: { if !$0 { editing = nil } })) {
                            SpaceEditor(space: space)
                        }
                    ForEach(store.projects(in: space.id)) { project in
                        Label(project.name, systemImage: "folder")
                            .padding(.leading, 14)
                            .badge(store.count(.project(project.id)))
                            .tag(Scope.project(project.id))
                            .dropDestination(for: String.self) { ids, _ in
                                store.move(Set(ids.compactMap(UUID.init(uuidString:))), to: space.id, project: project.id)
                                return true
                            }
                            .contextMenu {
                                Button("Rename…") { ask(.renameProject(project)) }
                                Button("Archive") { var p = project; p.archived = true; store.updateProject(p) }
                                Button("Delete Project", role: .destructive) { store.deleteProject(project.id) }
                            }
                    }
                }
                Button { ask(.space) } label: { Label("New Space", systemImage: "plus") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }

            Section {
                row(.trash, "Trash", "trash", count: store.count(.trash))
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) { footer }
        .alert(title, isPresented: Binding(get: { naming != nil }, set: { if !$0 { naming = nil } })) {
            TextField("Name", text: $name)
            Button("Save") { commit() }
            Button("Cancel", role: .cancel) {}
        }
        #if os(iOS)
        .toolbar {
            Button { settings = true } label: { Label("Settings", systemImage: "gearshape") }
        }
        .sheet(isPresented: $settings) { NavigationStack { SettingsView() } }
        #endif
    }

    private func row(_ scope: Scope, _ title: String, _ icon: String, count: Int = 0) -> some View {
        Label(title, systemImage: icon)
            .badge(count)
            .tag(scope)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.shield.fill").foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 0) {
                Text("Encrypted vault").font(.caption.weight(.semibold))
                Text("\(store.count(.all)) items · AES-256").font(.caption2).foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }
            Spacer()
            Button { store.lock(manual: true) } label: { Image(systemName: "lock.fill") }
                .buttonStyle(.glass)
                .help("Lock vault (⌘L)")
        }
        .padding(12)
    }

    private var title: String {
        switch naming {
        case .space: "New Space"
        case .project: "New Project"
        case .renameProject: "Rename Project"
        case nil: ""
        }
    }

    private func ask(_ target: Naming) {
        if case .renameProject(let p) = target { name = p.name } else { name = "" }
        naming = target
    }

    private func commit() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let naming else { return }
        switch naming {
        case .space: store.addSpace(trimmed)
        case .project(let space): store.scope = .project(store.addProject(trimmed, in: space).id)
        case .renameProject(var p): p.name = trimmed; store.updateProject(p)
        }
    }
}

struct SpaceEditor: View {
    @Environment(Store.self) private var store
    @State var space: Space
    private let symbols = ["briefcase.fill", "leaf.fill", "graduationcap.fill", "flask.fill", "heart.fill", "house.fill",
                           "star.fill", "bolt.fill", "globe.europe.africa.fill", "hammer.fill", "paintpalette.fill", "brain.head.profile",
                           "chart.line.uptrend.xyaxis", "book.fill", "airplane", "circle.fill"]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            TextField("Name", text: $space.name).textFieldStyle(.roundedBorder).font(.headline)
            HStack(spacing: 8) {
                ForEach(0..<Palette.count, id: \.self) { tone in
                    Circle().fill(Palette.color(tone)).frame(width: 22, height: 22)
                        .overlay(Circle().strokeBorder(.primary, lineWidth: space.tone == tone ? 2 : 0).padding(-3))
                        .onTapGesture { withAnimation(.snappy) { space.tone = tone } }
                }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(30), spacing: 6), count: 8), spacing: 6) {
                ForEach(symbols, id: \.self) { symbol in
                    Image(systemName: symbol)
                        .frame(width: 30, height: 30)
                        .foregroundStyle(space.icon == symbol ? .white : space.color)
                        .background(space.icon == symbol ? space.color : .clear, in: .rect(cornerRadius: 8))
                        .onTapGesture { withAnimation(.snappy) { space.icon = symbol } }
                }
            }
        }
        .padding(16)
        .frame(width: 300)
        .onChange(of: space) { _, space in store.updateSpace(space) }
    }
}
