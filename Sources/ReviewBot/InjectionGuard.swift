import Foundation

/// Deterministic gates that keep untrusted pull-request content (the conversation
/// thread and every file the PR ships) from driving the posted decision.
///
/// Reviewer verdicts are model judgment, and smaller models measurably degrade
/// under injected thread content (a planted `VERDICT:` line or a fake "already
/// approved" narrative can downgrade a finding). These checks run on the *text
/// alone* — no model involved — so the worst outcome of any injection is a
/// neutral comment, never an approval.
enum InjectionGuard {
    /// Why an otherwise-approvable decision was downgraded to a neutral comment.
    enum Reason: Equatable {
        /// The reviewer's verdict matches a `VERDICT:` line planted inside the
        /// PR thread or diff by a commenter/author, so it is not independent.
        case verdictMatchesPlantedLine
        /// A permissive reviewer verdict contradicts its own prose (the body
        /// describes a merge blocker while the verdict line is CLEAN/NITS_ONLY),
        /// so the verdict line is not trustworthy.
        case verdictContradictsOwnFindings
    }

    /// All `VERDICT:` lines present in untrusted text. A reviewer's verdict that
    /// matches any of these is not independent — the author could simply have
    /// told the model which line to emit.
    static func plantedVerdicts(in text: String) -> Set<ReviewVerdict> {
        guard let regex = try? NSRegularExpression(pattern: VerdictParser.verdictLineRegex) else {
            return []
        }
        return Set(
            regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
                .compactMap { match in
                    guard let range = Range(match.range(at: 1), in: text) else { return nil }
                    return ReviewVerdict(rawValue: String(text[range]).uppercased())
                }
        )
    }

    /// Returns the reason an approval decision is unsafe, or `nil` when an
    /// approval may stand. Callers must invoke this only when the computed
    /// decision is `.approve`; gating verdicts (`requestChanges`) are unaffected
    /// by design, since the failure mode is a permissive verdict.
    static func flagIfApproveUnsafe(
        thread: String,
        diff: String,
        results: [ReviewerResult],
        adjudication: ReviewerResult?
    ) -> Reason? {
        let planted = plantedVerdicts(in: thread + "\n" + diff)

        // The verdict that produced the approval: the adjudicator's if it decided,
        // otherwise the strictest reviewer verdict (which must exist here — the
        // engine only reaches the decision when every reviewer parsed).
        let deciding: ReviewVerdict
        if let adjudicated = adjudication?.verdict {
            deciding = adjudicated
        } else if let strictest = results.compactMap(\.verdict).max(by: { $0.rank < $1.rank }) {
            deciding = strictest
        } else {
            return nil
        }

        if planted.contains(deciding) {
            return .verdictMatchesPlantedLine
        }

        // Any permissive review whose own prose describes a merge blocker
        // contradicts its verdict line — a severity-calibration collapse under
        // injected context. A strict verdict is always allowed to stand.
        var reviews: [(ReviewVerdict?, String)] = results.map { result in
            (result.verdict, result.output)
        }
        if let adjudication {
            reviews.append((adjudication.verdict, adjudication.output))
        }
        for (verdict, output) in reviews {
            if let verdict, verdict == .clean || verdict == .nitsOnly, bodySaysUnmergeable(output) {
                return .verdictContradictsOwnFindings
            }
        }

        return nil
    }

    /// True when the review body states, in its own words, that the PR blocks or
    /// cannot be merged — language no CLEAN/NITS_ONLY verdict should coexist with.
    private static func bodySaysUnmergeable(_ body: String) -> Bool {
        guard let regex = try? NSRegularExpression(
            pattern: #"(?i)\b(not mergeable|unmergeable|cannot be merged|cannot merge|merge-blocking|must (?:be )?fixed|needs? to be fixed|do not (?:merge|ship|release)|not ready (?:for|to) merge|hold (?:the )?merge)\b"#
        ) else {
            return false
        }
        return regex.firstMatch(in: body, range: NSRange(body.startIndex..., in: body)) != nil
    }
}