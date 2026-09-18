import Combine
import Foundation

struct StoragePaths {
    let root: URL

    init(root: URL? = nil) {
        if let root {
            self.root = root
        } else {
            let applicationSupport = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first!
            self.root = applicationSupport.appendingPathComponent("ReviewBot", isDirectory: true)
        }
    }

    var configFile: URL { root.appendingPathComponent("config.json") }
    var historyFile: URL { root.appendingPathComponent("history.json") }
    var reviewedFile: URL { root.appendingPathComponent("reviewed.json") }
    var lastReviewedFile: URL { root.appendingPathComponent("last-reviewed.json") }
    var attemptsFile: URL { root.appendingPathComponent("attempts.json") }
    var worktreesDirectory: URL { root.appendingPathComponent("worktrees", isDirectory: true) }
    var reviewsDirectory: URL { root.appendingPathComponent("reviews", isDirectory: true) }
    var logsDirectory: URL { root.appendingPathComponent("logs", isDirectory: true) }
    /// Configuration Review Bot injects into the opencode reviewer (read-only
    /// sandbox agent). Lives outside the worktree so a pull request can't
    /// influence its contents.
    var opencodeConfigDirectory: URL {
        root.appendingPathComponent("opencode", isDirectory: true)
    }
    var opencodeAgentFile: URL {
        opencodeConfigDirectory.appendingPathComponent("agents/review-bot.md")
    }

    func prepare() throws {
        for directory in [root, worktreesDirectory, reviewsDirectory, logsDirectory, opencodeConfigDirectory] {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
    }
}

@MainActor
final class SettingsStore: ObservableObject {
    @Published var configuration: ReviewBotConfiguration {
        didSet { save() }
    }

    private let paths: StoragePaths
    private let encoder = JSONEncoder()

    init(paths: StoragePaths) {
        self.paths = paths
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        configuration = Self.load(from: paths.configFile) ?? .default
    }

    func add(_ repository: InspectedRepository) {
        guard !configuration.repositories.contains(where: { $0.path == repository.path }) else {
            return
        }

        configuration.repositories.append(
            RepositoryConfiguration(
                name: repository.name,
                path: repository.path,
                githubSlug: repository.githubSlug
            )
        )
    }

    func removeRepositories(at offsets: IndexSet) {
        configuration.repositories.remove(atOffsets: offsets)
    }

    func removeRepository(_ id: RepositoryConfiguration.ID) {
        configuration.repositories.removeAll { $0.id == id }
    }

    private func save() {
        try? paths.prepare()
        guard let data = try? encoder.encode(configuration) else { return }
        try? data.write(to: paths.configFile, options: .atomic)
    }

    private static func load(from url: URL) -> ReviewBotConfiguration? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ReviewBotConfiguration.self, from: data)
    }
}

/// History that survives an entry it cannot read.
///
/// `HistoryEventKind` gains cases over time — `superseded` is the most recent — and
/// `HistoryStore` rewrites the whole file on every append. So a build reading a file that a
/// newer build wrote will meet a raw value it has no case for, which is exactly what happens
/// when someone reinstalls an older release. `decode([HistoryEntry].self)` is all-or-nothing
/// there: the one unreadable entry throws, the `try?` at the call site turns that into no
/// history at all, and up to 2,000 entries disappear because one of them named a kind this
/// build predates. Decoding element by element costs that one entry instead.
///
/// This cannot rescue releases that already shipped without it — nothing can — but it makes
/// `superseded`, and every case added after it, safe to read from either direction.
private struct LenientHistory: Decodable {
    let entries: [HistoryEntry]

    /// Decodes anything and keeps none of it. An unkeyed container does not step past an
    /// element whose decode threw, so the slot has to be consumed some other way.
    private struct AnyElement: Decodable {
        init(from decoder: Decoder) throws {}
    }

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var decoded: [HistoryEntry] = []
        while !container.isAtEnd {
            let index = container.currentIndex
            if let entry = try? container.decode(HistoryEntry.self) {
                decoded.append(entry)
            } else {
                _ = try? container.decode(AnyElement.self)
            }
            // If neither decode moved the cursor, stop rather than spin on one element.
            guard container.currentIndex > index else { break }
        }
        entries = decoded
    }
}

@MainActor
final class HistoryStore: ObservableObject {
    @Published private(set) var entries: [HistoryEntry]

    private let paths: StoragePaths
    private let encoder = JSONEncoder()
    private let maximumEntries = 2_000

    init(paths: StoragePaths) {
        self.paths = paths
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: paths.historyFile),
           let decoded = try? decoder.decode(LenientHistory.self, from: data) {
            entries = decoded.entries
        } else {
            entries = []
        }
    }

    func append(_ entry: HistoryEntry) {
        entries.insert(entry, at: 0)
        if entries.count > maximumEntries {
            entries.removeLast(entries.count - maximumEntries)
        }
        save()
    }

    func clear() {
        entries.removeAll()
        save()
    }

    private func save() {
        try? paths.prepare()
        guard let data = try? encoder.encode(entries) else { return }
        try? data.write(to: paths.historyFile, options: .atomic)
    }
}

final class ReviewedStateStore {
    private let paths: StoragePaths
    private var keys: Set<String>

    init(paths: StoragePaths) {
        self.paths = paths
        if let data = try? Data(contentsOf: paths.reviewedFile),
           let values = try? JSONDecoder().decode([String].self, from: data) {
            keys = Set(values)
        } else {
            keys = []
        }
    }

    func contains(_ key: String) -> Bool {
        keys.contains(key)
    }

    /// Number of already-posted reviews whose dedup key starts with `prefix`.
    /// Each posted review (new commit or re-request) adds one key, so this counts
    /// how many review rounds a pull request has already had.
    func count(withPrefix prefix: String) -> Int {
        keys.reduce(into: 0) { total, key in
            if key.hasPrefix(prefix) { total += 1 }
        }
    }

    func insert(_ key: String) {
        keys.insert(key)
        try? paths.prepare()
        let values = keys.sorted()
        guard let data = try? JSONEncoder().encode(values) else { return }
        try? data.write(to: paths.reviewedFile, options: .atomic)
    }
}

/// A run of consecutive failed attempts at one review request (one dedup key).
struct ReviewAttempt: Codable, Equatable {
    var failures: Int
    var lastAttempt: Date
}

/// Counts the failed attempts at each review request. A review that never posts
/// leaves its dedup key unrecorded so the next poll retries it; without this the
/// retry is unbounded, and a permanently broken reviewer re-runs the whole
/// pipeline on every poll forever. `ReviewEngine` uses these counts to back off
/// between attempts and to give up after the configured budget.
final class ReviewAttemptStore {
    /// Attempts are keyed by head commit and request marker, so entries for
    /// superseded commits are dead weight. Dropping them after this long also
    /// means a request abandoned a month ago gets one more chance rather than
    /// being pinned as failed forever. Expired entries are dropped on load and
    /// on every write, so neither the file nor the map grows without bound.
    static let retention: TimeInterval = 30 * 24 * 60 * 60

    private let paths: StoragePaths
    private var attempts: [String: ReviewAttempt]

    init(paths: StoragePaths, now: Date = Date()) {
        self.paths = paths
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let stored = (try? Data(contentsOf: paths.attemptsFile))
            .flatMap { try? decoder.decode([String: ReviewAttempt].self, from: $0) } ?? [:]
        // Pruned in memory; the next write persists the smaller map, so loading
        // the store never touches the disk.
        attempts = Self.live(in: stored, at: now)
    }

    func attempt(for key: String) -> ReviewAttempt? {
        attempts[key]
    }

    /// Records one more failure for `key` and returns the new consecutive count.
    @discardableResult
    func recordFailure(for key: String, at date: Date) -> Int {
        let failures = (attempts[key]?.failures ?? 0) + 1
        attempts[key] = ReviewAttempt(failures: failures, lastAttempt: date)
        save(now: date)
        return failures
    }

    /// Forgets the failures for `key` — called once the review finally posts.
    func clear(_ key: String, at date: Date) {
        guard attempts.removeValue(forKey: key) != nil else { return }
        save(now: date)
    }

    private static func live(
        in attempts: [String: ReviewAttempt],
        at now: Date
    ) -> [String: ReviewAttempt] {
        attempts.filter { now.timeIntervalSince($0.value.lastAttempt) < retention }
    }

    private func save(now: Date) {
        attempts = Self.live(in: attempts, at: now)
        try? paths.prepare()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(attempts) else { return }
        try? data.write(to: paths.attemptsFile, options: .atomic)
    }
}

/// Remembers the head commit each pull request was last reviewed at, so an
/// incremental review can diff only the changes made since then.
final class LastReviewedStore {
    private let paths: StoragePaths
    private var heads: [String: String]

    init(paths: StoragePaths) {
        self.paths = paths
        if let data = try? Data(contentsOf: paths.lastReviewedFile),
           let values = try? JSONDecoder().decode([String: String].self, from: data) {
            heads = values
        } else {
            heads = [:]
        }
    }

    func head(for key: String) -> String? {
        heads[key]
    }

    func record(_ key: String, head: String) {
        heads[key] = head
        try? paths.prepare()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(heads) else { return }
        try? data.write(to: paths.lastReviewedFile, options: .atomic)
    }
}

actor ActivityLogger {
    private let directory: URL
    private let formatter: ISO8601DateFormatter

    init(directory: URL) {
        self.directory = directory
        formatter = ISO8601DateFormatter()
    }

    func append(_ message: String) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let day = String(formatter.string(from: Date()).prefix(10))
        let file = directory.appendingPathComponent("review-bot-\(day).log")
        let line = "[\(formatter.string(from: Date()))] \(message)\n"
        let data = Data(line.utf8)

        if FileManager.default.fileExists(atPath: file.path),
           let handle = try? FileHandle(forWritingTo: file) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: file, options: .atomic)
        }
    }
}
