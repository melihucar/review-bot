import Foundation

enum VerdictParser {
    static func parse(_ output: String) -> ReviewVerdict? {
        let pattern = #"(?im)^\s*VERDICT:\s*(BLOCKING|SHOULD_FIX|NITS_ONLY|CLEAN)\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
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

        // A verdict the policy treats as blocking wins, even if another reviewer failed to parse.
        if worstAction == .requestChanges {
            return .requestChanges
        }

        // Every reviewer produced a readable verdict: honour the strictest configured action
        // (`.comment` if any level is set to "leave it to me", otherwise `.approve`).
        if !results.isEmpty, parsed.count == results.count {
            return worstAction ?? .approve
        }

        // A reviewer failed or emitted no verdict: stay neutral.
        return .comment
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
