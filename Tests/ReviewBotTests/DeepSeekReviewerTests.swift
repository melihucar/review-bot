import Foundation
import XCTest
@testable import ReviewBot

final class DeepSeekReviewerTests: XCTestCase {
    private var worktree: URL!

    private let finalReview = """
    ## Summary
    The change is safe.

    VERDICT: CLEAN
    """

    override func setUpWithError() throws {
        worktree = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReviewBotDeepSeek-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        try write("diff --git a/Widget.swift b/Widget.swift\n+let answer = 42\n", to: ".review-bot-diff.patch")
        try write("## Pull request and conversation\n\nLooks good to me.\n", to: ".review-bot-thread.md")
        try write("let answer = 42\n", to: "Widget.swift")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: worktree)
    }

    private func write(_ contents: String, to relativePath: String) throws {
        try Data(contents.utf8).write(
            to: worktree.appendingPathComponent(relativePath),
            options: .atomic
        )
    }

    func testOpeningMessageCarriesTheContractDiffAndThread() async throws {
        let client = StubChatClient([.message(finalReview)])
        let reviewer = DeepSeekReviewer(client: client, model: "deepseek-chat")

        _ = try await reviewer.review(
            prompt: "REVIEW CONTRACT",
            worktree: worktree,
            apiKey: "sk-test"
        )

        let requests = await client.recordedRequests()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].messages.first?.role, .system)
        XCTAssertEqual(requests[0].messages.first?.content, "REVIEW CONTRACT")

        let opening = requests[0].messages.last?.content ?? ""
        XCTAssertTrue(opening.contains("let answer = 42"), "the diff should be inlined")
        XCTAssertTrue(opening.contains("Looks good to me."), "the thread should be inlined")
        XCTAssertNotNil(requests[0].tools, "the first attempt should offer the read-only tools")
    }

    /// The review contract grants the scope gate exactly one exception — a defect that appears
    /// only once the PR merges — and rests it on `.review-bot-merge.md`. The other reviewers open
    /// that file themselves; DeepSeek must be handed it, because on the no-tools path there is
    /// nothing to open it with.
    func testTheMergePreviewIsInlinedAlongsideTheDiffAndThread() async throws {
        try write(
            "# Merge preview\n\n`develop` has moved 2 commits ahead.\n\nChanged on both sides:\n- `Widget.swift`\n",
            to: ".review-bot-merge.md"
        )
        let client = StubChatClient([.message(finalReview)])
        let reviewer = DeepSeekReviewer(client: client, model: "deepseek-chat")

        _ = try await reviewer.review(
            prompt: "REVIEW CONTRACT",
            worktree: worktree,
            apiKey: "sk-test"
        )

        let requests = await client.recordedRequests()
        let opening = requests[0].messages.last?.content ?? ""
        XCTAssertTrue(opening.contains("--- BEGIN .review-bot-merge.md ---"))
        XCTAssertTrue(opening.contains("has moved 2 commits ahead"))
    }

    /// The file is absent whenever the base has not moved, and the engine writes it best-effort,
    /// so "not mentioned" is ambiguous in exactly the direction that matters: a model told to
    /// substantiate a merge finding from evidence it never received.
    func testAnAbsentMergePreviewIsStatedRatherThanLeftUnmentioned() async throws {
        let client = StubChatClient([.message(finalReview)])
        let reviewer = DeepSeekReviewer(client: client, model: "deepseek-chat")

        _ = try await reviewer.review(
            prompt: "REVIEW CONTRACT",
            worktree: worktree,
            apiKey: "sk-test"
        )

        let requests = await client.recordedRequests()
        let opening = requests[0].messages.last?.content ?? ""
        XCTAssertTrue(opening.contains("There is no `.review-bot-merge.md` in this worktree"))
        XCTAssertFalse(opening.contains("--- BEGIN .review-bot-merge.md ---"))
    }

    func testToolCallsAreExecutedInTheWorktreeAndFedBack() async throws {
        let client = StubChatClient([
            .toolCall(id: "call-1", name: "read_file", arguments: #"{"path": "Widget.swift"}"#),
            .message(finalReview),
        ])
        let reviewer = DeepSeekReviewer(client: client, model: "deepseek-chat")

        let output = try await reviewer.review(
            prompt: "REVIEW CONTRACT",
            worktree: worktree,
            apiKey: "sk-test"
        ).text

        XCTAssertEqual(output, finalReview)

        let requests = await client.recordedRequests()
        XCTAssertEqual(requests.count, 2)
        let toolResults = requests[1].messages.filter { $0.role == .tool }
        XCTAssertEqual(toolResults.count, 1)
        XCTAssertEqual(toolResults.first?.toolCallID, "call-1")
        XCTAssertTrue(toolResults.first?.content?.contains("1\tlet answer = 42") == true)
    }

    func testToolCallEscapingTheWorktreeIsRefusedWithoutFailingTheReview() async throws {
        let client = StubChatClient([
            .toolCall(id: "call-1", name: "read_file", arguments: #"{"path": "/etc/hosts"}"#),
            .message(finalReview),
        ])
        let reviewer = DeepSeekReviewer(client: client, model: "deepseek-chat")

        let output = try await reviewer.review(
            prompt: "REVIEW CONTRACT",
            worktree: worktree,
            apiKey: "sk-test"
        ).text

        XCTAssertEqual(output, finalReview)
        let requests = await client.recordedRequests()
        let refusal = requests[1].messages.first { $0.role == .tool }?.content ?? ""
        XCTAssertTrue(refusal.hasPrefix("Error:"))
        XCTAssertTrue(refusal.contains("outside the review worktree"))
    }

    func testModelsThatRejectToolsFallBackToASingleShotReview() async throws {
        let client = StubChatClient([
            .failure(ChatCompletionError.toolsUnsupported(model: "deepseek-reasoner")),
            .message(finalReview),
        ])
        let reviewer = DeepSeekReviewer(client: client, model: "deepseek-reasoner")

        let output = try await reviewer.review(
            prompt: "REVIEW CONTRACT",
            worktree: worktree,
            apiKey: "sk-test"
        ).text

        XCTAssertEqual(output, finalReview)
        let requests = await client.recordedRequests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertNotNil(requests[0].tools)
        XCTAssertNil(requests[1].tools, "the retry must not offer tools")
        // The fallback still has the diff, because it is inlined in the opening message.
        XCTAssertTrue(requests[1].messages.last?.content?.contains("let answer = 42") == true)
    }

    /// The fallback runs with `tools: nil`, so the opening message has to be rebuilt: the version
    /// written for the first attempt tells the model to call `read_file`, `search`, and
    /// `list_files`, and points it at `read_file` to continue past a truncated section. Repeating
    /// that here describes capabilities the model has just been denied.
    func testTheNoToolsAttemptIsNotToldToCallTools() async throws {
        let client = StubChatClient([
            .failure(ChatCompletionError.toolsUnsupported(model: "deepseek-reasoner")),
            .message(finalReview),
        ])
        let reviewer = DeepSeekReviewer(client: client, model: "deepseek-reasoner")

        _ = try await reviewer.review(
            prompt: "REVIEW CONTRACT",
            worktree: worktree,
            apiKey: "sk-test"
        )

        let requests = await client.recordedRequests()
        let withTools = requests[0].messages.last?.content ?? ""
        let withoutTools = requests[1].messages.last?.content ?? ""

        XCTAssertTrue(withTools.contains("read_file"))
        XCTAssertFalse(
            withoutTools.contains("read_file"),
            "the no-tools attempt must not name a tool it cannot call"
        )
        XCTAssertTrue(withoutTools.contains("You have no tools on this attempt"))
    }

    /// The round cap counts calls, not time: sixteen slow rounds can outlast every CLI reviewer in
    /// the panel. Running out of budget must end the same way running out of rounds does — with
    /// the review asked for — rather than by throwing away a dozen paid rounds of reading.
    func testTheWallClockBudgetStopsInvestigatingRatherThanFailing() async throws {
        let client = StubChatClient([
            .toolCall(id: "c1", name: "read_file", arguments: #"{"path": "Widget.swift"}"#),
            .message(finalReview),
        ])
        let reviewer = DeepSeekReviewer(
            client: client,
            model: "deepseek-chat",
            toolRounds: 16,
            reviewSeconds: 0
        )

        let output = try await reviewer.review(
            prompt: "REVIEW CONTRACT",
            worktree: worktree,
            apiKey: "sk-test"
        ).text

        XCTAssertEqual(output, finalReview)
        let requests = await client.recordedRequests()
        XCTAssertEqual(requests.count, 2, "an exhausted budget must not spend another tool round")
        XCTAssertNil(requests[1].tools)
        XCTAssertTrue(requests[1].messages.last?.content?.contains("Stop investigating") == true)
    }

    /// The meter is what makes a *cancelled* loop's spend visible. `ReviewEngine` races this
    /// review against a hard stop and drops the task when the stop wins, so nothing the loop
    /// throws — `PartialSpendFailure` included — is ever seen; the meter is the caller's own
    /// object and survives that. Asserted through a failing loop because cancelling one on a
    /// wall-clock deadline would mean waiting out the deadline; what matters either way is that
    /// each billed round has reached the meter by the time the round ends.
    func testTheSpendMeterSeesEachRoundAsItIsBilled() async throws {
        let client = StubChatClient(
            [
                .toolCall(id: "c1", name: "read_file", arguments: #"{"path": "Widget.swift"}"#),
                .failure(ChatCompletionError.timedOut(seconds: 180)),
            ],
            usagePerReply: TokenUsage(inputTokens: 1_000, outputTokens: 100, requests: 1)
        )
        let meter = DeepSeekReviewer.SpendMeter()
        let reviewer = DeepSeekReviewer(client: client, model: "deepseek-chat")

        let empty = await meter.total()
        XCTAssertNil(empty, "nothing billed yet must read as no cost, not as a cost of zero")

        do {
            _ = try await reviewer.review(
                prompt: "REVIEW CONTRACT",
                worktree: worktree,
                apiKey: "sk-test",
                meter: meter
            )
            XCTFail("The timeout should not be swallowed")
        } catch {
            // Bound before asserting: XCTUnwrap takes an @autoclosure, which cannot carry `await`.
            let total = await meter.total()
            let spent = try XCTUnwrap(total, "the completed round was billed")
            XCTAssertEqual(spent.requests, 1)
            XCTAssertEqual(spent.inputTokens, 1_000)
            XCTAssertEqual(spent.outputTokens, 100)
        }
    }

    /// A loop can spend a dozen paid rounds and fail on the last call. A thrown error carries no
    /// usage, so the engine recorded a review that cost real money as free — and then retried it,
    /// spending it again on top of a total that never showed the first attempt.
    func testAFailureAfterPaidRoundsCarriesWhatItAlreadySpent() async throws {
        let client = StubChatClient(
            [
                .toolCall(id: "c1", name: "read_file", arguments: #"{"path": "Widget.swift"}"#),
                .failure(ChatCompletionError.http(status: 500, message: "internal error")),
            ],
            usagePerReply: TokenUsage(inputTokens: 1_000, outputTokens: 100, requests: 1)
        )
        let reviewer = DeepSeekReviewer(
            client: client,
            model: "deepseek-chat",
            pricing: TokenPricing.deepSeekDefault
        )

        do {
            _ = try await reviewer.review(
                prompt: "REVIEW CONTRACT",
                worktree: worktree,
                apiKey: "sk-test"
            )
            XCTFail("The provider failure should not be swallowed")
        } catch {
            // It still renders as the failure it wraps, so the disclosure posted to GitHub and
            // every `ReviewerFailureClass.classify` marker are unaffected by the wrapping.
            XCTAssertTrue(error.localizedDescription.contains("500"))

            let outcome = DeepSeekReviewer.outcome(of: error)
            XCTAssertTrue(outcome.error is ChatCompletionError)
            let spent = try XCTUnwrap(outcome.usage, "the paid round must survive the failure")
            XCTAssertEqual(spent.requests, 1)
            XCTAssertEqual(spent.inputTokens, 1_000)
            XCTAssertNotNil(spent.costUSD, "partial spend is priced like a completed review")
        }
    }

    /// DeepSeek is not a child process, so `ProcessRunner`'s alarm never fires for it and the
    /// engine has to set `ReviewerResult.timedOut` itself. That only works if the timeout is still
    /// recognisable after the spend wrapper has been put around it.
    func testATimeoutStaysRecognisableThroughThePartialSpendWrapper() async throws {
        let client = StubChatClient(
            [
                .toolCall(id: "c1", name: "read_file", arguments: #"{"path": "Widget.swift"}"#),
                .failure(ChatCompletionError.timedOut(seconds: 180)),
            ],
            usagePerReply: TokenUsage(inputTokens: 500, outputTokens: 50, requests: 1)
        )
        let reviewer = DeepSeekReviewer(client: client, model: "deepseek-chat")

        do {
            _ = try await reviewer.review(
                prompt: "REVIEW CONTRACT",
                worktree: worktree,
                apiKey: "sk-test"
            )
            XCTFail("A provider timeout should not be swallowed")
        } catch {
            let outcome = DeepSeekReviewer.outcome(of: error)
            let chatError = try XCTUnwrap(outcome.error as? ChatCompletionError)
            guard case .timedOut = chatError else {
                return XCTFail("the timeout must not be flattened into a generic failure")
            }
            XCTAssertEqual(outcome.usage?.requests, 1)
        }
    }

    /// The text DeepSeek actually posted to fizbot-x-infra#66: its investigation monologue,
    /// emitted on a turn with no tool calls, which the old loop mistook for the finished review.
    private let narration = """
    Now let me verify one more thing — the `2>/dev/null` on line 41 is important. Let me think.

    Actually, let me look closer at the patterns.

    I'm confident this is clean.
    """

    func testNarrationOnATurnWithoutToolCallsIsNotPostedAsTheReview() async throws {
        let client = StubChatClient([.message(narration), .message(finalReview)])
        let reviewer = DeepSeekReviewer(client: client, model: "deepseek-chat")

        let output = try await reviewer.review(
            prompt: "REVIEW CONTRACT",
            worktree: worktree,
            apiKey: "sk-test"
        ).text

        // An absent tool call does not mean the model is done — it writes reasoning into the same
        // field as its answer, so the review has to be asked for rather than inferred.
        XCTAssertEqual(output, finalReview)
        XCTAssertFalse(output.contains("Now let me verify"))

        let requests = await client.recordedRequests()
        XCTAssertEqual(requests.count, 2, "the review must be requested explicitly")
        XCTAssertNil(requests[1].tools, "the final request must not offer tools")
        XCTAssertTrue(
            requests[1].messages.last?.content?.contains("Stop investigating") == true,
            "the final request must restate the required structure"
        )
        XCTAssertTrue(
            requests[1].messages.contains { $0.content == narration },
            "the discarded narration stays in context as history the model can draw on"
        )
    }

    func testAConformingReviewIsAcceptedWithoutAnExtraRoundTrip() async throws {
        let client = StubChatClient([.message(finalReview)])
        let reviewer = DeepSeekReviewer(client: client, model: "deepseek-chat")

        let output = try await reviewer.review(
            prompt: "REVIEW CONTRACT",
            worktree: worktree,
            apiKey: "sk-test"
        ).text

        XCTAssertEqual(output, finalReview)
        let requests = await client.recordedRequests()
        XCTAssertEqual(requests.count, 1, "no extra call when the model already produced the review")
    }

    func testExhaustedToolRoundsStillEndInAnExplicitReviewRequest() async throws {
        let client = StubChatClient([
            .toolCall(id: "c1", name: "read_file", arguments: #"{"path": "Widget.swift"}"#),
            .message(finalReview),
        ])
        let reviewer = DeepSeekReviewer(client: client, model: "deepseek-chat", toolRounds: 1)

        let output = try await reviewer.review(
            prompt: "REVIEW CONTRACT",
            worktree: worktree,
            apiKey: "sk-test"
        ).text

        XCTAssertEqual(output, finalReview)
        let requests = await client.recordedRequests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertNil(requests[1].tools)
        XCTAssertTrue(requests[1].messages.last?.content?.contains("Stop investigating") == true)
    }

    func testHeadingVariantsThatPreviouslyDefeatedTheTrim() {
        // Requiring the heading to sit alone on its line meant a single trailing colon left the
        // whole monologue in the posted review.
        for variant in [
            "## Summary:",
            "### Summary",
            "## **Summary**",
            "**## Summary**",
            "##Summary",
            "## Summary of changes",
        ] {
            let trimmed = DeepSeekReviewer.trimmedToContract(
                "narration here\n\n\(variant)\n\nFine.\n\nVERDICT: CLEAN"
            )
            XCTAssertFalse(
                trimmed.contains("narration here"),
                "the trim should anchor on \(variant)"
            )
            XCTAssertTrue(DeepSeekReviewer.followsContract(trimmed))
        }
    }

    func testFollowsContractRejectsPureNarration() {
        XCTAssertFalse(DeepSeekReviewer.followsContract(narration))
        XCTAssertFalse(DeepSeekReviewer.followsContract("I'm confident this is clean."))
        XCTAssertTrue(DeepSeekReviewer.followsContract(finalReview))
    }

    func testUsageIsAccumulatedAcrossEveryCallInTheLoop() async throws {
        let client = StubChatClient(
            [
                .toolCall(id: "c1", name: "read_file", arguments: #"{"path": "Widget.swift"}"#),
                .message(finalReview),
            ],
            usagePerReply: TokenUsage(
                inputTokens: 100,
                cachedInputTokens: 40,
                outputTokens: 10,
                requests: 1
            )
        )
        let reviewer = DeepSeekReviewer(client: client, model: "deepseek-chat")

        let usage = try await reviewer.review(
            prompt: "REVIEW CONTRACT",
            worktree: worktree,
            apiKey: "sk-test"
        ).usage

        // A DeepSeek review is many calls, so per-review spend is only right if all of them count.
        XCTAssertEqual(usage.requests, 2)
        XCTAssertEqual(usage.inputTokens, 200)
        XCTAssertEqual(usage.cachedInputTokens, 80)
        XCTAssertEqual(usage.outputTokens, 20)
        XCTAssertEqual(usage.totalTokens, 300)
    }

    func testCostIsComputedFromConfiguredPricing() async throws {
        let client = StubChatClient(
            [.message(finalReview)],
            usagePerReply: TokenUsage(
                inputTokens: 1_000_000,
                cachedInputTokens: 1_000_000,
                outputTokens: 1_000_000,
                requests: 1
            )
        )
        let pricing = TokenPricing(
            inputPerMillion: 1,
            cachedInputPerMillion: 0.25,
            outputPerMillion: 4
        )
        let reviewer = DeepSeekReviewer(
            client: client,
            model: "deepseek-chat",
            pricing: pricing
        )

        let usage = try await reviewer.review(
            prompt: "REVIEW CONTRACT",
            worktree: worktree,
            apiKey: "sk-test"
        ).usage

        XCTAssertEqual(usage.costUSD ?? 0, 5.25, accuracy: 0.0001)
        XCTAssertEqual(usage.costSummary, "$5.25")
    }

    func testCostIsUnknownRatherThanZeroWhenNoPriceIsConfigured() async throws {
        let client = StubChatClient(
            [.message(finalReview)],
            usagePerReply: TokenUsage(inputTokens: 500, outputTokens: 50, requests: 1)
        )
        let reviewer = DeepSeekReviewer(client: client, model: "deepseek-chat", pricing: nil)

        let usage = try await reviewer.review(
            prompt: "REVIEW CONTRACT",
            worktree: worktree,
            apiKey: "sk-test"
        ).usage

        // Reporting "$0.00" for an unpriced model would understate real spend.
        XCTAssertNil(usage.costUSD)
        XCTAssertNil(usage.costSummary)
        XCTAssertEqual(usage.totalTokens, 550)
    }

    func testZeroPricingReportsTokensWithoutACost() async throws {
        let client = StubChatClient(
            [.message(finalReview)],
            usagePerReply: TokenUsage(inputTokens: 500, outputTokens: 50, requests: 1)
        )
        let reviewer = DeepSeekReviewer(
            client: client,
            model: "deepseek-chat",
            pricing: TokenPricing(
                inputPerMillion: 0,
                cachedInputPerMillion: 0,
                outputPerMillion: 0
            )
        )

        let usage = try await reviewer.review(
            prompt: "REVIEW CONTRACT",
            worktree: worktree,
            apiKey: "sk-test"
        ).usage

        XCTAssertNil(usage.costUSD)
        XCTAssertEqual(usage.inputTokens, 500)
    }

    func testUsageStillCountsCallsWhenTheProviderReportsNone() async throws {
        let client = StubChatClient([.message(finalReview)], usagePerReply: nil)
        let reviewer = DeepSeekReviewer(client: client, model: "deepseek-chat")

        let usage = try await reviewer.review(
            prompt: "REVIEW CONTRACT",
            worktree: worktree,
            apiKey: "sk-test"
        ).usage

        XCTAssertEqual(usage.requests, 1)
        XCTAssertEqual(usage.totalTokens, 0)
    }

    /// Pricing multiplies token counts, so a billed round that reported no tokens contributes
    /// nothing and prices out at exactly zero. Rendered, that is `$0.0000` — an unknown cost
    /// reading as a free review, which is the one outcome cost reporting exists to prevent.
    func testCostIsUnknownRatherThanZeroWhenTheProviderReportsNoTokens() async throws {
        let client = StubChatClient([.message(finalReview)], usagePerReply: nil)
        let reviewer = DeepSeekReviewer(
            client: client,
            model: "deepseek-chat",
            pricing: .deepSeekDefault
        )

        let usage = try await reviewer.review(
            prompt: "REVIEW CONTRACT",
            worktree: worktree,
            apiKey: "sk-test"
        ).usage

        XCTAssertEqual(usage.requests, 1, "the call was still billed")
        XCTAssertNil(usage.costUSD, "rates times unknown tokens is unknown, not zero")
        XCTAssertNil(usage.costSummary)
    }

    /// The same defect in its quieter form: one silent round among several would understate the
    /// total rather than obviously zero it, which is worse because the figure still looks real.
    func testCostIsUnknownWhenOnlySomeRoundsReportTokens() async throws {
        let client = StubChatClient(
            [
                .toolCall(id: "c1", name: "read_file", arguments: #"{"path": "Widget.swift"}"#),
                .message(finalReview),
            ],
            usagePerReply: [
                TokenUsage(inputTokens: 1_000, outputTokens: 100, requests: 1),
                nil,
            ]
        )
        let reviewer = DeepSeekReviewer(
            client: client,
            model: "deepseek-chat",
            pricing: .deepSeekDefault
        )

        let usage = try await reviewer.review(
            prompt: "REVIEW CONTRACT",
            worktree: worktree,
            apiKey: "sk-test"
        ).usage

        XCTAssertEqual(usage.requests, 2)
        XCTAssertEqual(usage.inputTokens, 1_000, "what was reported is still counted")
        XCTAssertNil(usage.costUSD, "a partial measurement must not be priced as the whole")
    }

    /// The meter is the only figure a cancelled loop leaves behind, so it has to be priced the
    /// same way a returned review is — otherwise an abandoned review reports tokens and no cost
    /// even though the rates were right there.
    func testTheSpendMeterPricesTheRoundsItSaw() async throws {
        let client = StubChatClient(
            [
                .toolCall(id: "c1", name: "read_file", arguments: #"{"path": "Widget.swift"}"#),
                .failure(ChatCompletionError.timedOut(seconds: 180)),
            ],
            usagePerReply: TokenUsage(
                inputTokens: 1_000_000,
                cachedInputTokens: 1_000_000,
                outputTokens: 1_000_000,
                requests: 1
            )
        )
        let meter = DeepSeekReviewer.SpendMeter(
            pricing: TokenPricing(
                inputPerMillion: 1,
                cachedInputPerMillion: 0.25,
                outputPerMillion: 4
            )
        )
        let reviewer = DeepSeekReviewer(client: client, model: "deepseek-chat")

        do {
            _ = try await reviewer.review(
                prompt: "REVIEW CONTRACT",
                worktree: worktree,
                apiKey: "sk-test",
                meter: meter
            )
            XCTFail("The timeout should not be swallowed")
        } catch {
            let total = await meter.total()
            let spent = try XCTUnwrap(total, "the completed round was billed")
            XCTAssertEqual(spent.costUSD ?? 0, 5.25, accuracy: 0.0001)
        }
    }

    func testTheSpendMeterReportsNoCostForRoundsTheProviderDidNotMeasure() async throws {
        let client = StubChatClient(
            [
                .toolCall(id: "c1", name: "read_file", arguments: #"{"path": "Widget.swift"}"#),
                .failure(ChatCompletionError.timedOut(seconds: 180)),
            ],
            usagePerReply: nil
        )
        let meter = DeepSeekReviewer.SpendMeter(pricing: .deepSeekDefault)
        let reviewer = DeepSeekReviewer(client: client, model: "deepseek-chat")

        do {
            _ = try await reviewer.review(
                prompt: "REVIEW CONTRACT",
                worktree: worktree,
                apiKey: "sk-test",
                meter: meter
            )
            XCTFail("The timeout should not be swallowed")
        } catch {
            let total = await meter.total()
            let spent = try XCTUnwrap(total, "the round was billed even though it went unreported")
            XCTAssertEqual(spent.requests, 1)
            XCTAssertNil(spent.costUSD, "an unmeasured round must not price out as free")
        }
    }

    func testNarrationBeforeTheContractHeadingIsStripped() {
        // A chat completion arrives as one blob and often opens with the model thinking out
        // loud. That must not reach the posted GitHub review.
        XCTAssertEqual(
            DeepSeekReviewer.trimmedToContract(
                "Let me check the tests.\n\nNow let me finalize.\n\n## Summary\n\nAll good.\n\nVERDICT: CLEAN"
            ),
            "## Summary\n\nAll good.\n\nVERDICT: CLEAN"
        )
    }

    func testTrimmingIsANoOpForWellFormedOutput() {
        let clean = "## Summary\n\nAll good.\n\nVERDICT: CLEAN"
        XCTAssertEqual(DeepSeekReviewer.trimmedToContract(clean), clean)
    }

    func testOutputWithoutTheHeadingIsLeftIntact() {
        // Better to post a slightly untidy review than to discard the whole thing.
        let unstructured = "Some review with no heading.\n\nVERDICT: CLEAN"
        XCTAssertEqual(DeepSeekReviewer.trimmedToContract(unstructured), unstructured)
    }

    func testTrimmingAnchorsOnTheFirstHeadingOnly() {
        XCTAssertEqual(
            DeepSeekReviewer.trimmedToContract(
                "chatter\n## Summary\n\nfirst\n\n## Summary of risks\n\nsecond\n\nVERDICT: CLEAN"
            ),
            "## Summary\n\nfirst\n\n## Summary of risks\n\nsecond\n\nVERDICT: CLEAN"
        )
    }

    func testReviewOutputIsTrimmedBeforeItIsReturned() async throws {
        let client = StubChatClient([
            .message("Let me look around first.\n\n## Summary\n\nFine.\n\nVERDICT: CLEAN"),
        ])
        let reviewer = DeepSeekReviewer(client: client, model: "deepseek-chat")

        let output = try await reviewer.review(
            prompt: "REVIEW CONTRACT",
            worktree: worktree,
            apiKey: "sk-test"
        ).text

        XCTAssertTrue(output.hasPrefix("## Summary"))
        XCTAssertEqual(VerdictParser.parse(output), .clean)
    }

    func testOtherFailuresPropagate() async {
        let client = StubChatClient([
            .failure(ChatCompletionError.http(status: 401, message: "invalid api key")),
        ])
        let reviewer = DeepSeekReviewer(client: client, model: "deepseek-chat")

        do {
            _ = try await reviewer.review(
                prompt: "REVIEW CONTRACT",
                worktree: worktree,
                apiKey: "sk-wrong"
            ).text
            XCTFail("An authentication failure should not be swallowed")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("401"))
            // Nothing was billed before the first call failed, so the error is handed back bare
            // rather than wrapped in a spend of zero the engine would then report as a cost.
            let outcome = DeepSeekReviewer.outcome(of: error)
            XCTAssertNil(outcome.usage)
            XCTAssertTrue(outcome.error is ChatCompletionError)
        }
    }
}

/// Replays a scripted conversation so the reviewer can be exercised without reaching DeepSeek.
actor StubChatClient: ChatCompleting {
    enum Reply {
        case message(String)
        case toolCall(id: String, name: String, arguments: String)
        case failure(Error)
    }

    /// Usage attached to every successful reply, so accumulation across the loop can be asserted.
    var usagePerReply: TokenUsage?

    /// Usage per reply in order, for the case `usagePerReply` cannot express: a provider that
    /// reports tokens for some rounds and not others.
    private var usageScript: [TokenUsage?]?

    private var replies: [Reply]
    private var requests: [ChatCompletionRequest] = []

    init(_ replies: [Reply], usagePerReply: TokenUsage? = nil) {
        self.replies = replies
        self.usagePerReply = usagePerReply
    }

    init(_ replies: [Reply], usagePerReply: [TokenUsage?]) {
        self.replies = replies
        self.usageScript = usagePerReply
    }

    /// The next reply's usage: the script when one was given, otherwise the fixed value. A script
    /// that runs out reports nothing, matching a provider that stopped sending the object.
    private func nextUsage() -> TokenUsage? {
        guard var script = usageScript else { return usagePerReply }
        guard !script.isEmpty else { return nil }
        let next = script.removeFirst()
        usageScript = script
        return next
    }

    func complete(
        _ request: ChatCompletionRequest,
        apiKey: String
    ) async throws -> ChatCompletionResult {
        requests.append(request)
        guard !replies.isEmpty else {
            throw ChatCompletionError.emptyResponse
        }

        switch replies.removeFirst() {
        case let .message(text):
            return ChatCompletionResult(
                message: ChatMessage(role: .assistant, content: text),
                usage: nextUsage()
            )
        case let .toolCall(id, name, arguments):
            return ChatCompletionResult(
                message: ChatMessage(
                    role: .assistant,
                    toolCalls: [
                        ChatToolCall(
                            id: id,
                            function: ChatToolCall.Function(name: name, arguments: arguments)
                        ),
                    ]
                ),
                usage: nextUsage()
            )
        case let .failure(error):
            throw error
        }
    }

    func recordedRequests() -> [ChatCompletionRequest] { requests }
}
