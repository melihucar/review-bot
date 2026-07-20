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
    var worktreesDirectory: URL { root.appendingPathComponent("worktrees", isDirectory: true) }
    var reviewsDirectory: URL { root.appendingPathComponent("reviews", isDirectory: true) }
    var logsDirectory: URL { root.appendingPathComponent("logs", isDirectory: true) }

    func prepare() throws {
        for directory in [root, worktreesDirectory, reviewsDirectory, logsDirectory] {
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
           let decoded = try? decoder.decode([HistoryEntry].self, from: data) {
            entries = decoded
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

    func insert(_ key: String) {
        keys.insert(key)
        try? paths.prepare()
        let values = keys.sorted()
        guard let data = try? JSONEncoder().encode(values) else { return }
        try? data.write(to: paths.reviewedFile, options: .atomic)
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
