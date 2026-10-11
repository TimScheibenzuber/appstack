import SwiftUI

struct ComposerView: View {
    @Bindable var chat: ChatViewModel
    var focused: FocusState<Bool>.Binding

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("Nachricht an Claude", text: $chat.draft, axis: .vertical)
                .lineLimit(1...8)
                .focused(focused)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20))
                .onChange(of: chat.draft.isEmpty) { _, isEmpty in
                    // First keystroke: open/refresh the connection so sending skips the handshake.
                    if !isEmpty { chat.userIsTyping() }
                }

            if chat.isBusy {
                Button {
                    chat.stop()
                } label: {
                    Image(systemName: "stop.circle.fill")
                        .font(.system(size: 32))
                        .symbolRenderingMode(.hierarchical)
                }
                .keyboardShortcut(.escape, modifiers: [])
                .accessibilityLabel("Antwort stoppen")
            } else {
                Button {
                    chat.send()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 32))
                }
                .disabled(!chat.canSend)
                .keyboardShortcut(.return, modifiers: .command)
                .accessibilityLabel("Senden")
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }
}
