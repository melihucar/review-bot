import XCTest
@testable import ReviewBot

final class ReviewQueueItemTests: XCTestCase {
    private func entry(_ kind: HistoryEventKind, startedAt: Date? = nil) -> HistoryEntry {
        HistoryEntry(
            date: Date(timeIntervalSince1970: 1_800_000_000),
            kind: kind,
            repositoryName: "widget",
            repositorySlug: "acme/widget",
            pullRequestNumber: 42,
            pullRequestTitle: "Improve widgets",
            pullRequestURL: nil,
            message: "",
            startedAt: startedAt
        )
    }

    func testARunningItemKnowsWhenItsReviewStarted() throws {
        let started = Date(timeIntervalSince1970: 1_799_999_000)
        let running = try XCTUnwrap(ReviewQueueItem(entry: entry(.reviewStarted, startedAt: started)))
        XCTAssertEqual(running.startedAt, started)

        // An entry written before the start was stamped falls back to its own date.
        let legacy = try XCTUnwrap(ReviewQueueItem(entry: entry(.reviewStarted)))
        XCTAssertEqual(legacy.startedAt, Date(timeIntervalSince1970: 1_800_000_000))
    }

    func testAWaitingItemHasNoStart() throws {
        let pending = try XCTUnwrap(ReviewQueueItem(entry: entry(.requestDetected)))
        XCTAssertNil(pending.startedAt)
    }

    func testAnEntryWithoutAPullRequestIsNotAQueueItem() {
        var noPullRequest = entry(.failed)
        noPullRequest.pullRequestNumber = nil
        XCTAssertNil(ReviewQueueItem(entry: noPullRequest))
    }
}
