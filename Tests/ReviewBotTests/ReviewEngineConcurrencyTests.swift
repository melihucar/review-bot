import XCTest
@testable import ReviewBot

/// A poll that discovers several review requests runs them at the same time, bounded
/// by `maxConcurrentReviews`. Both facts are asserted on an observed peak of
/// simultaneously-running reviewers, with the mock reviewers waiting for each other up
/// to a deadline — so a regression to sequential reviews fails in a few seconds rather
/// than hanging.
final class ReviewEngineConcurrencyTests: XCTestCase {
    func testPendingReviewsRunAtTheSameTime() async throws {
        let fixture = try ConcurrencyFixture(concurrency: 3)
        let runner = MultiPullRequestMock(pullRequests: [41, 42, 43], expectedPeak: 3)
        let engine = ReviewEngine(paths: fixture.paths, runner: runner)

        await engine.poll(configuration: fixture.configuration, onEvent: { _ in }, onStatus: { _ in })

        let peak = await runner.peakConcurrentReviewers()
        XCTAssertEqual(peak, 3, "Three pending reviews should have been in flight together")
        let posted = await runner.postedPullRequests()
        XCTAssertEqual(posted.sorted(), [41, 42, 43], "Every pull request should still be reviewed and posted")
    }

    func testConcurrencyLimitCapsHowManyRunTogether() async throws {
        let fixture = try ConcurrencyFixture(concurrency: 2)
        let runner = MultiPullRequestMock(pullRequests: [41, 42, 43], expectedPeak: 3)
        let engine = ReviewEngine(paths: fixture.paths, runner: runner)

        await engine.poll(configuration: fixture.configuration, onEvent: { _ in }, onStatus: { _ in })

        let peak = await runner.peakConcurrentReviewers()
        XCTAssertEqual(peak, 2, "The limit should hold the third review back until a slot frees")
        let posted = await runner.postedPullRequests()
        XCTAssertEqual(posted.sorted(), [41, 42, 43], "A capped queue still reviews everything")
    }

    func testAConcurrencyOfOneKeepsThePollSequential() async throws {
        let fixture = try ConcurrencyFixture(concurrency: 1)
        let runner = MultiPullRequestMock(pullRequests: [41, 42], expectedPeak: 2)
        let engine = ReviewEngine(paths: fixture.paths, runner: runner)

        await engine.poll(configuration: fixture.configuration, onEvent: { _ in }, onStatus: { _ in })

        let peak = await runner.peakConcurrentReviewers()
        XCTAssertEqual(peak, 1, "A limit of one is the old one-at-a-time behaviour")
        let posted = await runner.postedPullRequests()
        XCTAssertEqual(posted.sorted(), [41, 42])
    }

    func testTheGitStepsOfConcurrentReviewsDoNotInterleave() async throws {
        let fixture = try ConcurrencyFixture(concurrency: 3)
        let runner = MultiPullRequestMock(pullRequests: [41, 42, 43], expectedPeak: 3)
        let engine = ReviewEngine(paths: fixture.paths, runner: runner)

        await engine.poll(configuration: fixture.configuration, onEvent: { _ in }, onStatus: { _ in })

        // The reviews overlap, but they share one clone: a fetch or a `worktree add`
        // that ran while another review held the clone would race on git's ref locks.
        let peak = await runner.peakConcurrentClonewriters()
        XCTAssertEqual(peak, 1, "Concurrent reviews wrote to the same clone at the same time")
    }

    func testTheStatusLineReportsTheQueueRatherThanOnePullRequest() async throws {
        let fixture = try ConcurrencyFixture(concurrency: 3)
        let runner = MultiPullRequestMock(pullRequests: [41, 42, 43], expectedPeak: 3)
        let engine = ReviewEngine(paths: fixture.paths, runner: runner)
        let statuses = StatusLog()

        await engine.poll(
            configuration: fixture.configuration,
            onEvent: { _ in },
            onStatus: { await statuses.append($0) }
        )

        let seen = await statuses.snapshot()
        XCTAssertTrue(
            seen.contains("Reviewing 3 pull requests…"),
            "Expected a queue status, got: \(seen)"
        )
        XCTAssertTrue(
            seen.contains("Reviewed 3 of 3 pull requests…"),
            "Expected the queue's progress to be reported, got: \(seen)"
        )
        XCTAssertFalse(
            seen.contains(where: { $0.hasPrefix("Reviewing widget #") }),
            "Concurrent reviews should not fight over the status line: \(seen)"
        )
    }

    func testALoneReviewStillNarratesItself() async throws {
        let fixture = try ConcurrencyFixture(concurrency: 3)
        let runner = MultiPullRequestMock(pullRequests: [42], expectedPeak: 1)
        let engine = ReviewEngine(paths: fixture.paths, runner: runner)
        let statuses = StatusLog()

        await engine.poll(
            configuration: fixture.configuration,
            onEvent: { _ in },
            onStatus: { await statuses.append($0) }
        )

        let seen = await statuses.snapshot()
        XCTAssertTrue(seen.contains("Reviewing widget #42…"), "Expected per-PR status, got: \(seen)")
        XCTAssertFalse(
            seen.contains(where: { $0.hasPrefix("Reviewing 1 pull request") }),
            "One review needs no queue reporting: \(seen)"
        )
    }
}

private struct ConcurrencyFixture {
    let root: URL
    let paths: StoragePaths
    let configuration: ReviewBotConfiguration

    init(concurrency: Int) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReviewBotConcurrencyTests-\(UUID().uuidString)", isDirectory: true)
        paths = StoragePaths(root: root)
        try paths.prepare()
        configuration = ReviewBotConfiguration(
            repositories: [
                RepositoryConfiguration(name: "widget", path: "/mock/widget", githubSlug: "acme/widget"),
            ],
            pollIntervalMinutes: 15,
            isPaused: false,
            claude: ReviewerConfiguration(enabled: true, model: "claude-test", effort: .high),
            codex: ReviewerConfiguration(enabled: false, model: "codex-test", effort: .high),
            opencode: ReviewerConfiguration(enabled: false, model: "opencode-test", effort: .max),
            gemini: ReviewerConfiguration(enabled: false, model: "gemini-test", effort: .high),
            customPrompt: "",
            maxConcurrentReviews: concurrency
        )
    }
}

private actor StatusLog {
    private var values: [String] = []

    func append(_ value: String) { values.append(value) }
    func snapshot() -> [String] { values }
}

/// Serves any pull request number, and reports two peaks: how many reviewers ran at
/// once, and how many commands wrote to the shared clone at once.
private actor MultiPullRequestMock: CommandRunning {
    /// How many concurrent reviewers the mock waits for before letting the first one
    /// finish. When the engine cannot reach it — because the limit is lower, or because
    /// reviews are sequential — each reviewer returns on the deadline instead.
    private let expectedPeak: Int
    private var reviewersRunning = 0
    private var reviewerPeak = 0
    private var cloneWriters = 0
    private var cloneWriterPeak = 0
    private var posted: [Int] = []
    private let pullRequests: [Int]

    init(pullRequests: [Int], expectedPeak: Int) {
        self.pullRequests = pullRequests
        self.expectedPeak = expectedPeak
    }

    func peakConcurrentReviewers() -> Int { reviewerPeak }
    func peakConcurrentClonewriters() -> Int { cloneWriterPeak }
    func postedPullRequests() -> [Int] { posted }

    func run(
        _ executable: String,
        arguments: [String],
        currentDirectory: URL?,
        timeout: Int
    ) async throws -> CommandResult {
        if executable == "gh" {
            return try await runGitHub(arguments: arguments)
        }
        if executable == "git" {
            return try await runGit(arguments: arguments)
        }
        if executable == "claude" {
            return await runReviewer()
        }
        XCTFail("Unexpected command: \(executable) \(arguments.joined(separator: " "))")
        return result(exitCode: 127)
    }

    private func runReviewer() async -> CommandResult {
        reviewersRunning += 1
        reviewerPeak = max(reviewerPeak, reviewersRunning)
        // Hold the slot until every reviewer this test expects has started, so the peak
        // reflects what the engine allowed rather than how fast the mock returned.
        var waited = 0
        while reviewersRunning < expectedPeak, waited < 1_000 {
            try? await Task.sleep(for: .milliseconds(5))
            waited += 5
        }
        reviewersRunning -= 1
        return result(stdout: "## Summary\nFine.\n\nVERDICT: CLEAN\n")
    }

    /// Commands that write to the shared clone: their overlap is what the repository
    /// gate exists to prevent.
    private func runGit(arguments: [String]) async throws -> CommandResult {
        let writesToClone = arguments.contains("fetch")
            || (arguments.contains("worktree") && !arguments.contains("list"))
        guard writesToClone else {
            if arguments.contains("show") {
                return result(stdout: "Prefer small pull requests.\n")
            }
            if arguments.contains("rev-parse") {
                // The merge preview resolving the base branch's remote-tracking ref.
                return result(stdout: "aaaaaaaabbbbbbbb\n")
            }
            if arguments.contains("merge-base") {
                return result(stdout: "aaaaaaaabbbbbbbb\n")
            }
            if arguments.contains("rev-list") {
                // The base has not moved, so no merge preview is built.
                return result(stdout: "0\n")
            }
            XCTFail("Unexpected git command: \(arguments.joined(separator: " "))")
            return result(exitCode: 127)
        }

        cloneWriters += 1
        cloneWriterPeak = max(cloneWriterPeak, cloneWriters)
        // Suspend inside the "lock": an overlapping fetch would be counted here.
        try? await Task.sleep(for: .milliseconds(5))
        if arguments.contains("add"),
           let detachIndex = arguments.firstIndex(of: "--detach"),
           arguments.indices.contains(detachIndex + 1) {
            try FileManager.default.createDirectory(
                at: URL(fileURLWithPath: arguments[detachIndex + 1], isDirectory: true),
                withIntermediateDirectories: true
            )
        }
        cloneWriters -= 1
        return result()
    }

    private func runGitHub(arguments: [String]) async throws -> CommandResult {
        if arguments.starts(with: ["api", "user"]) {
            return result(stdout: "reviewer\n")
        }
        if arguments.starts(with: ["search", "prs"]) {
            let entries = pullRequests.map {
                #"{"number":\#($0),"title":"PR \#($0)","url":"https://github.com/acme/widget/pull/\#($0)"}"#
            }
            return result(stdout: "[\(entries.joined(separator: ","))]")
        }
        if arguments.starts(with: ["pr", "view"]), arguments.contains("--json") {
            let number = arguments[2]
            return result(
                stdout: #"{"title":"PR \#(number)","headRefOid":"head\#(number)000000","baseRefName":"main","baseRefOid":"base\#(number)000000","url":"https://github.com/acme/widget/pull/\#(number)"}"#
            )
        }
        if arguments.contains(where: { $0.hasSuffix("/timeline") }) {
            return result(stdout: "2026-07-15T10:00:00Z\n")
        }
        if arguments.starts(with: ["pr", "diff"]) {
            return result(stdout: "diff --git a/a.swift b/a.swift\n+let added = 1\n")
        }
        if arguments.starts(with: ["pr", "view"]), arguments.contains("--comments") {
            return result(stdout: "PR conversation")
        }
        if arguments.contains(where: { $0.hasSuffix("/reviews") }) {
            return result(stdout: "No prior reviews")
        }
        if arguments.contains(where: { $0.hasSuffix("/comments") }) {
            return result(stdout: "No inline comments")
        }
        if arguments.starts(with: ["pr", "review"]), let number = Int(arguments[2]) {
            posted.append(number)
            return result()
        }
        XCTFail("Unexpected gh command: \(arguments.joined(separator: " "))")
        return result(exitCode: 127)
    }

    private func result(
        exitCode: Int32 = 0,
        stdout: String = "",
        stderr: String = ""
    ) -> CommandResult {
        CommandResult(command: "mock", exitCode: exitCode, stdout: stdout, stderr: stderr)
    }
}
