import Foundation
import XCTest
@testable import ReviewBot

final class ReviewEngineFeatureTests: XCTestCase {
    func testCleanReviewRunsInWorktreeUsesRepositoryRulesAndPostsApproval() async throws {
        let fixture = try FeatureFixture()
        let runner = ReviewWorkflowMock()
        let engine = ReviewEngine(paths: fixture.paths, runner: runner)
        let recorder = EventRecorder()

        await engine.poll(
            configuration: fixture.configuration,
            onEvent: { entry in await recorder.append(entry) },
            onStatus: { _ in }
        )

        let events = await recorder.snapshot()
        let postCount = await runner.postCount()
        let postedBody = await runner.lastPostedBody()
        let claudePrompt = await runner.lastClaudePrompt()
        let sawPreparedDiff = await runner.sawPreparedDiffDuringReview()
        XCTAssertEqual(events.map(\.kind), [.requestDetected, .reviewStarted, .approved])
        XCTAssertEqual(postCount, 1)
        XCTAssertTrue(postedBody.contains("**Decision: Approved**"))
        XCTAssertTrue(claudePrompt.contains("Mandatory repository review rules"))
        XCTAssertTrue(claudePrompt.contains("Never approve an untested migration."))
        XCTAssertTrue(sawPreparedDiff)
    }

    func testAlreadyReviewedRequestIsNotRunOrPostedAgain() async throws {
        let fixture = try FeatureFixture()
        let runner = ReviewWorkflowMock()
        let engine = ReviewEngine(paths: fixture.paths, runner: runner)
        let recorder = EventRecorder()

        for _ in 0..<2 {
            await engine.poll(
                configuration: fixture.configuration,
                onEvent: { entry in await recorder.append(entry) },
                onStatus: { _ in }
            )
        }

        let postCount = await runner.postCount()
        let claudeCount = await runner.claudeCount()
        let events = await recorder.snapshot()
        XCTAssertEqual(postCount, 1)
        XCTAssertEqual(claudeCount, 1)
        XCTAssertEqual(events.filter { $0.kind == .requestDetected }.count, 1)
    }

    func testFailedPostIsRecordedAndRetriedOnNextPoll() async throws {
        let fixture = try FeatureFixture()
        let runner = ReviewWorkflowMock(failFirstPost: true)
        let engine = ReviewEngine(paths: fixture.paths, runner: runner)
        let recorder = EventRecorder()

        for _ in 0..<2 {
            await engine.poll(
                configuration: fixture.configuration,
                onEvent: { entry in await recorder.append(entry) },
                onStatus: { _ in }
            )
        }

        let events = await recorder.snapshot()
        let postCount = await runner.postCount()
        XCTAssertEqual(postCount, 2)
        XCTAssertTrue(events.contains(where: { $0.kind == .failed }))
        XCTAssertTrue(events.contains(where: { $0.kind == .approved }))
    }

    func testReviewerFailureIsNotPostedAndRetriedOnNextPoll() async throws {
        let fixture = try FeatureFixture()
        let runner = ReviewWorkflowMock(failCodex: true)
        let engine = ReviewEngine(paths: fixture.paths, runner: runner)
        let recorder = EventRecorder()
        var configuration = fixture.configuration
        configuration.claude.enabled = true
        configuration.codex.enabled = true

        for _ in 0..<2 {
            await engine.poll(
                configuration: configuration,
                onEvent: { entry in await recorder.append(entry) },
                onStatus: { _ in }
            )
        }

        let events = await recorder.snapshot()
        let postCount = await runner.postCount()
        let codexCount = await runner.codexCount()
        XCTAssertEqual(postCount, 0)
        XCTAssertEqual(codexCount, 2)
        XCTAssertTrue(events.contains(where: { $0.kind == .failed }))
        XCTAssertFalse(events.contains(where: {
            [.approved, .changesRequested, .commented].contains($0.kind)
        }))
    }

    func testDisagreementReconcilesAndOverturnsLoneShouldFix() async throws {
        let fixture = try FeatureFixture()
        let runner = ReviewWorkflowMock(
            claudeVerdict: .clean,
            codexVerdict: .shouldFix,
            reconciledVerdict: .clean
        )
        let engine = ReviewEngine(paths: fixture.paths, runner: runner)
        let recorder = EventRecorder()
        var configuration = fixture.configuration
        configuration.claude.enabled = true
        configuration.codex.enabled = true

        await engine.poll(
            configuration: configuration,
            onEvent: { entry in await recorder.append(entry) },
            onStatus: { _ in }
        )

        let events = await recorder.snapshot()
        let reconciliationCount = await runner.reconciliationCount()
        let postArgument = await runner.lastPostArgument()
        let postedBody = await runner.lastPostedBody()
        XCTAssertEqual(reconciliationCount, 1)
        XCTAssertEqual(postArgument, "--approve")
        XCTAssertEqual(events.last?.kind, .approved)
        XCTAssertTrue(postedBody.contains("reconciled the findings"))
    }

    func testDisagreementReconcilesAndUpholdsShouldFix() async throws {
        let fixture = try FeatureFixture()
        let runner = ReviewWorkflowMock(
            claudeVerdict: .clean,
            codexVerdict: .shouldFix,
            reconciledVerdict: .shouldFix
        )
        let engine = ReviewEngine(paths: fixture.paths, runner: runner)
        let recorder = EventRecorder()
        var configuration = fixture.configuration
        configuration.claude.enabled = true
        configuration.codex.enabled = true

        await engine.poll(
            configuration: configuration,
            onEvent: { entry in await recorder.append(entry) },
            onStatus: { _ in }
        )

        let events = await recorder.snapshot()
        let reconciliationCount = await runner.reconciliationCount()
        let postArgument = await runner.lastPostArgument()
        XCTAssertEqual(reconciliationCount, 1)
        XCTAssertEqual(postArgument, "--request-changes")
        XCTAssertEqual(events.last?.kind, .changesRequested)
    }

    func testAgreingReviewersDoNotTriggerReconciliation() async throws {
        let fixture = try FeatureFixture()
        let runner = ReviewWorkflowMock(claudeVerdict: .clean, codexVerdict: .clean)
        let engine = ReviewEngine(paths: fixture.paths, runner: runner)
        let recorder = EventRecorder()
        var configuration = fixture.configuration
        configuration.claude.enabled = true
        configuration.codex.enabled = true

        await engine.poll(
            configuration: configuration,
            onEvent: { entry in await recorder.append(entry) },
            onStatus: { _ in }
        )

        let reconciliationCount = await runner.reconciliationCount()
        let postArgument = await runner.lastPostArgument()
        XCTAssertEqual(reconciliationCount, 0)
        XCTAssertEqual(postArgument, "--approve")
    }

    func testCodexOnlyShouldFixVerdictRequestsChanges() async throws {
        let fixture = try FeatureFixture()
        let runner = ReviewWorkflowMock(codexVerdict: .shouldFix)
        let engine = ReviewEngine(paths: fixture.paths, runner: runner)
        let recorder = EventRecorder()
        var configuration = fixture.configuration
        configuration.claude.enabled = false
        configuration.codex.enabled = true

        await engine.poll(
            configuration: configuration,
            onEvent: { entry in await recorder.append(entry) },
            onStatus: { _ in }
        )

        let events = await recorder.snapshot()
        let claudeCount = await runner.claudeCount()
        let codexCount = await runner.codexCount()
        let postArgument = await runner.lastPostArgument()
        XCTAssertEqual(claudeCount, 0)
        XCTAssertEqual(codexCount, 1)
        XCTAssertEqual(postArgument, "--request-changes")
        XCTAssertEqual(events.last?.kind, .changesRequested)
    }

    func testPolicyBlockingOnNitsRequestsChanges() async throws {
        let fixture = try FeatureFixture()
        let runner = ReviewWorkflowMock(codexVerdict: .nitsOnly)
        let engine = ReviewEngine(paths: fixture.paths, runner: runner)
        let recorder = EventRecorder()
        var configuration = fixture.configuration
        configuration.claude.enabled = false
        configuration.codex.enabled = true
        configuration.decisionPolicy = DecisionPolicy(
            shouldFix: .requestChanges,
            nitsOnly: .requestChanges,
            clean: .approve
        )

        await engine.poll(
            configuration: configuration,
            onEvent: { entry in await recorder.append(entry) },
            onStatus: { _ in }
        )

        let events = await recorder.snapshot()
        let postArgument = await runner.lastPostArgument()
        XCTAssertEqual(postArgument, "--request-changes")
        XCTAssertEqual(events.last?.kind, .changesRequested)
    }

    func testPolicyApprovingShouldFixApproves() async throws {
        let fixture = try FeatureFixture()
        let runner = ReviewWorkflowMock(codexVerdict: .shouldFix)
        let engine = ReviewEngine(paths: fixture.paths, runner: runner)
        let recorder = EventRecorder()
        var configuration = fixture.configuration
        configuration.claude.enabled = false
        configuration.codex.enabled = true
        configuration.decisionPolicy = DecisionPolicy(
            shouldFix: .approve,
            nitsOnly: .approve,
            clean: .approve
        )

        await engine.poll(
            configuration: configuration,
            onEvent: { entry in await recorder.append(entry) },
            onStatus: { _ in }
        )

        let events = await recorder.snapshot()
        let postArgument = await runner.lastPostArgument()
        XCTAssertEqual(postArgument, "--approve")
        XCTAssertEqual(events.last?.kind, .approved)
    }

    func testIncrementalScopeDiffsAgainstLastReviewedHead() async throws {
        let fixture = try FeatureFixture()
        // A prior review recorded an earlier head; the mock's current head is 1234567890abcdef.
        let priorHeads = LastReviewedStore(paths: fixture.paths)
        priorHeads.record("acme/widget#42", head: "0000oldhead0000")

        let runner = ReviewWorkflowMock()
        let engine = ReviewEngine(paths: fixture.paths, runner: runner)
        let recorder = EventRecorder()
        var configuration = fixture.configuration
        configuration.reviewScope = .incremental

        await engine.poll(
            configuration: configuration,
            onEvent: { entry in await recorder.append(entry) },
            onStatus: { _ in }
        )

        let incrementalArgs = await runner.incrementalDiffInvocation()
        let incremental = try XCTUnwrap(incrementalArgs)
        let usedGhDiff = await runner.didCallGhPrDiff()
        XCTAssertEqual(Array(incremental.suffix(2)), ["0000oldhead0000", "1234567890abcdef"])
        XCTAssertFalse(usedGhDiff, "Incremental review should not download the full PR diff")
    }

    func testIncrementalScopeFallsBackToFullDiffWithoutPriorHead() async throws {
        let fixture = try FeatureFixture()
        let runner = ReviewWorkflowMock()
        let engine = ReviewEngine(paths: fixture.paths, runner: runner)
        let recorder = EventRecorder()
        var configuration = fixture.configuration
        configuration.reviewScope = .incremental

        await engine.poll(
            configuration: configuration,
            onEvent: { entry in await recorder.append(entry) },
            onStatus: { _ in }
        )

        let incremental = await runner.incrementalDiffInvocation()
        let usedGhDiff = await runner.didCallGhPrDiff()
        XCTAssertNil(incremental, "With no prior review there is nothing to diff incrementally against")
        XCTAssertTrue(usedGhDiff, "First review of a PR should use the full PR diff")
    }
}

private struct FeatureFixture {
    let root: URL
    let paths: StoragePaths
    let configuration: ReviewBotConfiguration

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReviewBotFeatureTests-\(UUID().uuidString)", isDirectory: true)
        paths = StoragePaths(root: root)
        try paths.prepare()
        configuration = ReviewBotConfiguration(
            repositories: [
                RepositoryConfiguration(
                    name: "widget",
                    path: "/mock/widget",
                    githubSlug: "acme/widget"
                ),
            ],
            pollIntervalMinutes: 15,
            isPaused: false,
            claude: ReviewerConfiguration(enabled: true, model: "claude-test", effort: .high),
            codex: ReviewerConfiguration(enabled: false, model: "codex-test", effort: .high),
            customPrompt: "Check public API compatibility."
        )
    }
}

private actor EventRecorder {
    private var entries: [HistoryEntry] = []

    func append(_ entry: HistoryEntry) { entries.append(entry) }
    func snapshot() -> [HistoryEntry] { entries }
}

private actor ReviewWorkflowMock: CommandRunning {
    private var posts = 0
    private var claudeRuns = 0
    private var codexRuns = 0
    private var reconciliationRuns = 0
    private var postedBody = ""
    private var postArgument = ""
    private var claudePrompt = ""
    private var preparedDiffSeen = false
    private var ghPrDiffCalled = false
    private var incrementalDiffArgs: [String]?
    private let failFirstPost: Bool
    private let claudeVerdict: ReviewVerdict
    private let codexVerdict: ReviewVerdict
    private let reconciledVerdict: ReviewVerdict?
    private let failCodex: Bool

    init(
        failFirstPost: Bool = false,
        claudeVerdict: ReviewVerdict = .clean,
        codexVerdict: ReviewVerdict = .clean,
        reconciledVerdict: ReviewVerdict? = nil,
        failCodex: Bool = false
    ) {
        self.failFirstPost = failFirstPost
        self.claudeVerdict = claudeVerdict
        self.codexVerdict = codexVerdict
        self.reconciledVerdict = reconciledVerdict
        self.failCodex = failCodex
    }

    func run(
        _ executable: String,
        arguments: [String],
        currentDirectory: URL?,
        timeout: Int
    ) async throws -> CommandResult {
        if executable == "gh", arguments.starts(with: ["api", "user"]) {
            return result(stdout: "reviewer\n")
        }
        if executable == "gh", arguments.starts(with: ["search", "prs"]) {
            return result(stdout: #"[{"number":42,"title":"Improve widgets","url":"https://github.com/acme/widget/pull/42"}]"#)
        }
        if executable == "gh", arguments.starts(with: ["pr", "view", "42"]),
           arguments.contains("--json") {
            return result(stdout: #"{"title":"Improve widgets","headRefOid":"1234567890abcdef","baseRefName":"main","baseRefOid":"abcdef1234567890","url":"https://github.com/acme/widget/pull/42"}"#)
        }
        if executable == "gh", arguments.contains("repos/acme/widget/issues/42/timeline") {
            return result(stdout: "2026-07-15T10:00:00Z\n")
        }
        if executable == "git", arguments.contains("fetch") {
            return result()
        }
        if executable == "git", arguments.contains("worktree"), arguments.contains("add") {
            if let detachIndex = arguments.firstIndex(of: "--detach"),
               arguments.indices.contains(detachIndex + 1) {
                let directory = URL(fileURLWithPath: arguments[detachIndex + 1], isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            return result()
        }
        if executable == "git", arguments.contains("show") {
            return result(stdout: "Never approve an untested migration.\n")
        }
        if executable == "git", arguments.contains("cat-file") {
            // The prior-reviewed commit is present locally.
            return result()
        }
        if executable == "git", arguments.contains("diff") {
            incrementalDiffArgs = arguments
            return result(stdout: "diff --git a/incremental.swift b/incremental.swift\n")
        }
        if executable == "gh", arguments.starts(with: ["pr", "diff", "42"]) {
            ghPrDiffCalled = true
            return result(stdout: "diff --git a/a.swift b/a.swift\n")
        }
        if executable == "gh", arguments.starts(with: ["pr", "view", "42"]),
           arguments.contains("--comments") {
            return result(stdout: "PR conversation")
        }
        if executable == "gh", arguments.contains("repos/acme/widget/pulls/42/reviews") {
            return result(stdout: "No prior reviews")
        }
        if executable == "gh", arguments.contains("repos/acme/widget/pulls/42/comments") {
            return result(stdout: "No inline comments")
        }
        if executable == "claude" {
            let prompt = arguments.firstIndex(of: "-p").flatMap { index in
                arguments.indices.contains(index + 1) ? arguments[index + 1] : nil
            } ?? ""
            if prompt.contains("reconciling two independent automated reviews") {
                reconciliationRuns += 1
                let verdict = reconciledVerdict ?? .clean
                return result(stdout: "## Reconciliation\nRe-checked findings.\n\nVERDICT: \(verdict.rawValue)\n")
            }
            claudeRuns += 1
            claudePrompt = prompt
            if let currentDirectory {
                preparedDiffSeen = FileManager.default.fileExists(
                    atPath: currentDirectory.appendingPathComponent(".review-bot-diff.patch").path
                )
            }
            return result(stdout: "## Summary\nLooks safe.\n\nVERDICT: \(claudeVerdict.rawValue)\n")
        }
        if executable == "codex" {
            codexRuns += 1
            if failCodex {
                return result(exitCode: 1, stderr: "simulated codex failure")
            }
            if let outputIndex = arguments.firstIndex(of: "-o"),
               arguments.indices.contains(outputIndex + 1) {
                let output = "## Summary\nCodex result.\n\nVERDICT: \(codexVerdict.rawValue)\n"
                try Data(output.utf8).write(
                    to: URL(fileURLWithPath: arguments[outputIndex + 1]),
                    options: .atomic
                )
            }
            return result()
        }
        if executable == "gh", arguments.starts(with: ["pr", "review", "42"]) {
            posts += 1
            postArgument = arguments.first(where: {
                ["--approve", "--request-changes", "--comment"].contains($0)
            }) ?? ""
            if let bodyIndex = arguments.firstIndex(of: "--body-file"),
               arguments.indices.contains(bodyIndex + 1) {
                postedBody = (try? String(contentsOfFile: arguments[bodyIndex + 1], encoding: .utf8)) ?? ""
            }
            if failFirstPost, posts == 1 {
                return result(exitCode: 1, stderr: "simulated post failure")
            }
            return result()
        }
        if executable == "git", arguments.contains("remove") {
            return result()
        }
        if executable == "git", arguments.contains("prune") {
            return result()
        }

        XCTFail("Unexpected command: \(executable) \(arguments.joined(separator: " "))")
        return result(exitCode: 127, stderr: "unexpected command")
    }

    func postCount() -> Int { posts }
    func claudeCount() -> Int { claudeRuns }
    func codexCount() -> Int { codexRuns }
    func reconciliationCount() -> Int { reconciliationRuns }
    func lastPostedBody() -> String { postedBody }
    func lastPostArgument() -> String { postArgument }
    func lastClaudePrompt() -> String { claudePrompt }
    func sawPreparedDiffDuringReview() -> Bool { preparedDiffSeen }
    func didCallGhPrDiff() -> Bool { ghPrDiffCalled }
    func incrementalDiffInvocation() -> [String]? { incrementalDiffArgs }

    private func result(
        exitCode: Int32 = 0,
        stdout: String = "",
        stderr: String = ""
    ) -> CommandResult {
        CommandResult(
            command: "mock",
            exitCode: exitCode,
            stdout: stdout,
            stderr: stderr
        )
    }
}
