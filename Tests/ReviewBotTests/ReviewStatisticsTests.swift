import XCTest
@testable import ReviewBot

final class ReviewStatisticsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func entry(
        _ kind: HistoryEventKind,
        pullRequest: Int,
        minutesAgo: Double,
        startedMinutesBefore: Double? = nil,
        requestedMinutesBefore: Double? = nil,
        head: String? = nil,
        usage: TokenUsage? = nil,
        sessionUsage: TokenUsage? = nil
    ) -> HistoryEntry {
        let date = now.addingTimeInterval(-minutesAgo * 60)
        return HistoryEntry(
            date: date,
            kind: kind,
            repositoryName: "widget",
            repositorySlug: "acme/widget",
            pullRequestNumber: pullRequest,
            pullRequestTitle: "PR \(pullRequest)",
            pullRequestURL: nil,
            message: "",
            usage: usage,
            sessionUsage: sessionUsage,
            requestedAt: requestedMinutesBefore.map { date.addingTimeInterval(-$0 * 60) },
            startedAt: startedMinutesBefore.map { date.addingTimeInterval(-$0 * 60) },
            headCommit: head
        )
    }

    func testCountsDurationsAndResponseTimesOverThePostedDecisions() {
        let entries = [
            entry(.approved, pullRequest: 1, minutesAgo: 10, startedMinutesBefore: 4, requestedMinutesBefore: 20),
            entry(.changesRequested, pullRequest: 2, minutesAgo: 30, startedMinutesBefore: 8, requestedMinutesBefore: 10),
            entry(.commented, pullRequest: 3, minutesAgo: 40, startedMinutesBefore: 6),
            entry(.failed, pullRequest: 4, minutesAgo: 50, startedMinutesBefore: 100),
            entry(.requestDetected, pullRequest: 5, minutesAgo: 5),
            entry(.reviewStarted, pullRequest: 5, minutesAgo: 4),
        ]

        let stats = ReviewStatistics.compute(from: entries, now: now)

        XCTAssertEqual(stats.reviewsPosted, 3)
        XCTAssertEqual(stats.approved, 1)
        XCTAssertEqual(stats.changesRequested, 1)
        XCTAssertEqual(stats.commented, 1)
        XCTAssertEqual(stats.failed, 1)
        // Only posted decisions count towards duration: the failure's 100 minutes stay out.
        XCTAssertEqual(stats.averageDurationSeconds, 6 * 60)
        XCTAssertEqual(stats.medianDurationSeconds, 6 * 60)
        XCTAssertEqual(stats.lastDurationSeconds, 4 * 60, "the newest posted review is the one the panel shows as 'last'")
        XCTAssertEqual(stats.averageResponseSeconds, 15 * 60)
        XCTAssertEqual(stats.medianResponseSeconds, 15 * 60)
    }

    func testEntriesOutsideTheWindowAreIgnored() {
        let entries = [
            entry(.approved, pullRequest: 1, minutesAgo: 10, startedMinutesBefore: 4),
            entry(.approved, pullRequest: 2, minutesAgo: 31 * 24 * 60, startedMinutesBefore: 400),
        ]

        let stats = ReviewStatistics.compute(from: entries, windowDays: 30, now: now)

        XCTAssertEqual(stats.approved, 1)
        XCTAssertEqual(stats.averageDurationSeconds, 4 * 60)
    }

    func testAChangeRequestFollowedByAnApprovalAtAnotherCommitCountsAsActedOn() {
        let entries = [
            entry(.changesRequested, pullRequest: 1, minutesAgo: 100, head: "aaa"),
            entry(.changesRequested, pullRequest: 1, minutesAgo: 80, head: "bbb"),
            entry(.approved, pullRequest: 1, minutesAgo: 60, head: "ccc"),
            entry(.merged, pullRequest: 1, minutesAgo: 50),
            // A re-review of the same commit that approved is not the author acting on it.
            entry(.changesRequested, pullRequest: 2, minutesAgo: 100, head: "ddd"),
            entry(.approved, pullRequest: 2, minutesAgo: 90, head: "ddd"),
            // Requested, never resolved, but merged anyway.
            entry(.changesRequested, pullRequest: 3, minutesAgo: 100, head: "eee"),
            entry(.merged, pullRequest: 3, minutesAgo: 20),
        ]

        let stats = ReviewStatistics.compute(from: entries, now: now)

        XCTAssertEqual(stats.pullRequestsWithChangesRequested, 3)
        XCTAssertEqual(stats.changesRequestedThenApproved, 1)
        XCTAssertEqual(stats.changesRequestedThenMerged, 2)
        XCTAssertEqual(stats.averageRoundsToApproval, 2, "two change requests preceded #1's approval")
        XCTAssertEqual(stats.changesRequestedThenApprovedRate.map { Int(($0 * 100).rounded()) }, 33)
        XCTAssertEqual(stats.changesRequestedThenMergedRate.map { Int(($0 * 100).rounded()) }, 67)
    }

    func testEntriesWithoutAHeadCommitStillCountAnApprovalAsActedOn() {
        // History written before the head was recorded has no commit to compare, and a
        // later approval is the best evidence available.
        let entries = [
            entry(.changesRequested, pullRequest: 1, minutesAgo: 100),
            entry(.approved, pullRequest: 1, minutesAgo: 60),
        ]

        let stats = ReviewStatistics.compute(from: entries, now: now)

        XCTAssertEqual(stats.changesRequestedThenApproved, 1)
        XCTAssertEqual(stats.averageRoundsToApproval, 1)
    }

    func testApprovalsAreFollowedToTheMerge() {
        let entries = [
            entry(.approved, pullRequest: 1, minutesAgo: 100),
            entry(.merged, pullRequest: 1, minutesAgo: 90),
            entry(.approved, pullRequest: 2, minutesAgo: 100),
        ]

        let stats = ReviewStatistics.compute(from: entries, now: now)

        XCTAssertEqual(stats.pullRequestsApproved, 2)
        XCTAssertEqual(stats.approvedThenMerged, 1)
        XCTAssertEqual(ReviewStatistics.describe(rate: stats.approvedThenMergedRate), "50%")
    }

    func testAFollowUpOutsideTheWindowStillResolvesARequestInsideIt() {
        // The window selects which change requests to report on; what they led to is read
        // wherever it falls, or a request made on the window's last day could never resolve.
        let entries = [
            entry(.changesRequested, pullRequest: 1, minutesAgo: 29 * 24 * 60, head: "aaa"),
            entry(.approved, pullRequest: 1, minutesAgo: 31 * 24 * 60, head: "zzz"), // earlier: ignored
            entry(.merged, pullRequest: 1, minutesAgo: 1),
        ]

        let stats = ReviewStatistics.compute(from: entries, now: now)

        XCTAssertEqual(stats.pullRequestsWithChangesRequested, 1)
        XCTAssertEqual(stats.changesRequestedThenApproved, 0, "an approval *before* the request did not act on it")
        XCTAssertEqual(stats.changesRequestedThenMerged, 1)
    }

    func testSpendIsSummedAndAnUnpricedReviewMakesTheCostUnknown() {
        let priced = TokenUsage(inputTokens: 1_000, cachedInputTokens: 0, outputTokens: 500, requests: 1, costUSD: 0.5)
        let unpriced = TokenUsage(inputTokens: 200, cachedInputTokens: 0, outputTokens: 100, requests: 1, costUSD: nil)

        let known = ReviewStatistics.compute(
            from: [entry(.approved, pullRequest: 1, minutesAgo: 1, usage: priced),
                   entry(.approved, pullRequest: 2, minutesAgo: 2, usage: priced)],
            now: now
        )
        XCTAssertEqual(known.totalTokens, 3_000)
        XCTAssertEqual(known.totalCostUSD, 1.0)

        let unknown = ReviewStatistics.compute(
            from: [entry(.approved, pullRequest: 1, minutesAgo: 1, usage: priced),
                   entry(.approved, pullRequest: 2, minutesAgo: 2, usage: unpriced)],
            now: now
        )
        XCTAssertEqual(unknown.totalTokens, 1_800)
        XCTAssertNil(unknown.totalCostUSD, "a rate times unknown tokens is unknown, not free")
    }

    func testSessionTokensAreCountedApartFromMeteredSpend() {
        let priced = TokenUsage(inputTokens: 1_000, cachedInputTokens: 0, outputTokens: 500, requests: 1, costUSD: 0.5)
        let subscription = TokenUsage(inputTokens: 4_000, cachedInputTokens: 1_000, outputTokens: 300, requests: 1)

        let stats = ReviewStatistics.compute(
            from: [entry(.approved, pullRequest: 1, minutesAgo: 1, usage: priced),
                   entry(.approved, pullRequest: 2, minutesAgo: 2, sessionUsage: subscription),
                   entry(.changesRequested, pullRequest: 3, minutesAgo: 3, usage: priced, sessionUsage: subscription)],
            now: now
        )

        XCTAssertEqual(stats.meteredTokens, 3_000)
        XCTAssertEqual(stats.sessionTokens, 10_600)
        XCTAssertEqual(stats.totalTokens, 13_600)
        XCTAssertEqual(stats.totalCostUSD, 1.0, "a subscription review neither adds to the cost nor makes it unknown")

        let sessionOnly = ReviewStatistics.compute(
            from: [entry(.approved, pullRequest: 2, minutesAgo: 2, sessionUsage: subscription)],
            now: now
        )
        XCTAssertEqual(sessionOnly.meteredTokens, 0)
        XCTAssertNil(sessionOnly.totalCostUSD)
    }

    func testAnEmptyHistoryHasNoAveragesRatherThanZeros() {
        let stats = ReviewStatistics.compute(from: [], now: now)

        XCTAssertEqual(stats.reviewsPosted, 0)
        XCTAssertNil(stats.averageDurationSeconds)
        XCTAssertNil(stats.averageResponseSeconds)
        XCTAssertNil(stats.changesRequestedThenApprovedRate)
        XCTAssertEqual(ReviewStatistics.describe(seconds: nil), "—")
        XCTAssertEqual(ReviewStatistics.describe(rate: nil), "—")
    }

    func testDurationsAreDescribedInTheUnitThatFits() {
        XCTAssertEqual(ReviewStatistics.describe(seconds: 45), "45 s")
        XCTAssertEqual(ReviewStatistics.describe(seconds: 9 * 60 + 20), "9 min")
        XCTAssertEqual(ReviewStatistics.describe(seconds: 60 * 60), "1 h")
        XCTAssertEqual(ReviewStatistics.describe(seconds: 72 * 60), "1 h 12 min")
    }

    func testTheStatisticsRoundTripThroughJSONForTheDashboard() throws {
        let stats = ReviewStatistics.compute(
            from: [entry(.approved, pullRequest: 1, minutesAgo: 1, startedMinutesBefore: 3)],
            now: now
        )
        let data = try JSONEncoder().encode(stats)
        XCTAssertEqual(try JSONDecoder().decode(ReviewStatistics.self, from: data), stats)
    }
}
