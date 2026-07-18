import Foundation

enum ReviewEffort: String, Codable, CaseIterable, Identifiable {
    case low
    case medium
    case high
    case xhigh
    case max

    var id: String { rawValue }
    var label: String {
        switch self {
        case .xhigh: "Extra high"
        case .max: "Max"
        default: rawValue.capitalized
        }
    }

    // Claude and Codex expose different top-tier effort names, so each reviewer
    // only offers the levels its CLI accepts.
    static let claudeCases: [ReviewEffort] = [.low, .medium, .high, .max]
    static let codexCases: [ReviewEffort] = [.low, .medium, .high, .xhigh]
}

struct ReviewerConfiguration: Codable, Equatable {
    var enabled: Bool
    var model: String
    var effort: ReviewEffort
}

struct RepositoryConfiguration: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var path: String
    var githubSlug: String
    var enabled = true
}

struct ReviewBotConfiguration: Codable, Equatable {
    var repositories: [RepositoryConfiguration]
    var pollIntervalMinutes: Int
    var isPaused: Bool
    var claude: ReviewerConfiguration
    var codex: ReviewerConfiguration
    var customPrompt: String
    var decisionPolicy: DecisionPolicy

    static let `default` = ReviewBotConfiguration(
        repositories: [],
        pollIntervalMinutes: 15,
        isPaused: false,
        claude: ReviewerConfiguration(
            enabled: true,
            model: "claude-opus-4-8",
            effort: .max
        ),
        codex: ReviewerConfiguration(
            enabled: true,
            model: "gpt-5.6-sol",
            effort: .high
        ),
        customPrompt: "",
        decisionPolicy: .default
    )

    private enum CodingKeys: String, CodingKey {
        case repositories
        case pollIntervalMinutes
        case isPaused
        case claude
        case codex
        case customPrompt
        case decisionPolicy
    }

    init(
        repositories: [RepositoryConfiguration],
        pollIntervalMinutes: Int,
        isPaused: Bool,
        claude: ReviewerConfiguration,
        codex: ReviewerConfiguration,
        customPrompt: String,
        decisionPolicy: DecisionPolicy = .default
    ) {
        self.repositories = repositories
        self.pollIntervalMinutes = pollIntervalMinutes
        self.isPaused = isPaused
        self.claude = claude
        self.codex = codex
        self.customPrompt = customPrompt
        self.decisionPolicy = decisionPolicy
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        repositories = try values.decodeIfPresent(
            [RepositoryConfiguration].self,
            forKey: .repositories
        ) ?? []
        pollIntervalMinutes = try values.decodeIfPresent(
            Int.self,
            forKey: .pollIntervalMinutes
        ) ?? 15
        isPaused = try values.decodeIfPresent(Bool.self, forKey: .isPaused) ?? false
        claude = try values.decodeIfPresent(
            ReviewerConfiguration.self,
            forKey: .claude
        ) ?? ReviewBotConfiguration.default.claude
        codex = try values.decodeIfPresent(
            ReviewerConfiguration.self,
            forKey: .codex
        ) ?? ReviewBotConfiguration.default.codex
        if !ReviewEffort.claudeCases.contains(claude.effort) {
            claude.effort = .max
        }
        if !ReviewEffort.codexCases.contains(codex.effort) {
            codex.effort = .high
        }
        customPrompt = try values.decodeIfPresent(String.self, forKey: .customPrompt) ?? ""
        decisionPolicy = try values.decodeIfPresent(
            DecisionPolicy.self,
            forKey: .decisionPolicy
        ) ?? .default
    }
}

enum HistoryEventKind: String, Codable {
    case requestDetected
    case reviewStarted
    case approved
    case changesRequested
    case commented
    case failed

    var label: String {
        switch self {
        case .requestDetected: "Review requested"
        case .reviewStarted: "Review started"
        case .approved: "Approved"
        case .changesRequested: "Changes requested"
        case .commented: "Comment posted"
        case .failed: "Failed"
        }
    }

    var symbol: String {
        switch self {
        case .requestDetected: "bell.badge"
        case .reviewStarted: "sparkles"
        case .approved: "checkmark.circle.fill"
        case .changesRequested: "exclamationmark.octagon.fill"
        case .commented: "text.bubble.fill"
        case .failed: "xmark.circle.fill"
        }
    }
}

struct HistoryEntry: Codable, Equatable, Identifiable {
    var id = UUID()
    var date = Date()
    var kind: HistoryEventKind
    var repositoryName: String
    var repositorySlug: String
    var pullRequestNumber: Int?
    var pullRequestTitle: String?
    var pullRequestURL: String?
    var message: String
}

struct ReviewQueueItem: Equatable, Identifiable {
    let repositoryName: String
    let repositorySlug: String
    let pullRequestNumber: Int
    let pullRequestTitle: String
    let pullRequestURL: String?

    var id: String { "\(repositorySlug)#\(pullRequestNumber)" }

    init?(entry: HistoryEntry) {
        guard let number = entry.pullRequestNumber,
              let title = entry.pullRequestTitle else {
            return nil
        }
        repositoryName = entry.repositoryName
        repositorySlug = entry.repositorySlug
        pullRequestNumber = number
        pullRequestTitle = title
        pullRequestURL = entry.pullRequestURL
    }
}

enum ReviewerName: String, Codable, CaseIterable {
    case claude = "Claude"
    case codex = "Codex"
}

enum ReviewVerdict: String, Codable, CaseIterable {
    case blocking = "BLOCKING"
    case shouldFix = "SHOULD_FIX"
    case nitsOnly = "NITS_ONLY"
    case clean = "CLEAN"

    var rank: Int {
        switch self {
        case .blocking: 3
        case .shouldFix: 2
        case .nitsOnly: 1
        case .clean: 0
        }
    }
}

struct ReviewerResult: Equatable {
    var reviewer: ReviewerName
    var model: String
    var output: String
    var verdict: ReviewVerdict?
    var failure: String?
}

enum ReviewDecision: String, Codable, CaseIterable, Identifiable {
    case approve = "approve"
    case requestChanges = "request_changes"
    case comment = "comment"

    var id: String { rawValue }

    /// Severity ordering used to combine per-verdict actions across reviewers:
    /// requestChanges (strictest) > comment > approve.
    var rank: Int {
        switch self {
        case .requestChanges: 2
        case .comment: 1
        case .approve: 0
        }
    }

    var title: String {
        switch self {
        case .approve: "Approved"
        case .requestChanges: "Changes requested"
        case .comment: "Commented"
        }
    }

    /// User-facing label for the decision-policy pickers.
    var actionLabel: String {
        switch self {
        case .approve: "Approve"
        case .requestChanges: "Request changes"
        case .comment: "Leave it to me"
        }
    }

    var ghArgument: String {
        switch self {
        case .approve: "--approve"
        case .requestChanges: "--request-changes"
        case .comment: "--comment"
        }
    }

    var historyKind: HistoryEventKind {
        switch self {
        case .approve: .approved
        case .requestChanges: .changesRequested
        case .comment: .commented
        }
    }
}

/// Maps each configurable reviewer verdict to the GitHub action the bot takes.
/// `BLOCKING` is always `.requestChanges` and is not user-configurable.
struct DecisionPolicy: Codable, Equatable {
    var shouldFix: ReviewDecision
    var nitsOnly: ReviewDecision
    var clean: ReviewDecision

    static let `default` = DecisionPolicy(
        shouldFix: .requestChanges,
        nitsOnly: .approve,
        clean: .approve
    )

    func action(for verdict: ReviewVerdict) -> ReviewDecision {
        switch verdict {
        case .blocking: .requestChanges
        case .shouldFix: shouldFix
        case .nitsOnly: nitsOnly
        case .clean: clean
        }
    }
}

struct PullRequestSummary: Decodable {
    let number: Int
    let title: String
    let url: String
}

struct PullRequestMetadata: Decodable {
    let title: String
    let headRefOid: String
    let baseRefName: String
    let baseRefOid: String
    let url: String
}

struct InspectedRepository {
    let name: String
    let path: String
    let githubSlug: String
}
