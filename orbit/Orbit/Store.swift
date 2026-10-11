import SwiftUI
#if os(macOS)
import AppKit
#endif

enum Pref {
    static let biometric = "biometricUnlock"
    static let autoLock = "autoLock"
    static let autoEnrich = "autoEnrich"
    static func on(_ key: String) -> Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? true }
}

/// App state. Everything decrypted lives only in memory while the vault is unlocked.
@MainActor @Observable
final class Store {
    // Session
    private(set) var vault: Vault?
    private(set) var location: URL? = VaultLocation.restore()
    var isUnlocked: Bool { vault != nil }

    // Data
    private(set) var items: [UUID: Item] = [:]
    private(set) var meta = Meta()
    let brain = Brain()

    // Navigation
    var scope: Scope = .overview
    var mode: Mode = .list
    var selection: Set<UUID> = []
    var focused: UUID?
    var kindFilter: Kind?
    var query = ""
    var showPalette = false
    var showImporter = false
    private(set) var notice: String?
    private(set) var manualLock = false
    private(set) var working: Set<UUID> = []

    @ObservationIgnored private var pending: Set<UUID> = []
    @ObservationIgnored private var stamps: [UUID: Date] = [:]
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var syncTask: Task<Void, Never>?
    @ObservationIgnored private var noticeTask: Task<Void, Never>?
    @ObservationIgnored private var watcher: DispatchSourceFileSystemObject?
    @ObservationIgnored private let thumbs = NSCache<NSUUID, CGImage>()

    init() {
        #if os(macOS)
        let lockIfEnabled: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { if Pref.on(Pref.autoLock) { self?.lock() } }
        }
        _ = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main, using: lockIfEnabled)
        _ = DistributedNotificationCenter.default().addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main, using: lockIfEnabled)
        _ = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.lock() }
        }
        #endif
    }

    // MARK: Session

    var hasBiometricKey: Bool {
        guard Pref.on(Pref.biometric), let url = location, let header = try? Vault.readHeader(url) else { return false }
        return Keychain.has(header.id.uuidString)
    }

    func create(at url: URL, password: String) async throws {
        let vault = try await Task.detached { try Vault.create(at: url, password: password) }.value
        VaultLocation.remember(url)
        location = url
        await attach(vault)
    }

    func choose(_ url: URL) {
        VaultLocation.remember(url)
        location = url
    }

    func unlock(password: String) async throws {
        guard let url = location else { return }
        let vault = try await Task.detached { try Vault.open(at: url, password: password) }.value
        await attach(vault)
    }

    func unlockWithBiometrics() async -> Bool {
        guard let url = location, let header = try? Vault.readHeader(url), await Keychain.authenticate(),
              let key = Keychain.get(header.id.uuidString), let vault = try? Vault.open(at: url, key: key) else { return false }
        await attach(vault)
        return true
    }

    private func attach(_ vault: Vault) async {
        if Pref.on(Pref.biometric) { Keychain.set(vault.keyData, for: vault.id.uuidString) }
        manualLock = false
        meta = (try? vault.loadMeta()) ?? Meta()
        self.vault = vault
        await sync()
        watch(vault)
    }

    func lock(manual: Bool = false) {
        guard let vault else { return }
        manualLock = manual
        saveTask?.cancel()
        for id in pending {
            if let item = items[id] { _ = try? vault.save(item) } else { vault.delete(id) }
        }
        pending = []
        watcher?.cancel()
        watcher = nil
        self.vault = nil
        items = [:]
        stamps = [:]
        selection = []
        focused = nil
        showPalette = false
        brain.reset()
        thumbs.removeAllObjects()
        Vault.wipeTemp()
    }

    func forgetVault() {
        lock()
        VaultLocation.forget()
        location = nil
    }

    func changePassword(_ password: String) async throws {
        guard let vault else { return }
        try await Task.detached { try vault.changePassword(password) }.value
    }

    func setBiometric(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: Pref.biometric)
        guard let vault else { return }
        if on { Keychain.set(vault.keyData, for: vault.id.uuidString) } else { Keychain.delete(vault.id.uuidString) }
    }

    // MARK: Sync

    /// Loads files that changed on disk (another device, iCloud) and drops deleted ones.
    func sync() async {
        guard let vault else { return }
        let known = stamps
        let (changed, listing, meta) = await Task.detached(priority: .userInitiated) {
            let listing = vault.listing()
            let ids = listing.filter { known[$0.key] != $0.value }.map(\.key)
            return (vault.load(ids), listing, try? vault.loadMeta())
        }.value
        guard self.vault === vault else { return }
        for item in changed where !pending.contains(item.id) { items[item.id] = item }
        for id in known.keys where listing[id] == nil {
            stamps[id] = nil
            if !pending.contains(id) { items[id] = nil }
        }
        stamps.merge(listing) { _, new in new }
        if let meta, meta != self.meta { self.meta = meta }
        brain.refresh(Array(items.values))
    }

    private func watch(_ vault: Vault) {
        let fd = Darwin.open(vault.itemsDir.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.scheduleSync() } }
        source.setCancelHandler { close(fd) }
        source.resume()
        watcher = source
    }

    func scheduleSync() {
        syncTask?.cancel()
        syncTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            if !Task.isCancelled { await sync() }
        }
    }

    // MARK: Saving

    func update(_ item: Item) {
        var item = item
        item.updated = .now
        items[item.id] = item
        markDirty(item.id)
    }

    private func markDirty(_ id: UUID) {
        pending.insert(id)
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(450))
            if !Task.isCancelled { await flush() }
        }
    }

    /// Encrypts and writes pending changes off the main thread.
    private func flush() async {
        guard let vault, !pending.isEmpty else { return }
        let batch = pending.map { ($0, items[$0]) }
        pending = []
        let results = await Task.detached(priority: .utility) {
            batch.map { entry -> (UUID, Date?, Bool) in
                let (id, item) = entry
                guard let item else { vault.delete(id); return (id, nil, true) }
                let date = try? vault.save(item)
                return (id, date, date != nil)
            }
        }.value
        for (id, date, ok) in results {
            if ok { stamps[id] = date } else { pending.insert(id); notify("Couldn't save a change. Retrying on next edit.") }
        }
        brain.refresh(Array(items.values))
    }

    func saveMeta() {
        try? vault?.save(meta)
    }

    func notify(_ text: String) {
        withAnimation(.snappy) { notice = text }
        noticeTask?.cancel()
        noticeTask = Task {
            try? await Task.sleep(for: .seconds(2.6))
            if !Task.isCancelled { withAnimation(.snappy) { notice = nil } }
        }
    }

    // MARK: Items

    @discardableResult
    func create(_ kind: Kind, title: String = "", body: String = "") -> Item {
        var item = Item(kind: kind, title: title, body: body)
        switch scope {
        case .space(let id): item.space = id
        case .project(let id): item.project = id; item.space = project(id)?.space
        default: break
        }
        if kind == .question { item.status = .open }
        if kind == .mindmap { item.nodes = [MindNode(text: title.isEmpty ? "Central idea" : title)] }
        items[item.id] = item
        markDirty(item.id)
        selection = [item.id]
        if kind == .mindmap { focused = item.id }
        return item
    }

    /// Quick capture into the inbox without changing what the window shows.
    func capture(_ text: String, kind: Kind) {
        var item = Item(kind: kind, body: text)
        if kind == .question {
            item.status = .open
            item.title = String(text.prefix { $0 != "\n" }.prefix(120))
        }
        items[item.id] = item
        markDirty(item.id)
        notify("Captured to Inbox")
        if Pref.on(Pref.autoEnrich) && AI.isAvailable { Task { await enrich(item.id, quiet: true) } }
    }

    func binding(_ id: UUID) -> Binding<Item> {
        Binding(get: { self.items[id] ?? Item(id: id) }, set: { self.update($0) })
    }

    func modify(_ ids: Set<UUID>, _ change: (inout Item) -> Void) {
        for id in ids {
            guard var item = items[id] else { continue }
            change(&item)
            update(item)
        }
    }

    func trash(_ ids: Set<UUID>) {
        withAnimation(.snappy) {
            modify(ids) { $0.trashed = true }
            selection.subtract(ids)
            if let focused, ids.contains(focused) { self.focused = nil }
        }
    }

    func deleteForever(_ ids: Set<UUID>) {
        withAnimation(.snappy) {
            for id in ids {
                items[id] = nil
                markDirty(id)
            }
            selection.subtract(ids)
        }
    }

    func emptyTrash() { deleteForever(Set(items.values.filter(\.trashed).map(\.id))) }

    func move(_ ids: Set<UUID>, to space: UUID?, project: UUID? = nil) {
        withAnimation(.snappy) { modify(ids) { $0.space = space; $0.project = project } }
    }

    func link(_ a: UUID, _ b: UUID) {
        guard a != b else { return }
        modify([a]) { if !$0.links.contains(b) { $0.links.append(b) } }
    }

    func unlink(_ a: UUID, _ b: UUID) {
        modify([a]) { $0.links.removeAll { $0 == b } }
        modify([b]) { $0.links.removeAll { $0 == a } }
    }

    // MARK: Queries

    func includes(_ scope: Scope, _ item: Item) -> Bool {
        if scope == .trash { return item.trashed }
        if item.trashed { return false }
        switch scope {
        case .overview, .all, .trash: return true
        case .inbox: return item.space == nil
        case .questions: return item.kind == .question && item.status != .done
        case .pinned: return item.pinned
        case .space(let id): return item.space == id
        case .project(let id): return item.project == id
        }
    }

    /// Items in the current scope, filtered and sorted (pinned first, then most recent).
    var visible: [Item] {
        items.values
            .filter { includes(scope, $0) && (kindFilter == nil || $0.kind == kindFilter) && (query.isEmpty || $0.matches(query)) }
            .sorted { ($0.pinned ? 1 : 0, $0.updated) > ($1.pinned ? 1 : 0, $1.updated) }
    }

    func count(_ scope: Scope) -> Int { items.values.count { includes(scope, $0) } }

    func space(_ id: UUID?) -> Space? { id.flatMap { id in meta.spaces.first { $0.id == id } } }
    func project(_ id: UUID?) -> Project? { id.flatMap { id in meta.projects.first { $0.id == id } } }
    func projects(in space: UUID) -> [Project] { meta.projects.filter { $0.space == space && !$0.archived } }

    func backlinks(_ id: UUID) -> [Item] { items.values.filter { !$0.trashed && $0.links.contains(id) } }

    var selected: Item? { selection.count == 1 ? selection.first.flatMap { items[$0] } : nil }

    // MARK: Spaces & projects

    func addSpace(_ name: String) {
        let used = Set(meta.spaces.map(\.tone))
        let tone = (0..<Palette.count).first { !used.contains($0) } ?? meta.spaces.count % Palette.count
        meta.spaces.append(Space(name: name, icon: "circle.fill", tone: tone))
        saveMeta()
    }

    func updateSpace(_ space: Space) {
        guard let i = meta.spaces.firstIndex(where: { $0.id == space.id }) else { return }
        meta.spaces[i] = space
        saveMeta()
    }

    func deleteSpace(_ id: UUID) {
        meta.spaces.removeAll { $0.id == id }
        meta.projects.removeAll { $0.space == id }
        saveMeta()
        move(Set(items.values.filter { $0.space == id }.map(\.id)), to: nil)
        if scope == .space(id) { scope = .inbox }
    }

    @discardableResult
    func addProject(_ name: String, in space: UUID) -> Project {
        let project = Project(name: name, space: space)
        meta.projects.append(project)
        saveMeta()
        return project
    }

    func updateProject(_ project: Project) {
        guard let i = meta.projects.firstIndex(where: { $0.id == project.id }) else { return }
        meta.projects[i] = project
        saveMeta()
    }

    func deleteProject(_ id: UUID) {
        meta.projects.removeAll { $0.id == id }
        saveMeta()
        modify(Set(items.values.filter { $0.project == id }.map(\.id))) { $0.project = nil }
        if scope == .project(id) { scope = .inbox }
    }

    // MARK: Import

    func importFiles(_ urls: [URL]) async {
        guard let vault else { return }
        notify("Importing \(urls.count) file\(urls.count == 1 ? "" : "s")…")
        var added: [Item] = []
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            if url.hasDirectoryPath { continue }
            if url.pathExtension.lowercased() == "json", let data = try? Data(contentsOf: url) {
                let chats = Importer.chats(from: data)
                if !chats.isEmpty { added += chats; continue }
            }
            if let item = try? await Importer.file(url, into: vault) { added.append(item) }
        }
        guard self.vault === vault else { return }
        let target = scopeTarget
        withAnimation(.snappy) {
            for var item in added {
                item.space = target.space
                item.project = target.project
                items[item.id] = item
                markDirty(item.id)
            }
            if let first = added.first { selection = [first.id] }
        }
        notify("Imported \(added.count) item\(added.count == 1 ? "" : "s")")
        if Pref.on(Pref.autoEnrich) && AI.isAvailable {
            for item in added.prefix(25) { await enrich(item.id, quiet: true) }
        }
    }

    private var scopeTarget: (space: UUID?, project: UUID?) {
        switch scope {
        case .space(let id): (id, nil)
        case .project(let id): (project(id)?.space, id)
        default: (nil, nil)
        }
    }

    func thumbnail(_ id: UUID) async -> CGImage? {
        if let cached = thumbs.object(forKey: id as NSUUID) { return cached }
        guard let vault else { return nil }
        let data = await Task.detached(priority: .utility) { vault.thumb(id) }.value
        guard let data, let image = Importer.image(data) else { return nil }
        thumbs.setObject(image, forKey: id as NSUUID)
        return image
    }

    /// Decrypts a file to a private temporary location for Quick Look, sharing or opening.
    func decrypted(_ id: UUID) async -> URL? {
        guard let vault, let file = items[id]?.file else { return nil }
        return try? await Task.detached { try vault.exportBlob(id, name: file.name) }.value
    }

    // MARK: Intelligence

    func isWorking(_ id: UUID) -> Bool { working.contains(id) }

    /// Title, summary and tags from Apple Intelligence; keyword tags when it isn't available.
    func enrich(_ id: UUID, quiet: Bool = false) async {
        guard let item = items[id], !working.contains(id) else { return }
        working.insert(id)
        defer { working.remove(id) }
        var title = "", summary = "", tags: [String] = []
        if AI.isAvailable, let triage = try? await AI.triage(item.text) {
            (title, summary, tags) = (triage.title, triage.summary, triage.tags)
        } else {
            tags = AI.keywords(item.text)
            if !quiet && !AI.isAvailable { notify("Apple Intelligence is off. Added keyword tags instead.") }
        }
        modify([id]) { i in
            let fileStem = i.file.map { ($0.name as NSString).deletingPathExtension }
            if (i.title.isEmpty || i.title == fileStem) && !title.isEmpty { i.title = title }
            if !summary.isEmpty { i.summary = summary }
            let normalized = tags.map { $0.lowercased().trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            i.tags = Array((i.tags + normalized.filter { !i.tags.contains($0) }).prefix(6))
        }
    }

    func suggestAnswer(_ id: UUID) async {
        guard AI.isAvailable, let question = items[id], !working.contains(id) else {
            notify("Needs Apple Intelligence (System Settings › Apple Intelligence & Siri).")
            return
        }
        working.insert(id)
        defer { working.remove(id) }
        let context = brain.similar(to: id, limit: 4).compactMap { items[$0.id] }
            .map { "- \($0.display): \($0.text.prefix(500))" }.joined(separator: "\n")
        guard let answer = try? await AI.answer(question.text, context: context) else { return notify("No answer this time.") }
        modify([id]) { $0.body += ($0.body.isEmpty ? "" : "\n\n") + "**Suggested answer (on-device):** " + answer }
    }

    func suggestion(for item: Item) -> (space: Space, project: Project?)? {
        guard item.space == nil, let s = brain.suggestion(for: item, in: items), let space = space(s.space) else { return nil }
        return (space, project(s.project))
    }

    /// A small realistic workspace to explore the views with.
    func addSampleContent() {
        let work = meta.spaces.first { $0.name == "Work" }?.id ?? { addSpace("Work"); return meta.spaces.last!.id }()
        let personal = meta.spaces.first { $0.name == "Personal" }?.id ?? { addSpace("Personal"); return meta.spaces.last!.id }()
        let launch = addProject("Product Launch", in: work), research = addProject("User Research", in: work)
        let day: TimeInterval = 86_400
        var added: [Item] = []
        func add(_ kind: Kind, _ title: String, _ body: String, space: UUID? = nil, project: UUID? = nil,
                 status: Status = .none, tags: [String] = [], age: Double) -> UUID {
            let date = Date.now.addingTimeInterval(-age * day)
            added.append(Item(kind: kind, title: title, body: body, tags: tags, space: space, project: project,
                              status: status, created: date, updated: date))
            return added.last!.id
        }
        let plan = add(.note, "Launch plan v2", "Beta in **May**, public launch in June.\nOwners: product, marketing, support.\nRisks: onboarding drop-off, pricing clarity.",
                       space: work, project: launch.id, status: .active, tags: ["launch", "roadmap"], age: 1)
        let pricing = add(.question, "Which pricing tier converts best?", "Compare monthly vs. annual in the beta cohort.",
                          space: work, project: launch.id, status: .open, tags: ["pricing"], age: 2)
        _ = add(.question, "Do we need SOC 2 before the enterprise pilot?", "Ask legal and the two pilot customers.",
                space: work, project: launch.id, status: .active, tags: ["security", "enterprise"], age: 4)
        let interview = add(.note, "Interview: Anna, CFO at a 40-person agency", "Pain: invoices scattered across tools. Would pay for one place with search. Wants exports for the accountant.",
                            space: work, project: research.id, status: .done, tags: ["interview", "finance"], age: 6)
        _ = add(.note, "Competitor teardown: note apps", "Strong at writing, weak at files and AI chats. Nobody shows how knowledge connects.",
                space: work, project: research.id, tags: ["competition"], age: 9)
        _ = add(.chat, "Market sizing for the EU", Importer.transcript([
            .init(role: .user, text: "Estimate the number of agencies with 10 to 50 employees in Germany, France and the Netherlands."),
            .init(role: .assistant, text: "A rough range is **18,000 to 26,000**. The biggest uncertainty is how agencies are classified in each registry."),
            .init(role: .user, text: "Which assumption moves the number most?"),
            .init(role: .assistant, text: "The share of freelancers counted as agencies. Excluding them lowers the estimate by about a third."),
        ]), space: work, project: research.id, tags: ["market"], age: 3)
        var mindmap = Item(kind: .mindmap, title: "Q4 Strategy", space: work, created: .now.addingTimeInterval(-2 * day), updated: .now.addingTimeInterval(-2 * day))
        let root = MindNode(text: "Q4 Strategy")
        let growth = MindNode(text: "Growth", parent: root.id), product = MindNode(text: "Product", parent: root.id)
        let team = MindNode(text: "Team", parent: root.id), money = MindNode(text: "Finance", parent: root.id)
        mindmap.nodes = [root, growth, product, team, money,
                         MindNode(text: "Referral program", parent: growth.id), MindNode(text: "EU expansion", parent: growth.id),
                         MindNode(text: "Offline mode", parent: product.id), MindNode(text: "Shared spaces", parent: product.id),
                         MindNode(text: "Hire 2 engineers", parent: team.id), MindNode(text: "Runway 18 months", parent: money.id)]
        added.append(mindmap)
        _ = add(.note, "Marathon training plan", "16 weeks, 4 runs per week. Long run on Sundays, +1.5 km each week.",
                space: personal, tags: ["running"], age: 5)
        _ = add(.question, "Which shoes for long distance?", "Cushioning vs. weight. Try two pairs in store.",
                space: personal, status: .open, tags: ["running"], age: 7)
        _ = add(.note, "Books 2026", "Thinking in Systems · The Mom Test · Four Thousand Weeks", space: personal, tags: ["reading"], age: 12)
        _ = add(.note, "Idea: weekly digest email", "Send a Monday summary of open questions and what changed in each project.", age: 0.2)
        _ = add(.note, "Pricing page copy draft", "Headline: One calm place for everything you create. Annual plan saves two months.", age: 0.5)
        if let i = added.firstIndex(where: { $0.id == plan }) { added[i].links = [pricing, interview] }
        withAnimation(.snappy) {
            for item in added {
                items[item.id] = item
                markDirty(item.id)
            }
        }
        notify("Added \(added.count) sample items")
    }

    /// Files every inbox item whose neighbours agree on a space.
    func autoSort() {
        var moved = 0
        withAnimation(.snappy) {
            for item in items.values where !item.trashed && item.space == nil {
                guard let s = brain.suggestion(for: item, in: items) else { continue }
                modify([item.id]) { $0.space = s.space; $0.project = s.project }
                moved += 1
            }
        }
        notify(moved == 0 ? "Nothing to sort with confidence yet." : "Sorted \(moved) item\(moved == 1 ? "" : "s").")
    }
}
