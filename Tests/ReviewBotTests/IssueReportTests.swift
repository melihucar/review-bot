import Foundation
import XCTest
@testable import ReviewBot

final class IssueReportTests: XCTestCase {
    private let generatedAt = Date(timeIntervalSince1970: 1_770_000_000)
    private let failedAt = Date(timeIntervalSince1970: 1_769_990_000)

    private func makeEntry(
        repositoryName: String = "Widgets",
        repositorySlug: String = "acme/widgets",
        pullRequestNumber: Int? = 42,
        pullRequestTitle: String? = "Add sprockets",
        pullRequestURL: String? = "https://github.com/acme/widgets/pull/42",
        message: String = "Diff check failed."
    ) -> HistoryEntry {
        HistoryEntry(
            date: failedAt,
            kind: .failed,
            repositoryName: repositoryName,
            repositorySlug: repositorySlug,
            pullRequestNumber: pullRequestNumber,
            pullRequestTitle: pullRequestTitle,
            pullRequestURL: pullRequestURL,
            message: message,
            usage: nil
        )
    }

    private func makeEnvironment(
        toolAvailability: [String: Bool] = ["gh": true, "claude": true, "codex": false]
    ) -> IssueReport.Environment {
        IssueReport.Environment(
            appVersion: "1.2.3",
            operatingSystem: "15.1.0",
            toolAvailability: toolAvailability,
            enabledReviewers: ["Claude (claude-opus-5)", "Codex (gpt-5.6-sol)"],
            pollIntervalMinutes: 15,
            maxConcurrentReviews: 3,
            failureBudget: "5 attempts",
            reviewScope: "Whole PR",
            dataFolderPath: "/Users/test/Library/Application Support/ReviewBot"
        )
    }

    // MARK: - Title

    func testTitleIsDerivedFromTheMessageClippedAndDoesNotCarryTheRetryNote() {
        let message = "The diff for this pull request is much larger than any reviewer's context " +
            "window can hold, so nothing could be reviewed at all. Attempt 5 of 5 — giving up on " +
            "this request; a new commit, a re-request, or Run now starts over."
        let entry = makeEntry(message: message)
        let report = IssueReport(entry: entry, environment: makeEnvironment(), generatedAt: generatedAt)

        XCTAssertTrue(
            report.title.hasPrefix("Review failed: Widgets #42 — The diff for this pull request"),
            "unexpected title: \(report.title)"
        )
        // The retry note is the long tail of the message; the title must clip before reaching it.
        XCTAssertFalse(report.title.contains("Attempt 5 of 5"))
        XCTAssertFalse(report.title.contains("giving up"))
        // Roughly 60 characters of reason plus the "Review failed: <repo> #<n> — " prefix and an
        // ellipsis — nowhere near the length of the full message.
        XCTAssertLessThan(report.title.count, 120)
    }

    func testShortMessagesAreNotClippedOrGivenAnEllipsis() {
        let entry = makeEntry(message: "gh: authentication failed.")
        let report = IssueReport(entry: entry, environment: makeEnvironment(), generatedAt: generatedAt)

        XCTAssertEqual(report.title, "Review failed: Widgets #42 — gh: authentication failed.")
    }

    // MARK: - Body

    func testBodyContainsTheFailureMessageRepositoryPullRequestAndEnvironmentRows() {
        let entry = makeEntry()
        let report = IssueReport(entry: entry, environment: makeEnvironment(), generatedAt: generatedAt)

        XCTAssertTrue(report.body.contains(entry.message))
        XCTAssertTrue(report.body.contains("acme/widgets"))
        XCTAssertTrue(report.body.contains("#42"))
        XCTAssertTrue(report.body.contains("https://github.com/acme/widgets/pull/42"))
        XCTAssertTrue(report.body.contains("Add sprockets"))

        // Key environment rows.
        XCTAssertTrue(report.body.contains("| Review Bot version | 1.2.3 |"))
        XCTAssertTrue(report.body.contains("| macOS | 15.1.0 |"))
        XCTAssertTrue(report.body.contains("| Poll interval | 15 minutes |"))
        XCTAssertTrue(report.body.contains("| Concurrent reviews | 3 |"))
        XCTAssertTrue(report.body.contains("| Failure budget | 5 attempts |"))
        XCTAssertTrue(report.body.contains("| Review scope | Whole PR |"))
        XCTAssertTrue(report.body.contains("Claude (claude-opus-5)"))
        XCTAssertTrue(report.body.contains("Codex (gpt-5.6-sol)"))

        // The data folder path shows up in the logs pointer, not the table.
        XCTAssertTrue(report.body.contains("/Users/test/Library/Application Support/ReviewBot/logs/"))
        XCTAssertTrue(report.body.contains("Show data folder"))
    }

    func testEntryWithNoPullRequestProducesASensibleTitleAndBodyWithoutNilOrEmptyCells() {
        let entry = makeEntry(
            repositoryName: "",
            repositorySlug: "",
            pullRequestNumber: nil,
            pullRequestTitle: nil,
            pullRequestURL: nil,
            message: "Could not list pull requests for review (gh: authentication failed)."
        )
        let report = IssueReport(entry: entry, environment: makeEnvironment(), generatedAt: generatedAt)

        // Neither the repository name nor the slug is known, so the title falls all the way
        // back to naming Review Bot itself rather than printing an empty subject.
        XCTAssertTrue(report.title.hasPrefix("Review failed: Review Bot —"), report.title)
        XCTAssertFalse(report.title.contains("#nil"))
        XCTAssertFalse(report.body.contains("#nil"))
        XCTAssertFalse(report.body.contains("| |"))
        XCTAssertTrue(report.body.contains("not tied to a specific pull request"))
        XCTAssertTrue(report.body.contains("unknown"))
    }

    func testEntryWithARepositoryButNoPullRequestNamesTheRepositoryAlone() {
        let entry = makeEntry(
            repositoryName: "Widgets",
            repositorySlug: "acme/widgets",
            pullRequestNumber: nil,
            pullRequestTitle: nil,
            pullRequestURL: nil,
            message: "REVIEW.md could not be read from the base commit."
        )
        let report = IssueReport(entry: entry, environment: makeEnvironment(), generatedAt: generatedAt)

        XCTAssertTrue(report.title.hasPrefix("Review failed: Widgets —"), report.title)
        XCTAssertFalse(report.title.contains("#"))
    }

    // MARK: - formURL

    func testFormURLPercentEncodesAndRoundTripsSpaceAmpersandHashAndPlus() {
        let entry = makeEntry(message: "Diff check failed: size & shape # of files + count mismatch, retry?")
        let report = IssueReport(entry: entry, environment: makeEnvironment(), generatedAt: generatedAt)

        guard let url = report.formURL(repository: "acme/widgets") else {
            return XCTFail("expected formURL to build a URL")
        }
        XCTAssertTrue(url.absoluteString.hasPrefix("https://github.com/acme/widgets/issues/new?"))

        // The regression this guards against: encoding a space (or anything else) as a literal
        // '+' would have GitHub decode it back as a space, silently corrupting the report.
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = components.queryItems else {
            return XCTFail("expected a query string")
        }
        let decodedTitle = items.first(where: { $0.name == "title" })?.value
        let decodedBody = items.first(where: { $0.name == "body" })?.value

        XCTAssertEqual(decodedTitle, report.title)
        XCTAssertEqual(decodedBody, report.urlBody)
        // The literal '+' in the message must have survived the round trip as '+', not become a
        // space.
        XCTAssertTrue(decodedBody?.contains("files + count") ?? false)
    }

    func testFormURLUsesTheDefaultRepositoryWhenNoneIsGiven() {
        let entry = makeEntry()
        let report = IssueReport(entry: entry, environment: makeEnvironment(), generatedAt: generatedAt)

        XCTAssertTrue(
            report.formURL()?.absoluteString.hasPrefix("https://github.com/\(IssueReport.defaultRepository)/issues/new?") ?? false
        )
    }

    // MARK: - urlBody

    func testUrlBodyIsCappedAtTheLimitAndCarriesTheClipboardMarkerForAVeryLongMessage() {
        let longMessage = String(
            repeating: "This failure repeats a long diagnostic line so the body exceeds the URL cap. ",
            count: 200
        )
        let entry = makeEntry(message: longMessage)
        let report = IssueReport(entry: entry, environment: makeEnvironment(), generatedAt: generatedAt)

        XCTAssertGreaterThan(encodedLength(report.body), IssueReport.urlBodyEncodedLimit)
        XCTAssertLessThanOrEqual(encodedLength(report.urlBody), IssueReport.urlBodyEncodedLimit)
        XCTAssertTrue(report.urlBody.localizedCaseInsensitiveContains("clipboard"))
    }

    /// The cap is a byte budget, so it has to hold for a body that is mostly *escaped* bytes —
    /// the case a character-counting cap gets wrong by a factor of three. Spaces and newlines
    /// alone already do this to a real report, which is why the encoded length is what `urlBody`
    /// measures.
    func testUrlBodyRespectsTheByteBudgetForABodyOfEntirelyEscapedCharacters() {
        let entry = makeEntry(message: String(repeating: "→ ", count: 2_000))
        let report = IssueReport(entry: entry, environment: makeEnvironment(), generatedAt: generatedAt)

        XCTAssertLessThanOrEqual(encodedLength(report.urlBody), IssueReport.urlBodyEncodedLimit)
        // Every one of those characters encodes to at least three bytes, so a body kept inside a
        // 6000-byte budget is necessarily far shorter than 6000 characters — the assertion that
        // would have failed against a character-counting cap.
        XCTAssertLessThan(report.urlBody.count, IssueReport.urlBodyEncodedLimit)
        XCTAssertTrue(report.urlBody.localizedCaseInsensitiveContains("clipboard"))
    }

    func testUrlBodyPassesAShortBodyThroughUnchanged() {
        let entry = makeEntry(message: "Short failure.")
        let report = IssueReport(entry: entry, environment: makeEnvironment(), generatedAt: generatedAt)

        XCTAssertLessThan(encodedLength(report.body), IssueReport.urlBodyEncodedLimit)
        XCTAssertEqual(report.urlBody, report.body)
    }

    /// Mirrors `IssueReport`'s own accounting — one byte per RFC 3986 unreserved character,
    /// three for every other — computed here from the *actual* encoder output so the test
    /// measures what a browser would send rather than restating the implementation's arithmetic.
    private func encodedLength(_ text: String) -> Int {
        let unreserved = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
        )
        return text.addingPercentEncoding(withAllowedCharacters: unreserved)?.count ?? .max
    }

    // MARK: - toolAvailability ordering

    func testToolAvailabilityRendersInADeterministicOrderRegardlessOfDictionaryInsertionOrder() {
        let entry = makeEntry()
        let orderingA: [String: Bool] = ["gh": true, "claude": false, "codex": true]
        let orderingB: [String: Bool] = ["codex": true, "claude": false, "gh": true]

        let reportA = IssueReport(entry: entry, environment: makeEnvironment(toolAvailability: orderingA), generatedAt: generatedAt)
        let reportB = IssueReport(entry: entry, environment: makeEnvironment(toolAvailability: orderingB), generatedAt: generatedAt)

        XCTAssertEqual(reportA.body, reportB.body)
        // Alphabetical by CLI name: claude, codex, gh.
        XCTAssertTrue(reportA.body.contains("claude ✗, codex ✓, gh ✓"))
    }
}
