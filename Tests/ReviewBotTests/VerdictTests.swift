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

    func testUnreadableVerdictProducesNeutralComment() {
        let results = [
            result(.claude, verdict: .clean),
            result(.codex, verdict: nil),
        ]
        XCTAssertEqual(DecisionEvaluator.evaluate(results, policy: .default), .comment)
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
