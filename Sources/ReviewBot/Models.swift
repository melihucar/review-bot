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

    // Claude, Codex, and opencode expose different top-tier effort names, so
    // each reviewer only offers the levels its CLI accepts. Gemini's CLI has no
    // effort flag at all — its empty list hides the picker rather than offering
    // a control that would silently do nothing.
    static let claudeCases: [ReviewEffort] = [.low, .medium, .high, .max]
    static let codexCases: [ReviewEffort] = [.low, .medium, .high, .xhigh]
    static let opencodeCases: [ReviewEffort] = [.low, .medium, .high, .max]
    static let geminiCases: [ReviewEffort] = []
}

/// How much of a pull request each review looks at.
enum ReviewScope: String, Codable, CaseIterable, Identifiable {
    /// Review the entire base…head diff every time (default, original behavior).
    case fullPullRequest = "full"
    /// Review only what changed since the commit we last posted a review on.
    case incremental = "incremental"

    var id: String { rawValue }
    var label: String {
        switch self {
        case .fullPullRequest: "Whole PR"
        case .incremental: "New changes only"
        }
    }
}

struct ReviewerConfiguration: Codable, Equatable {
    var enabled: Bool
    var model: String
    var effort: ReviewEffort

    /// Small/experimental models with measurably weaker resistance to injected
    /// thread content (see the prompt-injection spike in issue #3).
    static let smallModelMarkers = ["mimo", "laguna", "lightning", "big-pickle", "hy3", "mini"]

    static func isSmallOrExperimental(_ model: String) -> Bool {
        let name = model.lowercased()
        // "gemini" contains the letters "mini", so strip that token before the
        // mini check; hyphenated mini variants (gpt-4o-mini) still match.
        let withoutGemini = name.replacingOccurrences(of: "gemini", with: "")
        return smallModelMarkers.contains { marker in
            let haystack = marker == "mini" ? withoutGemini : name
            return haystack.contains(marker)
        }
    }
}

struct RepositoryConfiguration: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var path: String
    var githubSlug: String
    var enabled = true
}

/// How many times one review request may fail — a reviewer that errors or returns
/// no verdict, or a post GitHub rejects — before Review Bot stops retrying it.
/// Stored as a plain number so `config.json` stays readable, with `0` meaning
/// "keep retrying"; absent means the config predates the setting and adopts the
/// bounded default.
enum FailureBudget: Codable, Equatable {
    case unlimited
    case attempts(Int)

    static let `default` = FailureBudget.attempts(5)

    /// The attempt ceiling, or `nil` when retries are unlimited.
    var limit: Int? {
        switch self {
        case .unlimited: return nil
        case let .attempts(count): return count
        }
    }

    init(limit: Int?) {
        if let limit {
            self = .attempts(max(1, limit))
        } else {
            self = .unlimited
        }
    }

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(Int.self)
        self = value > 0 ? .attempts(value) : .unlimited
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(limit ?? 0)
    }
}

struct ReviewBotConfiguration: Codable, Equatable {
    var repositories: [RepositoryConfiguration]
    var pollIntervalMinutes: Int
    var isPaused: Bool
    var claude: ReviewerConfiguration
    var codex: ReviewerConfiguration
    var opencode: ReviewerConfiguration
    var gemini: ReviewerConfiguration
    var customPrompt: String
    var decisionPolicy: DecisionPolicy
    var reviewScope: ReviewScope
    /// Maximum number of times a single pull request will be reviewed (across new
    /// commits and re-requests). Counts reviews that actually posted; `nil` means
    /// unlimited.
    var maxReviewRoundsPerPR: Int?
    /// When to stop retrying a review request that keeps failing. Attempts are also
    /// spaced out by a widening backoff, so a permanently broken reviewer costs a
    /// bounded amount of work instead of re-running on every poll forever.
    var failureBudget: FailureBudget
    /// How many pull requests a single poll reviews at the same time. Every one of
    /// them runs every enabled reviewer, so this bounds the fan-out of CLI processes
    /// (and the API traffic behind them); `1` restores the old one-at-a-time poll.
    var maxConcurrentReviews: Int

    static let `default` = ReviewBotConfiguration(
        repositories: [],
        pollIntervalMinutes: 15,
        isPaused: false,
        claude: ReviewerConfiguration(
            enabled: true,
            model: "claude-opus-5",
            effort: .high
        ),
        codex: ReviewerConfiguration(
            enabled: true,
            model: "gpt-5.6-sol",
            effort: .high
        ),
        // opencode is opt-in: the deepseek-v4-flash-free model is free, so the
        // default pairs it with max reasoning effort at no cost.
        opencode: ReviewerConfiguration(
            enabled: false,
            model: "opencode/deepseek-v4-flash-free",
            effort: .max
        ),
        // Gemini is opt-in too. `effort` is stored but unused — the CLI takes no
        // effort flag — so it keeps the shared default rather than a meaningful value.
        gemini: ReviewerConfiguration(
            enabled: false,
            model: "gemini-3.1-pro-high",
            effort: .high
        ),
        customPrompt: "",
        decisionPolicy: .default,
        reviewScope: .fullPullRequest,
        maxReviewRoundsPerPR: nil,
        failureBudget: .default,
        maxConcurrentReviews: 3
    )

    private enum CodingKeys: String, CodingKey {
        case repositories
        case pollIntervalMinutes
        case isPaused
        case claude
        case codex
        case opencode
        case gemini
        case customPrompt
        case decisionPolicy
        case reviewScope
        case maxReviewRoundsPerPR
        case failureBudget
        case maxConcurrentReviews
    }

    init(
        repositories: [RepositoryConfiguration],
        pollIntervalMinutes: Int,
        isPaused: Bool,
        claude: ReviewerConfiguration,
        codex: ReviewerConfiguration,
        opencode: ReviewerConfiguration,
        gemini: ReviewerConfiguration,
        customPrompt: String,
        decisionPolicy: DecisionPolicy = .default,
        reviewScope: ReviewScope = .fullPullRequest,
        maxReviewRoundsPerPR: Int? = nil,
        failureBudget: FailureBudget = .default,
        maxConcurrentReviews: Int = 3
    ) {
        self.repositories = repositories
        self.pollIntervalMinutes = pollIntervalMinutes
        self.isPaused = isPaused
        self.claude = claude
        self.codex = codex
        self.opencode = opencode
        self.gemini = gemini
        self.customPrompt = customPrompt
        self.decisionPolicy = decisionPolicy
        self.reviewScope = reviewScope
        self.maxReviewRoundsPerPR = maxReviewRoundsPerPR.map { max(1, $0) }
        self.failureBudget = failureBudget
        self.maxConcurrentReviews = max(1, maxConcurrentReviews)
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
        opencode = try values.decodeIfPresent(
            ReviewerConfiguration.self,
            forKey: .opencode
        ) ?? ReviewBotConfiguration.default.opencode
        gemini = try values.decodeIfPresent(
            ReviewerConfiguration.self,
            forKey: .gemini
        ) ?? ReviewBotConfiguration.default.gemini
        if !ReviewEffort.claudeCases.contains(claude.effort) {
            claude.effort = .high
        }
        if !ReviewEffort.codexCases.contains(codex.effort) {
            codex.effort = .high
        }
        if !ReviewEffort.opencodeCases.contains(opencode.effort) {
            opencode.effort = .max
        }
        // Gemini has no clamp: its CLI takes no effort flag, so no stored value
        // is wrong and there is no valid set to snap one back to.
        customPrompt = try values.decodeIfPresent(String.self, forKey: .customPrompt) ?? ""
        decisionPolicy = try values.decodeIfPresent(
            DecisionPolicy.self,
            forKey: .decisionPolicy
        ) ?? .default
        reviewScope = try values.decodeIfPresent(
            ReviewScope.self,
            forKey: .reviewScope
        ) ?? .fullPullRequest
        if let rounds = try values.decodeIfPresent(Int.self, forKey: .maxReviewRoundsPerPR) {
            maxReviewRoundsPerPR = max(1, rounds)
        } else {
            maxReviewRoundsPerPR = nil
        }
        // Absent from a pre-existing config: adopt the bounded default rather than
        // the historical unbounded retry.
        failureBudget = try values.decodeIfPresent(
            FailureBudget.self,
            forKey: .failureBudget
        ) ?? .default
        maxConcurrentReviews = max(
            1,
            try values.decodeIfPresent(Int.self, forKey: .maxConcurrentReviews) ?? 3
        )
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
    case opencode = "opencode"
    case gemini = "Gemini"
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

/// Why a reviewer failed, to the extent its own output says so. The only distinction that
/// matters here is whether calling it again could plausibly produce a different answer.
enum ReviewerFailureClass: Equatable {
    /// The same call will fail the same way: an exhausted quota, a rejected credential, a
    /// model the account may not use. Retrying only spends wall time.
    case terminal
    /// Might succeed on a second try — a crash, a dropped connection, a 5xx, a missing
    /// verdict line.
    case transient

    /// Deliberately conservative: anything unrecognised is `transient`. Mistaking a
    /// recoverable failure for a terminal one silently drops a reviewer from the panel,
    /// while the reverse costs a single extra CLI call — a cost the retry already accepts.
    /// The markers are phrases a CLI emits about *itself*, long enough not to fire on a
    /// pull request that happens to discuss quotas or authentication.
    static func classify(_ message: String) -> ReviewerFailureClass {
        let haystack = message.lowercased()
        let terminalMarkers = [
            "usage limit",
            "rate limit exceeded",
            "insufficient_quota",
            "exceeded your current quota",
            "is not supported when using",
            "invalid api key",
            "invalid_api_key",
            "authentication_error",
            "authentication failed",
            "not authenticated",
            "please run `codex login`",
            "please run `claude login`",
            "credit balance is too low",
            // Gemini: quota, a rejected credential, and a CLI build whose OAuth
            // client the service no longer accepts — none of which a second call fixes.
            "resource_exhausted",
            "error authenticating",
            "api key not valid",
            "this client is no longer supported",
        ]
        return terminalMarkers.contains { haystack.contains($0) } ? .terminal : .transient
    }
}

struct ReviewerResult: Equatable {
    var reviewer: ReviewerName
    var model: String
    var output: String
    var verdict: ReviewVerdict?
    var failure: String?
    /// True when the reviewer ran out its own timeout. Re-running it inside the same
    /// review would spend that timeout again on a CLI that is most likely still hung,
    /// so these are left to the next poll instead of retried in place.
    var timedOut = false

    /// `nil` when the reviewer finished; otherwise whether a second call could help.
    var failureClass: ReviewerFailureClass? {
        guard let failure else { return nil }
        return ReviewerFailureClass.classify(failure)
    }

    /// Whether running this reviewer again right now is worth the wall time: a crash,
    /// a transient API error, or a missing verdict line may well succeed on a second
    /// try; a timeout or an exhausted quota will not.
    var isWorthRetrying: Bool {
        guard !timedOut, failureClass != .terminal else { return false }
        return failure != nil || verdict == nil
    }
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
