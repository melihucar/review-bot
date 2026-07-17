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
        XCTAssertEqual(DecisionEvaluator.evaluate(results), .requestChanges)
    }

    func testAllParsedNonBlockingResultsApprove() {
        let results = [
            result(.claude, verdict: .nitsOnly),
            result(.codex, verdict: .clean),
        ]
        XCTAssertEqual(DecisionEvaluator.evaluate(results), .approve)
    }

    func testUnreadableVerdictProducesNeutralComment() {
        let results = [
            result(.claude, verdict: .clean),
            result(.codex, verdict: nil),
        ]
        XCTAssertEqual(DecisionEvaluator.evaluate(results), .comment)
    }

    func testGateDisagreementWhenReviewersStraddleTheGate() {
        XCTAssertTrue(DecisionEvaluator.gateDisagreement([
            result(.claude, verdict: .clean),
            result(.codex, verdict: .shouldFix),
        ]))
        XCTAssertTrue(DecisionEvaluator.gateDisagreement([
            result(.claude, verdict: .nitsOnly),
            result(.codex, verdict: .blocking),
        ]))
    }

    func testNoGateDisagreementWhenReviewersAgreeOrAreAlone() {
        XCTAssertFalse(DecisionEvaluator.gateDisagreement([
            result(.claude, verdict: .shouldFix),
            result(.codex, verdict: .blocking),
        ]))
        XCTAssertFalse(DecisionEvaluator.gateDisagreement([
            result(.claude, verdict: .clean),
            result(.codex, verdict: .nitsOnly),
        ]))
        XCTAssertFalse(DecisionEvaluator.gateDisagreement([
            result(.codex, verdict: .shouldFix),
        ]))
        XCTAssertFalse(DecisionEvaluator.gateDisagreement([
            result(.claude, verdict: .blocking),
            result(.codex, verdict: nil),
        ]))
    }

    func testDecisionForReconciledVerdict() {
        XCTAssertEqual(DecisionEvaluator.decision(for: .blocking), .requestChanges)
        XCTAssertEqual(DecisionEvaluator.decision(for: .shouldFix), .requestChanges)
        XCTAssertEqual(DecisionEvaluator.decision(for: .nitsOnly), .approve)
        XCTAssertEqual(DecisionEvaluator.decision(for: .clean), .approve)
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
