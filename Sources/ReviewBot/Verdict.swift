import Foundation

enum VerdictParser {
    /// The machine-readable verdict line a reviewer must end with. Shared by the
    /// parser and `InjectionGuard` (which scans untrusted thread/diff text for
    /// planted lines that would match).
    static let verdictLineRegex = #"(?im)^\s*VERDICT:\s*(BLOCKING|SHOULD_FIX|NITS_ONLY|CLEAN)\s*$"#

    static func parse(_ output: String) -> ReviewVerdict? {
        guard let regex = try? NSRegularExpression(pattern: verdictLineRegex),
              let match = regex.matches(
                in: output,
                range: NSRange(output.startIndex..., in: output)
              ).last,
              let range = Range(match.range(at: 1), in: output)
        else {
            return nil
        }

        return ReviewVerdict(rawValue: String(output[range]).uppercased())
    }

    /// True when the review says, in its own words, that it could not actually assess the pull
    /// request — the evidence was unreadable, missing, or never reached.
    ///
    /// A verdict line is cheap to emit and the contract demands one, so a reviewer that spent its
    /// whole turn failing to open the diff still signs off with `VERDICT: NITS_ONLY` — "I found
    /// no problems" being literally true of a review that looked at nothing. Taken at face value
    /// that is an approval, which is the most damaging thing this tool can produce. It happened:
    /// on a 181-file pull request whose diff exceeded the tool sandbox's file cap, the reviewer
    /// reported plainly that it could not read the diff and approved in the same breath.
    ///
    /// So the *body* overrides the verdict line. Each phrase is one a model uses about its own
    /// inability and is anchored to the review itself, so ordinary prose about the pull request
    /// cannot trip it: "this pull request could not be reviewed" matches, while "this migration
    /// could not be verified" — a legitimate finding — does not.
    static func statesItCouldNotAssess(_ body: String) -> Bool {
        let patterns = [
            #"(?i)\b(?:this )?(?:pull request|PR|diff|change)\b[^.\n]{0,40}\bcould not be (?:reviewed|assessed|evaluated)\b"#,
            #"(?i)\bI (?:can ?not|cannot|could not|am unable to|was unable to)\b[^.\n]{0,40}\b(?:review|assess|evaluate)\b"#,
            #"(?i)\bno basis to (?:certify|assess|judge)\b"#,
            #"(?i)\b(?:merge )?gate cannot be (?:meaningfully )?determined\b"#,
            #"(?i)\bunable to assess\b"#,
        ]
        return patterns.contains { pattern in
            guard let regex = try? NSRegularExpression(
                pattern: pattern,
                options: [.anchorsMatchLines]
            ) else { return false }
            let range = NSRange(body.startIndex..., in: body)
            return regex.firstMatch(in: body, range: range) != nil
        }
    }

    static func bodyWithoutTrailer(_ output: String) -> String {
        output
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { line in
                parse(String(line)) == nil
            }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum DecisionEvaluator {
    static func evaluate(_ results: [ReviewerResult], policy: DecisionPolicy) -> ReviewDecision {
        let parsed = results.compactMap(\.verdict)
        let actions = parsed.map { policy.action(for: $0) }
        let worstAction = actions.max(by: { $0.rank < $1.rank })

        // Decide on whoever finished, and honour the strictest configured action among them
        // (`.comment` if any level is set to "leave it to me", otherwise `.approve`). A reviewer
        // that failed contributes nothing rather than pinning the decision to neutral: an outage
        // in one CLI would otherwise mean the other reviewer's findings never gate anything, and
        // the review that says so is posted with the absence disclosed in its body.
        //
        // `worstAction` is nil exactly when no reviewer parsed a verdict, which is the one case
        // with nothing to decide on. The engine declines to post at all there; `.comment` is the
        // safe answer for any other caller.
        return worstAction ?? .comment
    }

    /// True when two or more reviewers parsed a verdict but land on opposite sides of the
    /// policy's request-changes boundary — at least one action is `.requestChanges` while at
    /// least one is not. A lone reviewer's false blocker is the main way strictest-wins
    /// mis-gates a correct PR, so this disagreement is the signal to reconcile before deciding.
    static func gateDisagreement(_ results: [ReviewerResult], policy: DecisionPolicy) -> Bool {
        let actions = results.compactMap(\.verdict).map { policy.action(for: $0) }
        guard actions.count >= 2 else { return false }
        return actions.contains { $0 == .requestChanges } && actions.contains { $0 != .requestChanges }
    }

    /// Maps a single reconciled verdict to the GitHub action under the active policy.
    static func decision(for verdict: ReviewVerdict, policy: DecisionPolicy) -> ReviewDecision {
        policy.action(for: verdict)
    }
}
