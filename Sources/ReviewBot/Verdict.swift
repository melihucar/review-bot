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
    static func evaluate(_ results: [ReviewerResult]) -> ReviewDecision {
        let parsed = results.compactMap(\.verdict)
        let worstRank = parsed.map(\.rank).max() ?? -1

        if worstRank >= ReviewVerdict.shouldFix.rank {
            return .requestChanges
        }

        if !results.isEmpty, parsed.count == results.count {
            return .approve
        }

        return .comment
    }
}
