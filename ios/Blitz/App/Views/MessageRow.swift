import ClaudeKit
import SwiftUI
import UIKit

struct MessageRow: View {
    let message: ChatMessage
    /// Set only for the turn that is currently streaming.
    let live: LiveReply?
    let isLastAssistant: Bool
    let chat: ChatViewModel

    var body: some View {
        switch message.role {
        case .user: userBubble
        case .assistant: assistantBody
        }
    }

    private var userBubble: some View {
        HStack {
            Spacer(minLength: 48)
            Text(message.text)
                .textSelection(.enabled)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color.accentColor.opacity(message.excludedFromContext ? 0.35 : 1), in: RoundedRectangle(cornerRadius: 18))
                .foregroundStyle(.white)
                .contextMenu {
                    Button("Kopieren", systemImage: "doc.on.doc") { UIPasteboard.general.string = message.text }
                    if !chat.isBusy {
                        Button("Bearbeiten", systemImage: "pencil") { chat.edit(message.id) }
                    }
                }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Du: \(message.text)")
    }

    @ViewBuilder
    private var assistantBody: some View {
        if let live {
            LiveReplyView(live: live)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                if !message.thinkingText.isEmpty {
                    ThinkingDisclosure(text: message.thinkingText, isStreaming: false)
                }
                switch message.status {
                case .refused(let category):
                    Label(refusalText(category), systemImage: "hand.raised")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                default:
                    if !message.text.isEmpty {
                        MarkdownView(text: message.text)
                    }
                }
                footer
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contextMenu {
                if !message.text.isEmpty {
                    Button("Kopieren", systemImage: "doc.on.doc") { UIPasteboard.general.string = message.text }
                }
                if isLastAssistant && !chat.isBusy {
                    Button("Neu generieren", systemImage: "arrow.clockwise") { chat.regenerate() }
                }
            }
        }
    }

    @ViewBuilder
    private var footer: some View {
        let details = footerDetails
        if !details.isEmpty {
            Text(details.joined(separator: " · "))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private var footerDetails: [String] {
        var parts: [String] = []
        switch message.status {
        case .stopped: parts.append("Gestoppt")
        case .truncated: parts.append("Längenlimit erreicht")
        case .failed(let text): parts.append(text)
        default: break
        }
        if message.blocks.contains(where: { if case .fallback = $0 { return true } else { return false } }) {
            parts.append("Fallback")
        }
        if let model = message.model {
            parts.append(ModelCatalog.info(for: model).shortName)
        }
        if let usage = message.usage, let output = usage.outputTokens {
            var tokens = "\(output) Tokens"
            if let cached = usage.cacheReadInputTokens, cached > 0 { tokens += " · \(cached) aus Cache" }
            if usage.speed == "fast" { tokens += " · Fast" }
            parts.append(tokens)
        }
        return parts
    }

    private func refusalText(_ category: String?) -> String {
        let base = "Claude hat diese Anfrage abgelehnt"
        return category.map { "\(base) (\($0)). Formuliere sie anders." } ?? "\(base). Formuliere sie anders."
    }
}

private struct LiveReplyView: View {
    let live: LiveReply

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !live.thinking.isEmpty {
                ThinkingDisclosure(text: live.thinking, isStreaming: live.text.isEmpty)
            }
            if live.text.isEmpty && live.thinking.isEmpty {
                TypingIndicator()
            } else if !live.text.isEmpty {
                MarkdownView(text: live.text)
            }
            if let notice = live.notice {
                Label(notice, systemImage: "arrow.triangle.branch")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ThinkingDisclosure: View {
    let text: String
    let isStreaming: Bool
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            Text(text)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
        } label: {
            Label(isStreaming ? "Denkt nach…" : "Gedanken", systemImage: "brain")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .tint(.secondary)
    }
}

private struct TypingIndicator: View {
    var body: some View {
        Image(systemName: "ellipsis")
            .font(.title2)
            .foregroundStyle(.secondary)
            .symbolEffect(.variableColor.iterative, options: .repeating)
            .accessibilityLabel("Claude antwortet")
    }
}
