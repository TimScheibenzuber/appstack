import ClaudeKit
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic
    @State private var showSettings = false
    @State private var showKeySetup = false

    var body: some View {
        @Bindable var model = model
        NavigationSplitView(columnVisibility: $columnVisibility) {
            ConversationListView(showSettings: $showSettings)
        } detail: {
            if let id = model.selectedID {
                ChatContainer(id: id)
                    .id(id)
            } else {
                EmptyChatPlaceholder()
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .sheet(isPresented: $showKeySetup) {
            NavigationStack { APIKeyView(isInitialSetup: true) }
                .interactiveDismissDisabled(!model.hasAPIKey)
        }
        .overlay {
            // Hides conversation content in the app switcher snapshot.
            if scenePhase != .active { PrivacyShield() }
        }
        .onChange(of: scenePhase) { _, phase in
            model.scenePhaseChanged(to: phase)
        }
        .onChange(of: model.isLoaded) { _, loaded in
            if loaded && !model.hasAPIKey { showKeySetup = true }
        }
        .alert("Speicherfehler", isPresented: $model.isShowingStorageError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.storageError ?? "")
        }
    }
}

/// Resolves the view model for a conversation (loading it from disk if needed).
private struct ChatContainer: View {
    @Environment(AppModel.self) private var model
    let id: UUID
    @State private var chat: ChatViewModel?
    @State private var failed = false

    var body: some View {
        Group {
            if let chat {
                ChatView(chat: chat)
            } else if failed {
                ContentUnavailableView("Chat nicht gefunden", systemImage: "exclamationmark.bubble")
            } else {
                ProgressView()
            }
        }
        .task(id: id) {
            if let cached = model.chat(for: id) {
                chat = cached
            } else if let loaded = await model.openChat(id) {
                chat = loaded
            } else {
                failed = true
            }
        }
    }
}

private struct EmptyChatPlaceholder: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ContentUnavailableView {
            Label("Blitz", systemImage: "bolt.fill")
        } description: {
            Text("Schnelle Unterhaltungen mit Claude.")
        } actions: {
            Button("Neuer Chat") { model.newConversation() }
                .buttonStyle(.borderedProminent)
        }
    }
}

struct PrivacyShield: View {
    var body: some View {
        ZStack {
            Rectangle().fill(.regularMaterial)
            Image(systemName: "bolt.fill")
                .font(.system(size: 56, weight: .semibold))
                .foregroundStyle(.tint)
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}
