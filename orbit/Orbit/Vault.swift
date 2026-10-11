import Foundation
import CryptoKit
import CommonCrypto
import LocalAuthentication

enum VaultError: LocalizedError {
    case wrongPassword, notAVault

    var errorDescription: String? {
        switch self {
        case .wrongPassword: "Wrong passphrase."
        case .notAVault: "This folder is not an Orbit vault."
        }
    }
}

/// Plaintext header. Holds no secret: the master key is sealed with a key derived from the passphrase.
struct VaultHeader: Codable {
    var v = 1
    var id = UUID()
    var rounds: Int
    var salt: Data
    var key: Data
}

/// An encrypted folder that syncs through any file sync (iCloud Drive, Dropbox, …).
///
///     vault.json        header (KDF parameters + wrapped master key)
///     meta.orbit        spaces and projects
///     items/<id>.orbit  one AES-GCM sealed JSON file per item
///     blobs/<id>        sealed file contents
final class Vault: Sendable {
    let root: URL
    let id: UUID
    private let key: SymmetricKey

    private init(root: URL, id: UUID, key: SymmetricKey) {
        self.root = root
        self.id = id
        self.key = key
    }

    var itemsDir: URL { root.appending(path: "items", directoryHint: .isDirectory) }
    var blobsDir: URL { root.appending(path: "blobs", directoryHint: .isDirectory) }
    private var metaURL: URL { root.appending(path: "meta.orbit") }
    private static func headerURL(_ root: URL) -> URL { root.appending(path: "vault.json") }
    var keyData: Data { key.withUnsafeBytes { Data($0) } }

    static func exists(at root: URL) -> Bool {
        FileManager.default.fileExists(atPath: headerURL(root).path)
    }

    // MARK: Lifecycle

    static func create(at root: URL, password: String, rounds: Int = 600_000) throws -> Vault {
        let master = SymmetricKey(size: .bits256)
        let salt = Data(SymmetricKey(size: .bits128).withUnsafeBytes { Array($0) })
        let wrapped = try seal(master.withUnsafeBytes { Data($0) }, derive(password, salt: salt, rounds: rounds))
        let header = VaultHeader(rounds: rounds, salt: salt, key: wrapped)
        for dir in ["items", "blobs"] {
            try FileManager.default.createDirectory(at: root.appending(path: dir), withIntermediateDirectories: true)
        }
        try coordinatedWrite(JSONEncoder().encode(header), to: headerURL(root))
        let vault = Vault(root: root, id: header.id, key: master)
        try vault.save(Meta())
        return vault
    }

    static func open(at root: URL, password: String) throws -> Vault {
        let header = try readHeader(root)
        guard let raw = try? unseal(header.key, derive(password, salt: header.salt, rounds: header.rounds)) else {
            throw VaultError.wrongPassword
        }
        return Vault(root: root, id: header.id, key: SymmetricKey(data: raw))
    }

    /// Opens with a key restored from the keychain; verifies it against the vault's metadata.
    static func open(at root: URL, key: Data) throws -> Vault {
        let vault = Vault(root: root, id: try readHeader(root).id, key: SymmetricKey(data: key))
        _ = try vault.loadMeta()
        return vault
    }

    static func readHeader(_ root: URL) throws -> VaultHeader {
        guard exists(at: root) else { throw VaultError.notAVault }
        return try JSONDecoder().decode(VaultHeader.self, from: coordinatedRead(headerURL(root)))
    }

    func changePassword(_ password: String) throws {
        var header = try Vault.readHeader(root)
        header.salt = Data(SymmetricKey(size: .bits128).withUnsafeBytes { Array($0) })
        header.key = try Vault.seal(keyData, Vault.derive(password, salt: header.salt, rounds: header.rounds))
        try Vault.coordinatedWrite(JSONEncoder().encode(header), to: Vault.headerURL(root))
    }

    // MARK: Records

    func loadMeta() throws -> Meta { try read(Meta.self, at: metaURL) }
    func save(_ meta: Meta) throws { try write(meta, to: metaURL) }

    func url(for item: UUID) -> URL { itemsDir.appending(path: item.uuidString + ".orbit") }

    /// Writes the item and returns the file's new modification date.
    @discardableResult
    func save(_ item: Item) throws -> Date {
        let url = url(for: item.id)
        try write(item, to: url)
        return Self.modified(url) ?? .now
    }

    func delete(_ id: UUID) {
        try? FileManager.default.removeItem(at: url(for: id))
        try? FileManager.default.removeItem(at: blobsDir.appending(path: id.uuidString))
    }

    /// Item ids with modification dates. Asks iCloud to download placeholders it finds.
    func listing() -> [UUID: Date] {
        let fm = FileManager.default
        let urls = (try? fm.contentsOfDirectory(at: itemsDir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        var out: [UUID: Date] = [:]
        for url in urls {
            let name = url.lastPathComponent
            if name.hasSuffix(".icloud") {
                try? fm.startDownloadingUbiquitousItem(at: url)
            } else if url.pathExtension == "orbit", let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) {
                out[id] = Self.modified(url) ?? .distantPast
            }
        }
        return out
    }

    func load(_ ids: [UUID]) -> [Item] {
        var out = [Item?](repeating: nil, count: ids.count)
        out.withUnsafeMutableBufferPointer { buf in
            DispatchQueue.concurrentPerform(iterations: ids.count) { i in
                buf[i] = try? read(Item.self, at: url(for: ids[i]))
            }
        }
        return out.compactMap { $0 }
    }

    // MARK: Blobs

    func storeBlob(from source: URL, id: UUID) throws {
        let data = try Data(contentsOf: source, options: .mappedIfSafe)
        try Self.coordinatedWrite(Self.seal(data, key), to: blobsDir.appending(path: id.uuidString))
    }

    /// Decrypts a blob into a private temporary folder that is wiped on lock.
    func exportBlob(_ id: UUID, name: String) throws -> URL {
        let dir = Self.tempDir.appending(path: id.uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let out = dir.appending(path: name)
        if !FileManager.default.fileExists(atPath: out.path) {
            let data = try Self.unseal(Self.coordinatedRead(blobsDir.appending(path: id.uuidString)), key)
            try data.write(to: out, options: .atomic)
        }
        return out
    }

    static let tempDir = FileManager.default.temporaryDirectory.appending(path: "orbit-open", directoryHint: .isDirectory)
    static func wipeTemp() { try? FileManager.default.removeItem(at: tempDir) }

    // MARK: Crypto

    private func read<T: Decodable>(_: T.Type, at url: URL) throws -> T {
        try Self.decoder.decode(T.self, from: Self.unseal(Self.coordinatedRead(url), key))
    }

    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        try Self.coordinatedWrite(Self.seal(Self.encoder.encode(value), key), to: url)
    }

    static func derive(_ password: String, salt: Data, rounds: Int) -> SymmetricKey {
        var out = [UInt8](repeating: 0, count: 32)
        salt.withUnsafeBytes { s in
            _ = CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), password, password.utf8.count,
                                     s.bindMemory(to: UInt8.self).baseAddress, salt.count,
                                     CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(rounds), &out, out.count)
        }
        return SymmetricKey(data: out)
    }

    static func seal(_ data: Data, _ key: SymmetricKey) throws -> Data {
        try AES.GCM.seal(data, using: key).combined!
    }

    static func unseal(_ data: Data, _ key: SymmetricKey) throws -> Data {
        try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: key)
    }

    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()

    private static func modified(_ url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    // File coordination keeps reads and writes safe while iCloud Drive or another sync agent works on the folder.
    private static func coordinatedRead(_ url: URL) throws -> Data {
        var result: Result<Data, Error> = .failure(CocoaError(.fileReadUnknown))
        var error: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &error) { url in result = Result { try Data(contentsOf: url) } }
        if let error { throw error }
        return try result.get()
    }

    private static func coordinatedWrite(_ data: Data, to url: URL) throws {
        var result: Result<Void, Error> = .success(())
        var error: NSError?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &error) { url in result = Result { try data.write(to: url, options: .atomic) } }
        if let error { throw error }
        try result.get()
    }
}

/// Remembers the vault key on this device so it can be unlocked with Touch ID / Face ID.
enum Keychain {
    private static let service = "Orbit Vault Key"

    static func set(_ data: Data, for account: String) {
        delete(account)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecValueData as String: data,
                                    kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        SecItemAdd(query as CFDictionary, nil)
    }

    static func get(_ account: String) -> Data? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecReturnData as String: true]
        var out: CFTypeRef?
        return SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess ? out as? Data : nil
    }

    static func delete(_ account: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
    }

    static var biometryAvailable: Bool { LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) }

    static func authenticate() async -> Bool {
        (try? await LAContext().evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "unlock your vault")) ?? false
    }
}

/// Persists the user-chosen vault folder across launches (security-scoped on macOS).
enum VaultLocation {
    private static let defaultsKey = "vaultBookmark"

    #if os(macOS)
    private static let create: URL.BookmarkCreationOptions = .withSecurityScope
    private static let resolve: URL.BookmarkResolutionOptions = .withSecurityScope
    #else
    private static let create: URL.BookmarkCreationOptions = []
    private static let resolve: URL.BookmarkResolutionOptions = []
    #endif

    static var local: URL {
        URL.applicationSupportDirectory.appending(path: "Orbit Vault", directoryHint: .isDirectory)
    }

    static func remember(_ url: URL) {
        let isLocal = url.standardizedFileURL == local.standardizedFileURL
        UserDefaults.standard.set(isLocal ? Data("local".utf8) : try? url.bookmarkData(options: create), forKey: defaultsKey)
    }

    static func forget() { UserDefaults.standard.removeObject(forKey: defaultsKey) }

    static func restore() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else { return nil }
        if data == Data("local".utf8) { return local }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: resolve, bookmarkDataIsStale: &stale) else { return nil }
        _ = url.startAccessingSecurityScopedResource()
        if stale { remember(url) }
        return url
    }
}
