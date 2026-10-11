import ClaudeKit
import SwiftUI

struct ChatView: View {
    @Environment(AppModel.self) private var model
    @Bindable var chat: ChatViewModel
    @State private var isPinnedToBottom = true
    @FocusState private var composerFocused: Bool

    private static let bottomID = "bottom"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    ForEach(chat.conversation.messages) { message in
                        MessageRow(
                            message: message,
                            live: message.status == .streaming ? chat.live : nil,
                            isLastAssistant: message.id == chat.lastAssistantID,
                            chat: chat
                        )
                        .id(message.id)
                    }
                    Color.clear
                        .frame(height: 1)
                        .id(Self.bottomID)
                        .onAppear { isPinnedToBottom = true }
                        .onDisappear { isPinnedToBottom = false }
                }
                .padding(.horizontal)
                .padding(.vertical, 12)
                .frame(maxWidth: 820)
                .frame(maxWidth: .infinity)
            }
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: chat.live.text) { _, _ in
                if isPinnedToBottom { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
            }
            .onChange(of: chat.conversation.messages.count) { _, _ in
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
            }
            .overlay(alignment: .bottomTrailing) {
                if !isPinnedToBottom {
                    Button {
                        withAnimation { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
                    } label: {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.title)
                            .symbolRenderingMode(.hierarchical)
                    }
                    .padding()
                    .accessibilityLabel("Zum Ende scrollen")
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                StatusStrip(chat: chat, isOnline: model.isOnline)
                ComposerView(chat: chat, focused: $composerFocused)
            }
            .background(.bar)
        }
        .navigationTitle(chat.conversation.displayTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                ModelMenu()
            }
        }
        .onAppear {
            if chat.conversation.messages.isEmpty { composerFocused = true }
        }
    }
}

/// Activity, connectivity and error banner above the composer.
private struct StatusStrip: View {
    @Environment(AppModel.self) private var model
    let chat: ChatViewModel
    let isOnline: Bool
    @State private var showKeySetup = false

    var body: some View {
        VStack(spacing: 6) {
            if let banner = chat.banner {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: banner.kind == .info ? "info.circle" : "exclamationmark.triangle.fill")
                        .foregroundStyle(banner.kind == .info ? Color.secondary : Color.orange)
                    Text(banner.text)
                        .font(.footnote)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if banner.kind == .missingKey {
                        Button("API-Key") { showKeySetup = true }
                            .font(.footnote.bold())
                    } else if banner.kind == .error, !chat.isBusy {
                        Button("Erneut") { chat.regenerate() }
                            .font(.footnote.bold())
                    }
                    Button {
                        chat.dismissBanner()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.footnote)
                    }
                    .accessibilityLabel("Hinweis schließen")
                }
                .padding(10)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
            }
            if let status = statusText {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else if !isOnline {
                Label("Offline", systemImage: "wifi.slash")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal)
        .padding(.top, chat.banner == nil && statusText == nil && isOnline ? 0 : 8)
        .animation(.default, value: chat.banner)
        .sheet(isPresented: $showKeySetup) {
            NavigationStack { APIKeyView(isInitialSetup: false) }
        }
    }

    private var statusText: String? {
        switch chat.activity {
        case .idle, .streaming: return nil
        case .connecting: return "Verbinde…"
        case .waitingForNetwork: return "Warte auf Netzwerk…"
        case .retrying(let attempt): return "Neuer Versuch (\(attempt))…"
        }
    }
}

/// Quick model switch in the toolbar; applies from the next message on.
private struct ModelMenu: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Menu {
            Picker("Modell", selection: $model.settings.modelID) {
                ForEach(ModelCatalog.all) { info in
                    Text(info.displayName).tag(info.id)
                }
            }
            Picker("Aufwand", selection: $model.settings.effort) {
                ForEach(Effort.allCases) { effort in
                    Text(effort.label).tag(effort)
                }
            }
            if model.settings.model.supportsFastMode {
                Toggle("Fast Mode", isOn: $model.settings.fastMode)
            }
        } label: {
            HStack(spacing: 4) {
                if model.settings.fastMode && model.settings.model.supportsFastMode {
                    Image(systemName: "bolt.fill")
                }
                Text(model.settings.model.shortName)
            }
            .font(.subheadline.weight(.medium))
        }
        .accessibilityLabel("Modell und Geschwindigkeit")
    }
}

extension ModelInfo {
    var shortName: String {
        displayName.replacingOccurrences(of: "Claude ", with: "")
    }
}

extension Effort {
    var label: String {
        switch self {
        case .low: return "Niedrig – am schnellsten"
        case .medium: return "Mittel"
        case .high: return "Hoch"
        case .xhigh: return "Sehr hoch"
        case .max: return "Maximum"
        }
    }
}
