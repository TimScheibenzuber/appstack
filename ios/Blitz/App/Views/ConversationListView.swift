import ClaudeKit
import SwiftUI

struct ConversationListView: View {
    @Environment(AppModel.self) private var model
    @Binding var showSettings: Bool

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selectedID) {
            if !model.isOnline {
                Label("Offline – Nachrichten werden gesendet, sobald das Netz zurück ist", systemImage: "wifi.slash")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ForEach(model.summaries) { summary in
                NavigationLink(value: summary.id) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(summary.title)
                            .lineLimit(1)
                        Text(summary.updatedAt, format: .relative(presentation: .named))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .contextMenu {
                    Button("Löschen", systemImage: "trash", role: .destructive) {
                        model.deleteConversations([summary.id])
                    }
                }
            }
            .onDelete { offsets in
                model.deleteConversations(offsets.map { model.summaries[$0].id })
            }
        }
        .navigationTitle("Chats")
        .overlay {
            if model.summaries.isEmpty {
                ContentUnavailableView("Noch keine Chats", systemImage: "bubble.left.and.bubble.right")
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Einstellungen", systemImage: "gearshape") { showSettings = true }
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Neuer Chat", systemImage: "square.and.pencil") { model.newConversation() }
                    .keyboardShortcut("n", modifiers: .command)
            }
        }
    }
}
