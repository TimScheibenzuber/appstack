import SwiftUI

@main
struct OrbitApp: App {
    @State private var store = Store()

    var body: some Scene {
        WindowGroup("Orbit", id: "main") {
            RootView().environment(store)
        }
        .commands { OrbitCommands(store: store) }
        #if os(macOS)
        .defaultSize(width: 1320, height: 840)

        MenuBarExtra("Orbit", systemImage: "circle.circle") {
            CaptureView().environment(store)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView().environment(store)
        }
        #endif
    }
}

struct OrbitCommands: Commands {
    var store: Store

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Group {
                Button("New Note") { store.create(.note) }.keyboardShortcut("n")
                Button("New Question") { store.create(.question) }.keyboardShortcut("n", modifiers: [.command, .shift])
                Button("New Mindmap") { store.create(.mindmap) }.keyboardShortcut("n", modifiers: [.command, .option])
                Button("New Chat") { store.create(.chat) }
                Divider()
                Button("Import Files or Chat Exports…") { store.showImporter = true }
                    .keyboardShortcut("i", modifiers: [.command, .shift])
            }
            .disabled(!store.isUnlocked)
        }

        CommandMenu("Vault") {
            Group {
                Button("Command Palette") { store.showPalette.toggle() }.keyboardShortcut("k")
                Button("Auto-Sort Inbox") { store.autoSort() }
                Divider()
                ForEach(Array(Mode.allCases.enumerated()), id: \.element) { index, mode in
                    Button("Show as \(mode.rawValue.capitalized)") { store.mode = mode; store.focused = nil }
                        .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")))
                }
                Divider()
                Button("Lock Vault") { store.lock(manual: true) }.keyboardShortcut("l")
            }
            .disabled(!store.isUnlocked)
        }
    }
}

struct RootView: View {
    @Environment(Store.self) private var store
    @Environment(\.scenePhase) private var phase

    var body: some View {
        ZStack {
            if store.isUnlocked {
                MainView().transition(.opacity.combined(with: .scale(scale: 1.015)))
            } else {
                LockView().transition(.opacity.combined(with: .scale(scale: 0.985)))
            }
        }
        .animation(.smooth(duration: 0.5), value: store.isUnlocked)
        .overlay(alignment: .bottom) {
            if let notice = store.notice {
                NoticeView(text: notice).padding(.bottom, 26).transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .onChange(of: phase) { _, phase in
            if phase == .active { store.scheduleSync() }
            #if os(iOS)
            if phase == .background && Pref.on(Pref.autoLock) { store.lock() }
            #endif
        }
    }
}
