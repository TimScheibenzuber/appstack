import SwiftUI

struct MainView: View {
    @Environment(Store.self) private var store
    @AppStorage("inspector") private var showInspector = true

    var body: some View {
        @Bindable var store = store
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 210, ideal: 240, max: 320)
        } detail: {
            content
                .toolbar { toolbar }
                .inspector(isPresented: inspectorBinding) {
                    InspectorView().inspectorColumnWidth(min: 320, ideal: 400, max: 680)
                }
        }
        .searchable(text: $store.query, prompt: "Filter")
        .overlay {
            if store.showPalette {
                PaletteView().transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
            }
        }
        .animation(.snappy(duration: 0.25), value: store.showPalette)
        .fileImporter(isPresented: $store.showImporter, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { Task { await store.importFiles(urls) } }
        }
        .dropDestination(for: URL.self) { urls, _ in
            Task { await store.importFiles(urls) }
            return true
        }
    }

    @ViewBuilder private var content: some View {
        Group {
            if let id = store.focused, store.items[id] != nil {
                FocusView(id: id)
            } else if store.scope == .overview {
                OverviewView()
            } else {
                switch store.mode {
                case .list: ItemListView()
                case .board: BoardView()
                case .graph: GraphView()
                }
            }
        }
        .animation(.smooth(duration: 0.35), value: store.focused)
        .animation(.smooth(duration: 0.35), value: store.mode)
    }

    private var inspectorBinding: Binding<Bool> {
        Binding(get: { showInspector && store.selected != nil }, set: { shown in
            #if os(macOS)
            showInspector = shown
            #else
            if !shown { store.selection = [] }
            #endif
        })
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        @Bindable var store = store
        if store.focused == nil && store.scope != .overview {
            ToolbarItem(placement: .principal) {
                Picker("View", selection: $store.mode) {
                    ForEach(Mode.allCases) { Label($0.rawValue.capitalized, systemImage: $0.icon).tag($0) }
                }
                .pickerStyle(.segmented)
            }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Menu {
                Picker("Kind", selection: $store.kindFilter) {
                    Text("All Kinds").tag(Kind?.none)
                    ForEach(Kind.allCases) { Label($0.label, systemImage: $0.icon).tag(Kind?.some($0)) }
                }
            } label: {
                Label("Filter", systemImage: store.kindFilter == nil ? "line.3.horizontal.decrease" : "line.3.horizontal.decrease.circle.fill")
            }
            Menu {
                ForEach(Kind.allCases.filter { $0 != .file }) { kind in
                    Button { store.create(kind) } label: { Label("New \(kind.label)", systemImage: kind.icon) }
                }
                Divider()
                Button { store.showImporter = true } label: { Label("Import Files or Chats…", systemImage: "square.and.arrow.down") }
            } label: {
                Label("New", systemImage: "plus")
            } primaryAction: {
                store.create(.note)
            }
            Button { store.showPalette.toggle() } label: { Label("Command Palette", systemImage: "command") }
            #if os(macOS)
            Button { showInspector.toggle() } label: { Label("Inspector", systemImage: "sidebar.trailing") }
            #endif
        }
    }
}

/// Full-width editor: the mindmap canvas, or a roomy editor for long notes and chats.
struct FocusView: View {
    @Environment(Store.self) private var store
    let id: UUID

    var body: some View {
        let item = store.items[id]
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button { store.focused = nil } label: { Label("Back", systemImage: "chevron.left") }
                    .keyboardShortcut(store.showPalette ? nil : .cancelAction)
                    .buttonStyle(.glass)
                Text(item?.display ?? "").font(.headline).lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            if item?.kind == .mindmap {
                MindmapView(id: id)
            } else {
                EditorView(id: id, wide: true).frame(maxWidth: .infinity)
            }
        }
        .onAppear { store.selection = [id] }
    }
}

struct InspectorView: View {
    @Environment(Store.self) private var store

    var body: some View {
        if let item = store.selected {
            EditorView(id: item.id).id(item.id)
        } else {
            ContentUnavailableView("No Selection", systemImage: "sidebar.trailing",
                                   description: Text("Select an item to edit it."))
        }
    }
}
