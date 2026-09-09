import XCTest
@testable import ReviewBot

final class VerdictTests: XCTestCase {
    func testParserUsesLastValidVerdictTrailer() {
        let output = """
        An example says VERDICT: CLEAN in prose.
        VERDICT: SHOULD_FIX
        """
        XCTAssertEqual(VerdictParser.parse(output), .shouldFix)
    }

    func testParserRejectsMissingVerdict() {
        XCTAssertNil(VerdictParser.parse("## Summary\nLooks good."))
    }

    func testBodyWithoutTrailerOnlyRemovesVerdictLines() {
        let output = "## Summary\nVERDICT: appears in prose\n\nVERDICT: CLEAN\n"
        XCTAssertEqual(
            VerdictParser.bodyWithoutTrailer(output),
            "## Summary\nVERDICT: appears in prose"
        )
    }

    func testShouldFixResultRequestsChangesEvenWhenOtherReviewerFails() {
        let results = [
            result(.claude, verdict: .shouldFix),
            result(.codex, verdict: nil),
        ]
        XCTAssertEqual(DecisionEvaluator.evaluate(results, policy: .default), .requestChanges)
    }

    func testAllParsedNonBlockingResultsApprove() {
        let results = [
            result(.claude, verdict: .nitsOnly),
            result(.codex, verdict: .clean),
        ]
        XCTAssertEqual(DecisionEvaluator.evaluate(results, policy: .default), .approve)
    }

    func testSurvivingReviewerDecidesWhenTheOtherProducesNoVerdict() {
        let results = [
            result(.claude, verdict: .clean),
            result(.codex, verdict: nil),
        ]
        // The failed reviewer contributes nothing rather than pinning the panel to neutral.
        // The posted body discloses that it is a partial panel; see `aggregateReview`.
        XCTAssertEqual(DecisionEvaluator.evaluate(results, policy: .default), .approve)
    }

    func testNoReadableVerdictAtAllStaysNeutral() {
        let results = [
            result(.claude, verdict: nil),
            result(.codex, verdict: nil),
        ]
        // Nothing to decide on — and notably not an approval, which is what a naive
        // "strictest of an empty set" would produce.
        XCTAssertEqual(DecisionEvaluator.evaluate(results, policy: .default), .comment)
        XCTAssertEqual(DecisionEvaluator.evaluate([], policy: .default), .comment)
    }

    func testPolicyCanBlockOnNits() {
        let policy = DecisionPolicy(shouldFix: .requestChanges, nitsOnly: .requestChanges, clean: .approve)
        let results = [
            result(.claude, verdict: .nitsOnly),
            result(.codex, verdict: .clean),
        ]
        XCTAssertEqual(DecisionEvaluator.evaluate(results, policy: policy), .requestChanges)
    }

    func testPolicyCanApproveShouldFixOnlyPR() {
        let policy = DecisionPolicy(shouldFix: .approve, nitsOnly: .approve, clean: .approve)
        let results = [
            result(.claude, verdict: .shouldFix),
            result(.codex, verdict: .nitsOnly),
        ]
        XCTAssertEqual(DecisionEvaluator.evaluate(results, policy: policy), .approve)
    }

    func testPolicyLeaveToUserProducesNeutralComment() {
        let policy = DecisionPolicy(shouldFix: .comment, nitsOnly: .approve, clean: .approve)
        let results = [
            result(.claude, verdict: .shouldFix),
            result(.codex, verdict: .clean),
        ]
        XCTAssertEqual(DecisionEvaluator.evaluate(results, policy: policy), .comment)
    }

    func testBlockingAlwaysRequestsChangesRegardlessOfPolicy() {
        let policy = DecisionPolicy(shouldFix: .approve, nitsOnly: .approve, clean: .approve)
        let results = [result(.claude, verdict: .blocking)]
        XCTAssertEqual(DecisionEvaluator.evaluate(results, policy: policy), .requestChanges)
    }

    func testGateDisagreementWhenReviewersStraddleTheGate() {
        XCTAssertTrue(DecisionEvaluator.gateDisagreement([
            result(.claude, verdict: .clean),
            result(.codex, verdict: .shouldFix),
        ], policy: .default))
        XCTAssertTrue(DecisionEvaluator.gateDisagreement([
            result(.claude, verdict: .nitsOnly),
            result(.codex, verdict: .blocking),
        ], policy: .default))
    }

    func testGateDisagreementFollowsPolicyBoundary() {
        // Under default policy nits and clean both approve → no disagreement…
        let straddling = [
            result(.claude, verdict: .nitsOnly),
            result(.codex, verdict: .clean),
        ]
        XCTAssertFalse(DecisionEvaluator.gateDisagreement(straddling, policy: .default))
        // …but a policy that blocks on nits makes them straddle the request-changes line.
        let blockNits = DecisionPolicy(shouldFix: .requestChanges, nitsOnly: .requestChanges, clean: .approve)
        XCTAssertTrue(DecisionEvaluator.gateDisagreement(straddling, policy: blockNits))
    }

    func testNoGateDisagreementWhenReviewersAgreeOrAreAlone() {
        XCTAssertFalse(DecisionEvaluator.gateDisagreement([
            result(.claude, verdict: .shouldFix),
            result(.codex, verdict: .blocking),
        ], policy: .default))
        XCTAssertFalse(DecisionEvaluator.gateDisagreement([
            result(.claude, verdict: .clean),
            result(.codex, verdict: .nitsOnly),
        ], policy: .default))
        XCTAssertFalse(DecisionEvaluator.gateDisagreement([
            result(.codex, verdict: .shouldFix),
        ], policy: .default))
        XCTAssertFalse(DecisionEvaluator.gateDisagreement([
            result(.claude, verdict: .blocking),
            result(.codex, verdict: nil),
        ], policy: .default))
    }

    func testDecisionForReconciledVerdict() {
        XCTAssertEqual(DecisionEvaluator.decision(for: .blocking, policy: .default), .requestChanges)
        XCTAssertEqual(DecisionEvaluator.decision(for: .shouldFix, policy: .default), .requestChanges)
        XCTAssertEqual(DecisionEvaluator.decision(for: .nitsOnly, policy: .default), .approve)
        XCTAssertEqual(DecisionEvaluator.decision(for: .clean, policy: .default), .approve)
    }

    func testDecisionForReconciledVerdictHonoursPolicy() {
        let policy = DecisionPolicy(shouldFix: .approve, nitsOnly: .requestChanges, clean: .approve)
        XCTAssertEqual(DecisionEvaluator.decision(for: .shouldFix, policy: policy), .approve)
        XCTAssertEqual(DecisionEvaluator.decision(for: .nitsOnly, policy: policy), .requestChanges)
        // BLOCKING is never configurable.
        XCTAssertEqual(DecisionEvaluator.decision(for: .blocking, policy: policy), .requestChanges)
    }

    func testExhaustedQuotaAndRejectedCredentialsAreTerminal() {
        let terminal = [
            "ERROR: You've hit your usage limit. Try again at 2:22 PM.",
            "stream error: insufficient_quota",
            "The model `gpt-5.6-sol` is not supported when using Codex with a ChatGPT account",
            "API Error: 401 {\"type\":\"authentication_error\"}",
            "Not authenticated. Please run `codex login`.",
            "Your credit balance is too low to access the API.",
            // DeepSeek reaches the engine over HTTP rather than as a CLI, so its own wording for
            // a rejected key and an empty account has to be recognised too — a full agent loop
            // is the most expensive thing in the panel to retry for nothing.
            "DeepSeek returned HTTP 401: Authentication Fails",
            "DeepSeek returned HTTP 402: Insufficient Balance",
            // Review Bot's own message when a reviewer is set to API-key auth and no key
            // resolves, or the Keychain prompt was denied. Only Settings can fix that, so the
            // whole failure budget would otherwise be spent on a request that cannot start.
            "DeepSeek is set to API-key auth but its key could not be read — either none is "
                + "saved, or macOS Keychain access was denied. Check Settings → Reviewers.",
        ]
        for message in terminal {
            XCTAssertEqual(
                ReviewerFailureClass.classify(message),
                .terminal,
                "expected terminal: \(message)"
            )
            XCTAssertFalse(
                ReviewerResult(
                    reviewer: .codex,
                    model: "m",
                    output: "",
                    verdict: nil,
                    failure: message
                ).isWorthRetrying,
                "a terminal failure must not be retried in place: \(message)"
            )
        }
    }

    func testUnrecognisedAndRecoverableFailuresStayTransient() {
        let transient = [
            "command exited with status 1",
            "API Error: 529 overloaded_error",
            "error sending request for url (https://api.example.com): connection reset by peer",
            // A pull request is allowed to talk about quotas and logins without disarming
            // the retry: the markers describe what a CLI says about itself.
            "reviewed src/billing/quota.rs and src/auth/login.rs",
            // DeepSeek's own client already retries 5xx before giving up, but a provider outage
            // is exactly the failure the next poll is likely to get past.
            "DeepSeek returned HTTP 503: Service Unavailable",
        ]
        for message in transient {
            XCTAssertEqual(
                ReviewerFailureClass.classify(message),
                .transient,
                "expected transient: \(message)"
            )
        }
    }

    func testTimeoutIsStillNotRetriedInPlace() {
        var result = ReviewerResult(
            reviewer: .claude,
            model: "m",
            output: "",
            verdict: nil,
            failure: "timed out after 900s"
        )
        result.timedOut = true
        XCTAssertFalse(result.isWorthRetrying)
    }

    /// The exemption is the `timedOut` flag, not the message. That distinction matters most for
    /// DeepSeek: it is the one reviewer with no `ProcessRunner` alarm behind it, so its timeout
    /// arrives as an ordinary-looking provider error and classifies transient like any other
    /// network failure. Re-running it in place would mean a second full paid agent loop against
    /// a provider that is still not answering.
    func testADeepSeekTimeoutIsExemptedByTheFlagRatherThanByItsWording() {
        let message = ChatCompletionError.timedOut(seconds: 180).localizedDescription
        XCTAssertEqual(ReviewerFailureClass.classify(message), .transient)

        var result = ReviewerResult(
            reviewer: .deepseek,
            model: "deepseek-chat",
            output: "",
            verdict: nil,
            failure: message
        )
        XCTAssertTrue(result.isWorthRetrying, "without the flag it looks retryable")
        result.timedOut = true
        XCTAssertFalse(result.isWorthRetrying)
    }

    private func result(
        _ reviewer: ReviewerName,
        verdict: ReviewVerdict?
    ) -> ReviewerResult {
        ReviewerResult(
            reviewer: reviewer,
            model: "test-model",
            output: "test",
            verdict: verdict,
            failure: verdict == nil ? "failed" : nil
        )
    }
}
