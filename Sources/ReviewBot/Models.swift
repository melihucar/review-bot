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
    // each reviewer only offers the levels its CLI accepts.
    static let claudeCases: [ReviewEffort] = [.low, .medium, .high, .max]
    static let codexCases: [ReviewEffort] = [.low, .medium, .high, .xhigh]
    static let opencodeCases: [ReviewEffort] = [.low, .medium, .high, .max]
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

/// What one reviewer consumed producing one review.
struct TokenUsage: Codable, Equatable {
    var inputTokens: Int
    /// Input tokens served from the provider's prompt cache; billed at a lower rate.
    var cachedInputTokens: Int
    var outputTokens: Int
    /// Number of provider calls. DeepSeek's agent loop makes many per review.
    var requests: Int
    /// `nil` when the provider does not report cost — a missing cost must never be shown
    /// as `$0.00`.
    var costUSD: Double?

    init(
        inputTokens: Int = 0,
        cachedInputTokens: Int = 0,
        outputTokens: Int = 0,
        requests: Int = 0,
        costUSD: Double? = nil
    ) {
        self.inputTokens = inputTokens
        self.cachedInputTokens = cachedInputTokens
        self.outputTokens = outputTokens
        self.requests = requests
        self.costUSD = costUSD
    }

    var totalTokens: Int { inputTokens + cachedInputTokens + outputTokens }

    static func + (lhs: TokenUsage, rhs: TokenUsage) -> TokenUsage {
        TokenUsage(
            inputTokens: lhs.inputTokens + rhs.inputTokens,
            cachedInputTokens: lhs.cachedInputTokens + rhs.cachedInputTokens,
            outputTokens: lhs.outputTokens + rhs.outputTokens,
            requests: lhs.requests + rhs.requests,
            costUSD: lhs.costUSD == nil && rhs.costUSD == nil
                ? nil
                : (lhs.costUSD ?? 0) + (rhs.costUSD ?? 0)
        )
    }

    /// Input tokens in total, cached and uncached. `inputTokens` alone is the uncached portion,
    /// which is the figure that matters for pricing but not the one a reader expects to see.
    var totalInputTokens: Int { inputTokens + cachedInputTokens }

    /// e.g. `24.1k in (11.0k cached) + 2.0k out over 7 calls`. The cached count is a subset of
    /// the input count, matching how providers report it.
    var tokenSummary: String {
        var input = "\(Self.abbreviated(totalInputTokens)) in"
        if cachedInputTokens > 0 {
            input += " (\(Self.abbreviated(cachedInputTokens)) cached)"
        }
        let joined = "\(input) + \(Self.abbreviated(outputTokens)) out"
        return requests > 1 ? "\(joined) over \(requests) calls" : joined
    }

    /// `nil` when cost is unknown, so callers can say so rather than imply it was free.
    var costSummary: String? {
        guard let costUSD else { return nil }
        return costUSD >= 1
            ? String(format: "$%.2f", costUSD)
            : String(format: "$%.4f", costUSD)
    }

    static func abbreviated(_ count: Int) -> String {
        if count >= 1_000_000 { return String(format: "%.1fM", Double(count) / 1_000_000) }
        if count >= 1_000 { return String(format: "%.1fk", Double(count) / 1_000) }
        return String(count)
    }
}

/// Where a reviewer gets its provider credentials.
enum ReviewerAuthMode: String, Codable, CaseIterable, Identifiable {
    /// Use whatever the reviewer's CLI is already signed in as. Review Bot passes no key.
    case session
    /// Use an API key held in the macOS Keychain.
    case apiKey

    var id: String { rawValue }

    var label: String {
        switch self {
        case .session: "Signed-in CLI"
        case .apiKey: "API key"
        }
    }
}

struct ReviewerConfiguration: Codable, Equatable {
    var enabled: Bool
    var model: String
    var effort: ReviewEffort
    /// Never holds the key itself — only which source to use. Keys live in the Keychain.
    var authMode: ReviewerAuthMode

    init(
        enabled: Bool,
        model: String,
        effort: ReviewEffort,
        authMode: ReviewerAuthMode = .session
    ) {
        self.enabled = enabled
        self.model = model
        self.effort = effort
        self.authMode = authMode
    }

    private enum CodingKeys: String, CodingKey {
        case enabled
        case model
        case effort
        case authMode
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        model = try values.decodeIfPresent(String.self, forKey: .model) ?? ""
        effort = try values.decodeIfPresent(ReviewEffort.self, forKey: .effort) ?? .high
        authMode = try values.decodeIfPresent(ReviewerAuthMode.self, forKey: .authMode) ?? .session
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
    var deepseek: ReviewerConfiguration
    var customPrompt: String
    /// Whether the posted review reports what the API-key reviewers consumed.
    var includeUsageInReview: Bool
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

    /// DeepSeek has no CLI to inherit a session from, so it is API-key-only and starts disabled.
    static let defaultDeepSeek = ReviewerConfiguration(
        enabled: false,
        model: "deepseek-chat",
        effort: .high,
        authMode: .apiKey
    )

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
        // default pairs it with max reasoning effort at no cost. It signs in through its
        // own config directory, so it never takes a key.
        opencode: ReviewerConfiguration(
            enabled: false,
            model: "opencode/deepseek-v4-flash-free",
            effort: .max,
            authMode: .session
        ),
        deepseek: defaultDeepSeek,
        customPrompt: "",
        includeUsageInReview: true,
        decisionPolicy: .default,
        reviewScope: .fullPullRequest,
        maxReviewRoundsPerPR: nil,
        failureBudget: .default,
        maxConcurrentReviews: 3
    )

    /// `decoded` unless it is blank, in which case the shipped default.
    private static func model(_ decoded: String, or fallback: String) -> String {
        decoded.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? fallback : decoded
    }

    private enum CodingKeys: String, CodingKey {
        case repositories
        case pollIntervalMinutes
        case isPaused
        case claude
        case codex
        case opencode
        case deepseek
        case customPrompt
        case includeUsageInReview
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
        deepseek: ReviewerConfiguration = ReviewBotConfiguration.defaultDeepSeek,
        customPrompt: String,
        includeUsageInReview: Bool = true,
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
        self.deepseek = deepseek
        self.customPrompt = customPrompt
        self.includeUsageInReview = includeUsageInReview
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
        deepseek = try values.decodeIfPresent(
            ReviewerConfiguration.self,
            forKey: .deepseek
        ) ?? ReviewBotConfiguration.defaultDeepSeek
        if !ReviewEffort.claudeCases.contains(claude.effort) {
            claude.effort = .high
        }
        if !ReviewEffort.codexCases.contains(codex.effort) {
            codex.effort = .high
        }
        if !ReviewEffort.opencodeCases.contains(opencode.effort) {
            opencode.effort = .max
        }
        // `ReviewerConfiguration.init(from:)` decodes a missing `model` to an empty string so a
        // hand-edited config still loads instead of throwing the whole file away. An empty model
        // is not runnable, though — the CLI would be invoked as `--model ""` and fail in a way
        // that reads as a provider outage — so fall back to the shipped default here, where the
        // reviewer's identity is known, exactly as an out-of-range effort does above.
        claude.model = Self.model(claude.model, or: Self.default.claude.model)
        codex.model = Self.model(codex.model, or: Self.default.codex.model)
        opencode.model = Self.model(opencode.model, or: Self.default.opencode.model)
        // opencode signs in through its own config directory and takes no key, so there is
        // nothing to hand it in API-key mode. Pinning the mode here keeps a hand-edited or
        // migrated config from selecting one where Review Bot would inject nothing and still
        // count the reviewer as metered.
        opencode.authMode = .session
        // DeepSeek is reached over HTTP, so there is no CLI session to fall back on.
        deepseek.authMode = .apiKey
        customPrompt = try values.decodeIfPresent(String.self, forKey: .customPrompt) ?? ""
        includeUsageInReview = try values.decodeIfPresent(
            Bool.self,
            forKey: .includeUsageInReview
        ) ?? true
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
    /// Combined usage for the review this entry describes, so spend can be totalled from
    /// `history.json` later. Absent on entries written before usage was tracked.
    var usage: TokenUsage?
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

/// Declaration order is load-bearing beyond this enum: `enabledReviewers` maps `allCases`,
/// which fixes the order reviewers appear in the posted panel and the order
/// `ReviewEngine.runReconciliation` prefers an adjudicator in (Claude, then Codex, then
/// opencode). DeepSeek comes last deliberately, so the one reviewer that always bills a key
/// never becomes the adjudicator while a session-backed CLI is available.
enum ReviewerName: String, Codable, CaseIterable, Identifiable {
    case claude = "Claude"
    case codex = "Codex"
    case opencode = "opencode"
    case deepseek = "DeepSeek"

    var id: String { rawValue }

    /// The CLI this reviewer shells out to, or `nil` when it is reached over HTTP.
    var commandName: String? {
        switch self {
        case .claude: "claude"
        case .codex: "codex"
        case .opencode: "opencode"
        case .deepseek: nil
        }
    }

    /// Only CLI-backed reviewers can borrow an existing login session.
    var supportsSessionAuth: Bool { commandName != nil }

    /// Whether a key of the developer's own can be pointed at this reviewer at all: either it
    /// is a CLI that reads one from its environment, or it has no CLI and a key is the only way
    /// to reach it. opencode is neither — it authenticates through its own config directory —
    /// so offering it an API-key mode would produce a reviewer Review Bot cannot credential.
    var supportsAPIKeyAuth: Bool { apiKeyEnvironmentVariable != nil || commandName == nil }

    /// The variable a CLI-backed reviewer reads its API key from, when the developer
    /// chooses key auth over the CLI's own session.
    var apiKeyEnvironmentVariable: String? {
        switch self {
        case .claude: "ANTHROPIC_API_KEY"
        case .codex: "OPENAI_API_KEY"
        // opencode is credentialed through OPENCODE_CONFIG_DIR, not through an injected key,
        // so there is nothing to hand its child process.
        case .opencode: nil
        case .deepseek: nil
        }
    }

    /// The variable Review Bot itself reads a key from, taking precedence over the Keychain.
    /// Unlike `apiKeyEnvironmentVariable` — which is outbound, handed to a CLI child process —
    /// this is inbound, and every reviewer has one including DeepSeek, which has no CLI. It is
    /// how `make run`, a test, or a one-off probe supplies a key without touching the
    /// developer's Keychain. Note that a GUI app started from Finder or at login inherits
    /// launchd's environment, not a shell's, so this is a development affordance: the packaged
    /// app still reads the Keychain. opencode's entry exists only because the property is
    /// total; it is never consulted, since opencode is pinned to session auth.
    var apiKeyOverrideEnvironmentVariable: String {
        switch self {
        case .claude: "ANTHROPIC_API_KEY"
        case .codex: "OPENAI_API_KEY"
        case .opencode: "OPENCODE_API_KEY"
        case .deepseek: "DEEPSEEK_API_KEY"
        }
    }

    /// DeepSeek is called through the chat-completions API, which has no effort control.
    var usesEffortSetting: Bool { self != .deepseek }

    /// Whether the reviewer tells us what it spent. Claude's CLI reports both tokens and a
    /// dollar figure under `--output-format json`; DeepSeek's API reports tokens, though never a
    /// price; Codex and opencode print the review and nothing else, so there is no usage envelope
    /// to read.
    var reportsTokenUsage: Bool {
        switch self {
        case .claude: true
        case .codex: false
        case .opencode: false
        case .deepseek: true
        }
    }

    var efforts: [ReviewEffort] {
        switch self {
        case .claude: ReviewEffort.claudeCases
        case .codex: ReviewEffort.codexCases
        case .opencode: ReviewEffort.opencodeCases
        case .deepseek: []
        }
    }

    var symbolName: String {
        switch self {
        case .claude: "brain.head.profile"
        case .codex: "terminal.fill"
        case .opencode: "chevron.left.forwardslash.chevron.right"
        case .deepseek: "cloud.fill"
        }
    }
}

/// A reviewer paired with its settings, so the engine can treat all reviewers uniformly.
struct ConfiguredReviewer {
    let name: ReviewerName
    let configuration: ReviewerConfiguration
}

extension ReviewBotConfiguration {
    func settings(for reviewer: ReviewerName) -> ReviewerConfiguration {
        switch reviewer {
        case .claude: claude
        case .codex: codex
        case .opencode: opencode
        case .deepseek: deepseek
        }
    }

    /// Enabled reviewers in a stable order, so posted reviews and history read the same way
    /// on every run.
    var enabledReviewers: [ConfiguredReviewer] {
        ReviewerName.allCases
            .map { ConfiguredReviewer(name: $0, configuration: settings(for: $0)) }
            .filter(\.configuration.enabled)
    }
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
            // DeepSeek answers a bad key with "Authentication Fails" and an empty account
            // with "Insufficient Balance"; both arrive wrapped in `DeepSeek returned HTTP …`.
            "authentication fails",
            "insufficient balance",
            "deepseek returned http 401",
            "deepseek returned http 402",
            // Review Bot's own message for a reviewer set to API-key auth whose key is absent
            // or whose Keychain prompt was denied. Only Settings can fix that, so retrying
            // would spend the failure budget on a request that cannot start.
            "key could not be read",
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
    /// `nil` when the reviewer cannot report what it consumed. When a reviewer is retried
    /// inside one review this holds every attempt's spend, not the last one's — a discarded
    /// first attempt still billed the key.
    var usage: TokenUsage?

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
