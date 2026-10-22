import XCTest
@testable import ReviewBot

final class PullRequestSearchTests: XCTestCase {
    func testOwnersAreDeduplicatedCaseInsensitivelyInConfiguredOrder() {
        let repositories = [
            repository("acme/widget"),
            repository("other/thing"),
            repository("ACME/gadget"),
            repository("no-slash"),
        ]
        XCTAssertEqual(PullRequestSearch.owners(of: repositories), ["acme", "other"])
    }

    func testResultsAreSplitByWatchedRepositoryAndTheRestDropped() throws {
        let results = try decode(
            #"""
            [
              {"number":1,"title":"a","url":"https://github.com/acme/widget/pull/1","repository":{"nameWithOwner":"acme/widget"}},
              {"number":2,"title":"b","url":"https://github.com/acme/elsewhere/pull/2","repository":{"nameWithOwner":"acme/elsewhere"}},
              {"number":3,"title":"c","url":"https://github.com/Acme/Gadget/pull/3"}
            ]
            """#
        )
        let grouped = PullRequestSearch.byRepository(
            results,
            watching: [repository("acme/widget"), repository("acme/gadget")]
        )
        XCTAssertEqual(grouped["acme/widget"]?.map(\.number), [1])
        // No `repository` field: the URL names it, and the case of a slug never matters.
        XCTAssertEqual(grouped["acme/gadget"]?.map(\.number), [3])
        XCTAssertNil(grouped["acme/elsewhere"])
    }

    func testOnlyARateLimitAnswerCountsAsOne() {
        XCTAssertTrue(PullRequestSearch.isRateLimited(failure(
            "HTTP 403: You have exceeded a secondary rate limit. Please wait a few minutes before you try again."
        )))
        XCTAssertTrue(PullRequestSearch.isRateLimited(failure("HTTP 403: API rate limit exceeded for user ID 1.")))
        XCTAssertFalse(PullRequestSearch.isRateLimited(failure("HTTP 404: Not Found")))
    }

    func testTheHoldDoublesFromFiveMinutesUpToAnHour() {
        let minutes = (1...7).map { PullRequestSearch.hold(afterConsecutiveLimits: $0) / 60 }
        XCTAssertEqual(minutes, [5, 10, 20, 40, 60, 60, 60])
        XCTAssertEqual(PullRequestSearch.hold(afterConsecutiveLimits: 1_000), PullRequestSearch.maximumHold)
    }

    func testTheSearchAsksForTheRepositoryOfEachResult() {
        let arguments = PullRequestSearch.openRequestArguments(owner: "acme")
        let json = arguments.firstIndex(of: "--json").map { arguments[$0 + 1] }
        XCTAssertTrue(json?.split(separator: ",").contains("repository") == true, arguments.joined(separator: " "))
        XCTAssertEqual(arguments.firstIndex(of: "--owner").map { arguments[$0 + 1] }, "acme")
    }

    private func repository(_ slug: String) -> RepositoryConfiguration {
        RepositoryConfiguration(name: slug, path: "/mock/\(slug)", githubSlug: slug)
    }

    private func decode(_ json: String) throws -> [PullRequestSummary] {
        try JSONDecoder().decode([PullRequestSummary].self, from: Data(json.utf8))
    }

    private func failure(_ stderr: String) -> CommandResult {
        CommandResult(command: "gh search prs", exitCode: 1, stdout: "", stderr: stderr)
    }
}
