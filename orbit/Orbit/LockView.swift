import SwiftUI

struct LockView: View {
    @Environment(Store.self) private var store
    @State private var password = ""
    @State private var confirm = ""
    @State private var draft: URL?          // folder for a vault that is being created
    @State private var picking: Pick?
    @State private var error: String?
    @State private var busy = false
    @State private var attempts: CGFloat = 0
    @FocusState private var focused: Bool

    enum Pick { case create, open }

    var body: some View {
        ZStack {
            OrbitBackground()
            VStack(spacing: 28) {
                OrbitMark().frame(width: 130, height: 130)
                VStack(spacing: 6) {
                    Text("Orbit").font(.system(size: 42, weight: .bold, design: .rounded))
                    Text(subtitle).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                Group {
                    if store.location != nil { unlockForm } else if draft != nil { createForm } else { setup }
                }
                .frame(maxWidth: 340)
                .modifier(Shake(animatableData: attempts))
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(.orange)
                        .transition(.opacity)
                }
            }
            .padding(36)
            .disabled(busy)
        }
        .environment(\.colorScheme, .dark)
        .animation(.smooth, value: draft)
        .animation(.smooth, value: error)
        .fileImporter(isPresented: Binding(get: { picking != nil }, set: { if !$0 { picking = nil } }),
                      allowedContentTypes: [.folder]) { result in
            guard case .success(let url) = result, let mode = picking else { return }
            picked(url, mode)
        }
        .task(id: store.location) {
            if store.hasBiometricKey && !store.manualLock { _ = await store.unlockWithBiometrics() }
        }
    }

    private var subtitle: String {
        if store.location != nil { return "Your vault is locked." }
        return "Files, knowledge, questions and chats.\nEncrypted on your devices."
    }

    private var setup: some View {
        VStack(spacing: 12) {
            Button { draft = VaultLocation.local } label: {
                Label("Create Vault on This Device", systemImage: "lock.shield").frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            Button { picking = .create } label: {
                Label("Create in Folder (iCloud Drive)…", systemImage: "icloud").frame(maxWidth: .infinity)
            }
            .buttonStyle(.glass)
            Button { picking = .open } label: {
                Label("Open Existing Vault…", systemImage: "folder").frame(maxWidth: .infinity)
            }
            .buttonStyle(.glass)
        }
        .controlSize(.large)
    }

    private var createForm: some View {
        VStack(spacing: 12) {
            SecureField("Passphrase (at least 8 characters)", text: $password).focused($focused)
            SecureField("Repeat passphrase", text: $confirm).onSubmit(create)
            Text("There is no recovery. Without the passphrase your data can't be decrypted.")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            HStack {
                Button("Back") { draft = nil; error = nil }.buttonStyle(.glass)
                Button(action: create) {
                    Label(busy ? "Creating…" : "Create Vault", systemImage: "key.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .disabled(password.count < 8 || password != confirm)
            }
        }
        .textFieldStyle(.roundedBorder)
        .controlSize(.large)
        .onAppear { focused = true }
    }

    private var unlockForm: some View {
        VStack(spacing: 12) {
            HStack {
                SecureField("Passphrase", text: $password).focused($focused).onSubmit(unlock)
                    .textFieldStyle(.roundedBorder)
                if store.hasBiometricKey {
                    Button { Task { if !(await store.unlockWithBiometrics()) { fail("Biometric unlock failed.") } } } label: {
                        #if os(macOS)
                        Image(systemName: "touchid")
                        #else
                        Image(systemName: "faceid")
                        #endif
                    }
                    .buttonStyle(.glass)
                }
            }
            Button(action: unlock) {
                Label(busy ? "Unlocking…" : "Unlock", systemImage: "lock.open.fill").frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .disabled(password.isEmpty)
            Button("Use Another Vault") { store.forgetVault() }
                .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
        }
        .controlSize(.large)
        .onAppear { focused = true }
    }

    private func picked(_ url: URL, _ mode: Pick) {
        _ = url.startAccessingSecurityScopedResource()
        error = nil
        if Vault.exists(at: url) {
            store.choose(url)
        } else if mode == .open {
            fail(VaultError.notAVault.localizedDescription)
        } else {
            draft = url.appending(path: "Orbit Vault", directoryHint: .isDirectory)
        }
    }

    private func create() {
        guard let draft, password.count >= 8, password == confirm else { return }
        run { try await store.create(at: draft, password: password) }
    }

    private func unlock() {
        guard !password.isEmpty else { return }
        run { try await store.unlock(password: password) }
    }

    private func run(_ work: @escaping () async throws -> Void) {
        busy = true
        error = nil
        Task {
            do {
                try await work()
                password = ""
                confirm = ""
                draft = nil
            } catch {
                fail(error.localizedDescription)
            }
            busy = false
        }
    }

    private func fail(_ message: String) {
        error = message
        withAnimation(.linear(duration: 0.4)) { attempts += 1 }
    }
}

struct SettingsView: View {
    @Environment(Store.self) private var store
    @AppStorage(Pref.biometric) private var biometric = true
    @AppStorage(Pref.autoLock) private var autoLock = true
    @AppStorage(Pref.autoEnrich) private var autoEnrich = true
    @State private var password = ""
    @State private var confirm = ""
    @State private var message: String?

    var body: some View {
        Form {
            Section("Security") {
                Toggle("Unlock with Touch ID / Face ID", isOn: $biometric)
                    .onChange(of: biometric) { _, on in store.setBiometric(on) }
                Toggle("Lock when the device sleeps or the app goes to the background", isOn: $autoLock)
                SecureField("New passphrase", text: $password)
                SecureField("Repeat new passphrase", text: $confirm)
                Button("Change Passphrase") {
                    Task {
                        do { try await store.changePassword(password); message = "Passphrase changed." }
                        catch { message = error.localizedDescription }
                        password = ""
                        confirm = ""
                    }
                }
                .disabled(!store.isUnlocked || password.count < 8 || password != confirm)
                if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
            }
            Section("Intelligence") {
                Toggle("Title, summarize and tag new items automatically", isOn: $autoEnrich)
                LabeledContent("Apple Intelligence", value: AI.isAvailable ? "Available" : "Not available")
                Text("Embeddings, tags, summaries and answers run on this device. Orbit makes no network requests.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Vault") {
                LabeledContent("Location") {
                    Text(store.location?.path(percentEncoded: false) ?? "None").lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                }
                #if os(macOS)
                if let url = store.location {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                }
                #endif
                Button("Lock Now") { store.lock() }.disabled(!store.isUnlocked)
                Button("Use Another Vault…", role: .destructive) { store.forgetVault() }
            }
        }
        .formStyle(.grouped)
        #if os(macOS)
        .frame(width: 520)
        #endif
    }
}

/// Menu bar quick capture: type, ⌘↩, done.
struct CaptureView: View {
    @Environment(Store.self) private var store
    @Environment(\.openWindow) private var openWindow
    @State private var text = ""
    @State private var kind: Kind = .note
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Quick Capture").font(.headline)
                Spacer()
                Image(systemName: store.isUnlocked ? "lock.open" : "lock.fill").foregroundStyle(.secondary)
            }
            if store.isUnlocked {
                Picker("Kind", selection: $kind) {
                    ForEach([Kind.note, .question, .chat]) { Label($0.label, systemImage: $0.icon).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                TextEditor(text: $text)
                    .font(.body)
                    .focused($focused)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .frame(height: 130)
                    .background(.quinary, in: .rect(cornerRadius: 10))
                HStack {
                    Text("Saved encrypted to your Inbox").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Save") {
                        store.capture(text, kind: kind)
                        text = ""
                    }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.glassProminent)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            } else {
                Text("Unlock your vault to capture.").foregroundStyle(.secondary)
                Button("Open Orbit") {
                    openWindow(id: "main")
                    #if os(macOS)
                    NSApp.activate()
                    #endif
                }
                .buttonStyle(.glassProminent)
            }
        }
        .padding(16)
        .frame(width: 340)
        .onAppear { focused = true }
    }
}
