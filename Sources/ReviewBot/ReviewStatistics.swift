import Foundation

/// What the activity history says about Review Bot's own reviewing, over a window: how many
/// decisions it posted and of which kind, how long a review takes, how long an author waited
/// for it, and whether the changes it requested were acted on.
///
/// Computed from `HistoryEntry` alone, so it is the same on both platforms and needs no
/// GitHub call: the durations come from the timestamps the engine stamps on each entry, and
/// follow-through comes from the order of a pull request's entries — a change request that is
/// later followed by an approval at another commit was acted on, and one followed by a
/// `merged` entry made it in. Entries written before those timestamps existed are counted
/// where they can be and left out of the averages.
struct ReviewStatistics: Codable, Equatable {
    /// The window the figures cover, in days back from `now`.
    var windowDays: Int
    /// Decisions posted to GitHub: approvals, change requests and comments.
    var reviewsPosted: Int
    var approved: Int
    var changesRequested: Int
    var commented: Int
    /// Reviews that ended in a failure rather than a posted decision.
    var failed: Int
    /// Checkout to posted decision, over the posted reviews that recorded a start.
    var averageDurationSeconds: Double?
    var medianDurationSeconds: Double?
    /// The most recent posted review's duration — the figure the panel refreshes after
    /// every review.
    var lastDurationSeconds: Double?
    /// Review request on GitHub to posted decision, over the reviews that knew when they
    /// were requested.
    var averageResponseSeconds: Double?
    var medianResponseSeconds: Double?
    /// Distinct pull requests Review Bot requested changes on in the window.
    var pullRequestsWithChangesRequested: Int
    /// Of those, the ones Review Bot later approved at a different commit — the author
    /// pushed a fix and the re-review accepted it.
    var changesRequestedThenApproved: Int
    /// Of those, the ones that were merged after the change request.
    var changesRequestedThenMerged: Int
    /// How many change requests it took, on average, before an approval followed — 1.0
    /// means every request was resolved in one round.
    var averageRoundsToApproval: Double?
    /// Distinct pull requests Review Bot approved in the window, and how many of them
    /// have merged since.
    var pullRequestsApproved: Int
    var approvedThenMerged: Int
    /// Tokens across the window's reviews: everything any reviewer reported, billed or not.
    var totalTokens: Int
    /// The part of `totalTokens` billed to a key, and what it cost — `nil` when any metered
    /// review could not price its tokens, so an unknown cost never reads as free.
    var meteredTokens: Int
    var totalCostUSD: Double?
    /// The part of `totalTokens` consumed on signed-in CLIs, which a subscription covers.
    var sessionTokens: Int

    var changesRequestedThenApprovedRate: Double? {
        rate(changesRequestedThenApproved, of: pullRequestsWithChangesRequested)
    }

    var changesRequestedThenMergedRate: Double? {
        rate(changesRequestedThenMerged, of: pullRequestsWithChangesRequested)
    }

    var approvedThenMergedRate: Double? {
        rate(approvedThenMerged, of: pullRequestsApproved)
    }

    private func rate(_ part: Int, of whole: Int) -> Double? {
        whole > 0 ? Double(part) / Double(whole) : nil
    }

    static let empty = ReviewStatistics(
        windowDays: 30, reviewsPosted: 0, approved: 0, changesRequested: 0, commented: 0,
        failed: 0, averageDurationSeconds: nil, medianDurationSeconds: nil,
        lastDurationSeconds: nil, averageResponseSeconds: nil, medianResponseSeconds: nil,
        pullRequestsWithChangesRequested: 0, changesRequestedThenApproved: 0,
        changesRequestedThenMerged: 0, averageRoundsToApproval: nil, pullRequestsApproved: 0,
        approvedThenMerged: 0, totalTokens: 0, meteredTokens: 0, totalCostUSD: nil,
        sessionTokens: 0
    )

    /// - Parameters:
    ///   - entries: the history in any order; only entries dated within the window count,
    ///     except that a pull request's later `approved` and `merged` entries are read
    ///     wherever they fall, since they are what a change request in the window led to.
    ///   - windowDays: how far back from `now` to look.
    static func compute(
        from entries: [HistoryEntry],
        windowDays: Int = 30,
        now: Date = Date()
    ) -> ReviewStatistics {
        let since = now.addingTimeInterval(-Double(windowDays) * 86_400)
        let inWindow = entries.filter { $0.date >= since && $0.date <= now }
        var stats = ReviewStatistics.empty
        stats.windowDays = windowDays

        var durations: [Double] = []
        var responses: [Double] = []
        var latestPosted: HistoryEntry?
        var costKnown = true
        for entry in inWindow {
            switch entry.kind {
            case .approved: stats.approved += 1
            case .changesRequested: stats.changesRequested += 1
            case .commented: stats.commented += 1
            case .failed: stats.failed += 1
            case .requestDetected, .reviewStarted, .merged: break
            }
            guard entry.kind.isPostedDecision else { continue }
            if let duration = entry.reviewDuration { durations.append(duration) }
            if let response = entry.responseTime { responses.append(response) }
            if latestPosted.map({ entry.date > $0.date }) ?? true { latestPosted = entry }
            if let usage = entry.usage {
                stats.meteredTokens += usage.totalTokens
                if let cost = usage.costUSD { stats.totalCostUSD = (stats.totalCostUSD ?? 0) + cost }
                else { costKnown = false }
            }
            if let session = entry.sessionUsage {
                stats.sessionTokens += session.totalTokens
            }
        }
        stats.totalTokens = stats.meteredTokens + stats.sessionTokens
        stats.reviewsPosted = stats.approved + stats.changesRequested + stats.commented
        stats.averageDurationSeconds = mean(durations)
        stats.medianDurationSeconds = median(durations)
        stats.lastDurationSeconds = latestPosted?.reviewDuration
        stats.averageResponseSeconds = mean(responses)
        stats.medianResponseSeconds = median(responses)
        if !costKnown { stats.totalCostUSD = nil }

        // Follow-through is per pull request, read in the order things happened.
        let byPullRequest = Dictionary(grouping: entries.filter { $0.pullRequestKey != nil }) {
            $0.pullRequestKey!
        }
        var rounds: [Double] = []
        for (_, unordered) in byPullRequest {
            let timeline = unordered.sorted { $0.date < $1.date }
            if let request = timeline.firstIndex(where: {
                $0.kind == .changesRequested && $0.date >= since && $0.date <= now
            }) {
                stats.pullRequestsWithChangesRequested += 1
                let after = timeline[(request + 1)...]
                let requestHead = timeline[request].headCommit
                if let approval = after.firstIndex(where: {
                    $0.kind == .approved && ($0.headCommit == nil || requestHead == nil || $0.headCommit != requestHead)
                }) {
                    stats.changesRequestedThenApproved += 1
                    let requestsBefore = timeline[request..<approval].filter { $0.kind == .changesRequested }.count
                    rounds.append(Double(requestsBefore))
                }
                if after.contains(where: { $0.kind == .merged }) {
                    stats.changesRequestedThenMerged += 1
                }
            }
            if let approval = timeline.firstIndex(where: {
                $0.kind == .approved && $0.date >= since && $0.date <= now
            }) {
                stats.pullRequestsApproved += 1
                if timeline[(approval + 1)...].contains(where: { $0.kind == .merged }) {
                    stats.approvedThenMerged += 1
                }
            }
        }
        stats.averageRoundsToApproval = mean(rounds)
        return stats
    }

    private static func mean(_ values: [Double]) -> Double? {
        values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }

    private static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2)
            ? (sorted[middle - 1] + sorted[middle]) / 2
            : sorted[middle]
    }

    /// "45 s", "9 min", "1 h 12 min" — the shape both panels print a duration in.
    static func describe(seconds: Double?) -> String {
        guard let seconds else { return "—" }
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total) s" }
        let minutes = total / 60
        if minutes < 60 { return "\(minutes) min" }
        let remainder = minutes % 60
        return remainder == 0 ? "\(minutes / 60) h" : "\(minutes / 60) h \(remainder) min"
    }

    /// "93%", or "—" when there is nothing to take a percentage of.
    static func describe(rate: Double?) -> String {
        guard let rate else { return "—" }
        return "\(Int((rate * 100).rounded()))%"
    }
}
