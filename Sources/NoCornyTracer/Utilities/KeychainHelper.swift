import Foundation

/// Local token storage in `Application Support/NoCornyTracer/secrets.bin`.
/// Values are XOR-obfuscated with a per-install key to avoid trivial plain-text
/// disclosure. This is NOT real cryptography — the threat model is "don't put
/// cleartext tokens in a file that backup tools might index." For real security,
/// the app would need a Developer ID and proper Keychain ACLs, which ad-hoc signing
/// cannot support without forcing the user to approve each keychain item.
enum KeychainHelper {

    enum KeychainError: Error {
        case invalidData
    }

    private static let fileURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NoCornyTracer", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("secrets.bin")
    }()

    private static let keyURL: URL = {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NoCornyTracer", isDirectory: true)
            .appendingPathComponent("key.bin")
    }()

    private static let lock = NSLock()

    // MARK: - Public API

    static func save(key: String, value: String) throws {
        lock.lock(); defer { lock.unlock() }
        var store = loadStore()
        store[key] = value
        try writeStore(store)
    }

    static func load(key: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return loadStore()[key]
    }

    static func delete(key: String) {
        lock.lock(); defer { lock.unlock() }
        var store = loadStore()
        store.removeValue(forKey: key)
        try? writeStore(store)
    }

    // MARK: - Internals

    private static func loadStore() -> [String: String] {
        guard let data = try? Data(contentsOf: fileURL) else { return [:] }
        let key = obfuscationKey()
        let decoded = xor(data: data, key: key)
        guard let dict = try? JSONDecoder().decode([String: String].self, from: decoded) else { return [:] }
        return dict
    }

    private static func writeStore(_ store: [String: String]) throws {
        let data = try JSONEncoder().encode(store)
        let key = obfuscationKey()
        let obfuscated = xor(data: data, key: key)
        try obfuscated.write(to: fileURL, options: [.atomic])
    }

    /// A 32-byte random key generated once per install and stored next to the secrets file.
    /// Same filesystem permissions protect both — this adds obfuscation, not real crypto.
    private static func obfuscationKey() -> Data {
        if let existing = try? Data(contentsOf: keyURL), existing.count == 32 {
            return existing
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let key = Data(bytes)
        try? key.write(to: keyURL, options: [.atomic])
        return key
    }

    private static func xor(data: Data, key: Data) -> Data {
        var out = Data(count: data.count)
        for i in 0..<data.count {
            out[i] = data[i] ^ key[i % key.count]
        }
        return out
    }
}
