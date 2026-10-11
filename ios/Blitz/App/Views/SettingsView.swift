import ClaudeKit
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    private let tokenOptions = [8_000, 16_000, 32_000, 64_000, 128_000]

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            Form {
                Section {
                    NavigationLink {
                        APIKeyView(isInitialSetup: false)
                    } label: {
                        LabeledContent("API-Key", value: model.hasAPIKey ? "Gespeichert" : "Fehlt")
                    }
                } footer: {
                    Text("Der Key liegt verschlüsselt im Schlüsselbund dieses Geräts, wird nicht synchronisiert und nur an api.anthropic.com gesendet.")
                }

                Section("Modell") {
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
                    Picker("Max. Antwortlänge", selection: $model.settings.maxTokens) {
                        ForEach(tokenOptions, id: \.self) { tokens in
                            Text("\(tokens / 1000)k Tokens").tag(tokens)
                        }
                    }
                }

                Section {
                    Toggle(isOn: $model.settings.fastMode) {
                        Label("Fast Mode", systemImage: "bolt.fill")
                    }
                    .disabled(!model.settings.model.supportsFastMode)
                    Toggle(isOn: $model.settings.showThinking) {
                        Label("Gedanken live anzeigen", systemImage: "brain")
                    }
                } header: {
                    Text("Geschwindigkeit")
                } footer: {
                    Text("Fast Mode (nur Opus 5.5): bis zu ~2,5× schnellere Ausgabe zum doppelten Token-Preis. Nicht freigeschaltet oder Limit erreicht → automatisch Standard-Geschwindigkeit. Niedriger Aufwand = schnellste erste Antwort.")
                }

                Section {
                    TextField("Optional", text: $model.settings.systemPrompt, axis: .vertical)
                        .lineLimit(3...10)
                } header: {
                    Text("System-Prompt")
                } footer: {
                    Text("Gilt für neue Chats. Bestehende Chats behalten ihren Prompt, damit Cache und Gedanken gültig bleiben.")
                }

                Section("Stabilität & Sicherheit") {
                    InfoRow(icon: "arrow.triangle.2.circlepath", text: "Automatische Wiederholung bei Überlastung, Rate-Limits und Netzabbrüchen")
                    InfoRow(icon: "wifi.exclamationmark", text: "Wartet auf das Netz statt abzubrechen")
                    InfoRow(icon: "shield.lefthalf.filled", text: "Abgelehnte Anfragen laufen automatisch über das empfohlene Fallback-Modell")
                    InfoRow(icon: "lock.fill", text: "Chats verschlüsselt gespeichert, App-Vorschau im App-Umschalter verborgen")
                }
            }
            .navigationTitle("Einstellungen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") { dismiss() }
                }
            }
        }
    }
}

private struct InfoRow: View {
    let icon: String
    let text: String

    var body: some View {
        Label {
            Text(text).font(.footnote)
        } icon: {
            Image(systemName: icon).foregroundStyle(.tint)
        }
    }
}

struct APIKeyView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let isInitialSetup: Bool

    @State private var key = ""
    @State private var isChecking = false
    @State private var message: String?

    var body: some View {
        Form {
            Section {
                SecureField("sk-ant-…", text: $key)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(.body, design: .monospaced))
                    .onSubmit(save)
                Button("Aus Zwischenablage einfügen", systemImage: "doc.on.clipboard") {
                    key = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                }
            } header: {
                Text("Anthropic API-Key")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Den Key erstellst du in der Claude Console unter „API Keys“. Er wird vor dem Speichern geprüft (ohne Token-Kosten).")
                    Link("console.anthropic.com öffnen", destination: URL(string: "https://console.anthropic.com/settings/keys")!)
                }
            }

            if let message {
                Section {
                    Text(message).foregroundStyle(.red)
                }
            }

            Section {
                Button(action: save) {
                    HStack {
                        Text("Prüfen & speichern")
                        if isChecking {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(isChecking || key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                if model.hasAPIKey && !isInitialSetup {
                    Button("Gespeicherten Key entfernen", role: .destructive) {
                        Task {
                            await model.removeAPIKey()
                            dismiss()
                        }
                    }
                }
            }
        }
        .navigationTitle("API-Key")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if isInitialSetup && model.hasAPIKey {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Schließen") { dismiss() }
                }
            }
        }
    }

    private func save() {
        let candidate = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty, !isChecking else { return }
        isChecking = true
        message = nil
        Task {
            defer { isChecking = false }
            do {
                switch try await model.saveAPIKey(candidate) {
                case .valid:
                    key = ""
                    dismiss()
                case .invalid:
                    message = "Dieser Key wurde von der API abgelehnt."
                }
            } catch {
                message = ErrorPresentation(error).message
            }
        }
    }
}
