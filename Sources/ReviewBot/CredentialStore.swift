import Foundation
import Security

/// Storage for reviewer API keys. Keys are never written to `config.json`, which is a plain
/// JSON file in Application Support; they live in the login Keychain instead.
///
/// A key is only ever meaningful for a reviewer whose `supportsAPIKeyAuth` is true — either a
/// CLI that reads one from its environment, or a reviewer with no CLI at all, for which a key is
/// the only way in. opencode is neither: it authenticates through its own configuration
/// directory, so Review Bot has nowhere to put a key for it even if one were stored.
protocol CredentialStoring: Sendable {
    func apiKey(for reviewer: ReviewerName) -> String?
    func setAPIKey(_ key: String, for reviewer: ReviewerName) throws
    func removeAPIKey(for reviewer: ReviewerName) throws
}

enum CredentialStoreError: LocalizedError {
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case let .keychain(status):
            let detail = SecCopyErrorMessageString(status, nil) as String?
            return "Keychain error \(status)\(detail.map { ": \($0)" } ?? "")."
        }
    }
}

struct KeychainCredentialStore: CredentialStoring {
    /// Deliberately uses the file-based login Keychain rather than the data-protection
    /// Keychain: the latter needs an `application-identifier` entitlement, which an
    /// ad-hoc-signed build (the default for `make app`) does not have.
    private let service: String
    /// Consulted before the Keychain, so a key can be supplied out-of-band. Injected rather
    /// than read at the point of use so tests can exercise the override without a real key.
    private let environment: [String: String]

    init(
        service: String = "Review Bot reviewer API keys",
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.service = service
        self.environment = environment
    }

    func apiKey(for reviewer: ReviewerName) -> String? {
        // `apiKeyOverrideEnvironmentVariable` is total, so it names a variable even for a
        // reviewer that cannot be handed a key — opencode's `OPENCODE_API_KEY` exists only to
        // keep that switch exhaustive. Refusing here means an exported value cannot be resolved
        // into a credential the engine would then have no way to deliver, and cannot make
        // `AppModel` report a key as being "in effect" for a reviewer that ignores it. The
        // predicate is derived from the reviewer's own surface, so a reviewer that later gains a
        // key variable starts being answered again without a change here.
        guard reviewer.supportsAPIKeyAuth else { return nil }

        // An explicit environment variable wins, so a development run or a probe can supply a
        // key without touching — or being prompted for — the developer's Keychain.
        if let fromEnvironment = environmentKey(for: reviewer) { return fromEnvironment }

        var query = baseQuery(for: reviewer)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else {
            return nil
        }
        let value = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    func setAPIKey(_ key: String, for reviewer: ReviewerName) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            try removeAPIKey(for: reviewer)
            return
        }

        let query = baseQuery(for: reviewer)
        let attributes = [kSecValueData as String: Data(trimmed.utf8)] as CFDictionary
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw CredentialStoreError.keychain(updateStatus)
        }

        var insert = query
        insert[kSecValueData as String] = Data(trimmed.utf8)
        let addStatus = SecItemAdd(insert as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw CredentialStoreError.keychain(addStatus)
        }
    }

    /// Deliberately unguarded by `supportsAPIKeyAuth`, unlike `apiKey(for:)`: an item saved by
    /// an earlier build, or before a reviewer's auth surface changed, must stay removable.
    func removeAPIKey(for reviewer: ReviewerName) throws {
        let status = SecItemDelete(baseQuery(for: reviewer) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CredentialStoreError.keychain(status)
        }
    }

    private func baseQuery(for reviewer: ReviewerName) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: reviewer.rawValue,
        ]
    }

    private func environmentKey(for reviewer: ReviewerName) -> String? {
        let value = environment[reviewer.apiKeyOverrideEnvironmentVariable]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    // Two things that look like they would stop macOS re-prompting for this item after every
    // rebuild, both measured not to work. Don't spend the afternoon again.
    //
    // 1. `kSecAttrAccess` with a nil application list ("any application, never ask"). Every item
    //    also carries a *partition list*, checked independently of the trusted-application list.
    //    It is stamped `cdhash:<saving binary>` when the signature has no team identity, so a
    //    rebuilt binary fails it whatever the ACL says.
    // 2. A self-signed code-signing identity. It fixes the ACL half — the requirement becomes
    //    `identifier "…" and certificate leaf = H"…"`, which a rebuild does satisfy — but the
    //    partition list is still `cdhash:` because a self-signed cert carries no team id, so a
    //    rebuild is still refused.
    //
    // The partition list only becomes rebuild-stable when it can record `teamid:`, which needs a
    // real (Apple-issued) signing identity: `CODE_SIGN_IDENTITY="Developer ID Application: …"`.
    // Failing that, `ReviewerName.apiKeyOverrideEnvironmentVariable` avoids the Keychain
    // altogether for development runs.
}

/// Non-persistent store used by tests, so the suite never touches the developer's Keychain.
///
/// It carries no `supportsAPIKeyAuth` guard on purpose. That guard exists in the Keychain store
/// because that store reads ambient state — the process environment — and could therefore
/// resolve a key for a reviewer nobody meant to credential. This one returns only what a test
/// explicitly handed it, so guarding would hide a mis-wiring rather than prevent one.
final class InMemoryCredentialStore: CredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var keys: [ReviewerName: String]

    init(keys: [ReviewerName: String] = [:]) {
        self.keys = keys
    }

    func apiKey(for reviewer: ReviewerName) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return keys[reviewer]
    }

    func setAPIKey(_ key: String, for reviewer: ReviewerName) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        lock.lock()
        defer { lock.unlock() }
        if trimmed.isEmpty {
            keys.removeValue(forKey: reviewer)
        } else {
            keys[reviewer] = trimmed
        }
    }

    func removeAPIKey(for reviewer: ReviewerName) throws {
        lock.lock()
        defer { lock.unlock() }
        keys.removeValue(forKey: reviewer)
    }
}

/// The reviewer API keys one run needs, read once, up front, off whatever actor asked for them.
///
/// `KeychainCredentialStore.apiKey(for:)` is a synchronous `SecItemCopyMatching`. On a build
/// whose Keychain items are not partition-stable — the ad-hoc-signed default, as the comment
/// above explains — that call blocks its thread until the user answers a modal "allow access"
/// dialog. Called from inside an actor-isolated method it blocks the actor's executor, so
/// `ReviewEngine`'s parallel reviewers and the poll loop behind them would all queue up behind
/// one dialog; called on the main actor it freezes the UI. Resolving through this type keeps
/// the blocking read on a detached task, and asks for each key once per run rather than once per
/// place that happens to need it.
struct ResolvedCredentials: Sendable {
    private let keys: [ReviewerName: String]

    init(keys: [ReviewerName: String] = [:]) {
        self.keys = keys
    }

    /// The key to hand this reviewer, or `nil` if none resolved — because none is saved, because
    /// the Keychain read was refused, or because the reviewer was not one this run asked about.
    func apiKey(for reviewer: ReviewerName) -> String? { keys[reviewer] }

    /// The reviewers a key actually resolved for.
    var reviewersWithKey: Set<ReviewerName> { Set(keys.keys) }

    /// Reads `reviewers`' keys off the calling executor. `await`ing this suspends the caller —
    /// releasing an actor or the main thread — for as long as the store blocks.
    static func resolve(
        _ reviewers: [ReviewerName],
        from store: any CredentialStoring
    ) async -> ResolvedCredentials {
        guard !reviewers.isEmpty else { return ResolvedCredentials() }
        return await Task.detached(priority: .userInitiated) {
            var keys: [ReviewerName: String] = [:]
            for reviewer in reviewers {
                keys[reviewer] = store.apiKey(for: reviewer)
            }
            return ResolvedCredentials(keys: keys)
        }.value
    }
}
