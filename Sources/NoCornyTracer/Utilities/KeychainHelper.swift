import Foundation
import Security

/// Real macOS Keychain backed token storage.
///
/// Items are stored as `kSecClassGenericPassword` under service
/// `com.nocorny.tracer`, accessible after first user unlock. Each token is
/// keyed by an arbitrary `account` name (e.g. `TracerAPIToken`).
///
/// Auto-migrates any legacy XOR-obfuscated file store from earlier builds:
/// the first `load(key:)` after upgrade copies all surviving values into the
/// real Keychain and deletes `~/Library/Application Support/NoCornyTracer/{secrets,key}.bin`.
/// Idempotent — second call after migration is a no-op.
enum KeychainHelper {

    private static let service = "com.nocorny.tracer"

    enum KeychainError: Error {
        case unhandledStatus(OSStatus)
        case dataConversionFailed
    }

    // MARK: - Public API

    static func save(key: String, value: String) throws {
        guard let data = value.data(using: .utf8) else {
            throw KeychainError.dataConversionFailed
        }

        let identityQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]

        // Atomic: update an existing item in place first. The old delete-then-add
        // had a window where the item was deleted and the add then failed (locked
        // keychain, ACL denial) — losing the only copy of the token.
        let updateStatus = SecItemUpdate(
            identityQuery as CFDictionary,
            [
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            ] as CFDictionary
        )
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            let message = SecCopyErrorMessageString(updateStatus, nil) as String? ?? "n/a"
            LogManager.shared.log("🔐 Keychain save(\(key)): UPDATE FAILED status=\(updateStatus) — \(message)")
            throw KeychainError.unhandledStatus(updateStatus)
        }

        // No existing item — add a fresh one.
        var addAttributes = identityQuery
        addAttributes[kSecValueData as String] = data
        addAttributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let addStatus = SecItemAdd(addAttributes as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            let message = SecCopyErrorMessageString(addStatus, nil) as String? ?? "n/a"
            LogManager.shared.log("🔐 Keychain save(\(key)): ADD FAILED status=\(addStatus) — \(message)")
            throw KeychainError.unhandledStatus(addStatus)
        }
    }

    static func load(key: String) -> String? {
        // Lazy one-shot migration from the previous file-based store.
        migrateLegacyFileStoreIfNeeded()

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        // errSecItemNotFound is the normal "no value yet" case — don't log it.
        // Anything else (auth failed, interaction required, etc.) is worth surfacing.
        if status != errSecSuccess && status != errSecItemNotFound {
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "n/a"
            LogManager.shared.log("🔐 Keychain load(\(key)): status=\(status) — \(message)")
        }
        guard status == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return nil
        }
        return value
    }

    static func delete(key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - Migration

    private static var migrationDone = false
    private static let migrationLock = NSLock()

    /// Read tokens left over in `~/Library/Application Support/NoCornyTracer/secrets.bin`
    /// (XOR'd with `key.bin`), copy each value into the real Keychain, then delete
    /// both files. Runs at most once per process.
    private static func migrateLegacyFileStoreIfNeeded() {
        migrationLock.lock(); defer { migrationLock.unlock() }
        guard !migrationDone else { return }
        migrationDone = true

        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NoCornyTracer", isDirectory: true)
        let secretsFile = base.appendingPathComponent("secrets.bin")
        let keyFile = base.appendingPathComponent("key.bin")

        guard let secretsData = try? Data(contentsOf: secretsFile),
              let keyData = try? Data(contentsOf: keyFile),
              keyData.count == 32, !secretsData.isEmpty else {
            return
        }

        var decoded = Data(count: secretsData.count)
        for i in 0..<secretsData.count {
            decoded[i] = secretsData[i] ^ keyData[i % keyData.count]
        }
        guard let dict = try? JSONDecoder().decode([String: String].self, from: decoded) else {
            return
        }

        var allSaved = true
        for (k, v) in dict {
            do {
                try save(key: k, value: v)
            } catch {
                allSaved = false
            }
        }

        // Only delete the legacy file once EVERY value is safely in the Keychain.
        // Deleting unconditionally used to destroy the only copy of the token when a
        // save failed (e.g. keychain locked at early launch). migrationDone is
        // per-process, so a failed run retries on the next launch.
        guard allSaved else {
            LogManager.shared.log("🔐 Keychain: legacy migration incomplete — keeping legacy file for next-launch retry", type: .error)
            return
        }
        try? FileManager.default.removeItem(at: secretsFile)
        try? FileManager.default.removeItem(at: keyFile)
    }
}
