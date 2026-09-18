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
    ///
    /// Lenient by design: unlike `VerdictParser.parse` (which must be strict, since
    /// it extracts the *trusted* verdict from reviewer output), this scan allows
    /// unified-diff markers (`+`/`-`/context space) and surrounding quotes or
    /// punctuation, because planted lines in threads and diffs commonly carry them.
    static func plantedVerdicts(in text: String) -> Set<ReviewVerdict> {
        let pattern = #"(?im)^[+\- ]*\s*["'`]*\s*VERDICT:\s*(BLOCKING|SHOULD_FIX|NITS_ONLY|CLEAN)\s*["'`.,!?]*\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
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
    ///
    /// Direction of safety: this guard only ever downgrades a permissive verdict to
    /// a neutral comment (`Reason.verdictContradictsOwnFindings`); it never grants
    /// an approval a reviewer didn't already produce. A false positive here costs
    /// one extra human look at a comment instead of an approval; a false negative
    /// lets a body that contradicts its own verdict through as an approval — the
    /// exact injection this guard exists to catch. That asymmetry is why negation
    /// detection leans conservative: a *closed* filler list (`fillerWords`) rather
    /// than an open "skip N words" window, so a word we didn't anticipate stops the
    /// backward walk instead of silently absorbing a real negator. Words that flip a
    /// clause's polarity or scope — "and", "but", "so", "because", "until", "unless",
    /// "which", "that", "while" — are deliberately *not* filler, so "returns nothing
    /// and must be fixed" and "without which this cannot be merged" still count as
    /// unnegated.
    ///
    /// This scans the whole body rather than only the Blocking/Should-fix sections
    /// of the reviewer's own findings list: the contradictions this guard exists for
    /// are written as prose — a Summary or Merge-gate line — not necessarily
    /// restated under a findings heading. `testCleanVerdictWithMergeBlockerProseBlocksApproval`
    /// (`InjectionGuardTests`) is the fixture this was built against: "The PR is not
    /// mergeable as-is... blocks merge and must be fixed" lives entirely in `##
    /// Summary`, with no Blocking/Should-fix section at all.
    private static func bodySaysUnmergeable(_ body: String) -> Bool {
        guard let regex = phraseRegex else { return false }
        let matches = regex.matches(in: body, range: NSRange(body.startIndex..., in: body))
        for match in matches {
            guard let matchRange = Range(match.range, in: body) else { continue }
            if !isNegated(matchRange: matchRange, in: body) {
                return true
            }
        }
        return false
    }

    /// A match is negated when the clause leading into it opens with a negator
    /// (`hasLeadingNegation`) and the rest of the clause does not carve out an
    /// exception (`namesAnException`), or the match is immediately followed by a
    /// complete "none" value on the same line (`hasTrailingNoneValue`) — e.g. a
    /// findings-list line like "Merge-blocking: None." that has no leading clause
    /// to walk at all.
    private static func isNegated(matchRange: Range<String.Index>, in body: String) -> Bool {
        (hasLeadingNegation(before: matchRange.lowerBound, in: body)
            && !namesAnException(after: matchRange.upperBound, in: body))
            || hasTrailingNoneValue(after: matchRange.upperBound, in: body)
    }

    /// True when the clause leading into `matchStart` opens with a negator,
    /// tolerating up to 4 `fillerWords` between the negator and the match before
    /// giving up.
    ///
    /// A second negator further back cancels the first — "no reason not to hold
    /// the merge" argues *for* holding it — so the walk continues past the negator
    /// it found, over up to 4 more filler words, and treats a double negative as
    /// no negation at all.
    private static func hasLeadingNegation(before matchStart: String.Index, in body: String) -> Bool {
        let beforeText = body[body.startIndex..<matchStart]
        let clauseStart: String.Index
        if let boundaryIndex = beforeText.lastIndex(where: { clauseBoundaryCharacters.contains($0) }) {
            clauseStart = beforeText.index(after: boundaryIndex)
        } else {
            clauseStart = beforeText.startIndex
        }

        var tokens = beforeText[clauseStart...]
            .split(whereSeparator: \.isWhitespace)
            .map { $0.trimmingCharacters(in: tokenTrimCharacters) }
            .filter { !$0.isEmpty }

        // A bare "-" (a list marker, or a stray em-dash rendered as a hyphen) is
        // itself a clause boundary the character scan above can't see, because it
        // only fires between whitespace-delimited tokens.
        if let dashIndex = tokens.lastIndex(of: "-") {
            tokens = Array(tokens[(dashIndex + 1)...])
        }
        tokens = tokens.map { $0.lowercased() }

        guard let negatorIndex = nearestNegator(in: tokens, before: tokens.count) else {
            return false
        }
        return nearestNegator(in: tokens, before: negatorIndex) == nil
    }

    /// The index of the negator reached by walking back from `end` over at most 4
    /// filler words, or `nil` when a non-filler word, a fifth filler word, or the
    /// start of the clause comes first.
    private static func nearestNegator(in tokens: [String], before end: Int) -> Int? {
        var skippedFillers = 0
        var index = end - 1
        while index >= 0 {
            let token = tokens[index]
            if isNegator(token) {
                return index
            }
            guard fillerWords.contains(token), skippedFillers < 4 else {
                return nil
            }
            skippedFillers += 1
            index -= 1
        }
        return nil
    }

    private static func isNegator(_ token: String) -> Bool {
        negators.contains(token) || token.hasSuffix("n't") || token.hasSuffix("n’t")
    }

    /// True when the rest of the match's sentence names an exception to the
    /// negation: "no merge-blocking defect other than the migration", "nothing needs
    /// to be fixed more urgently than the migration", "no merge-blocking defects,
    /// except the migration" and "no blockers (besides the migration)" all *assert* a
    /// blocker, so the strong exception words count anywhere up to the end of the
    /// sentence, past commas and brackets. "but" is ambiguous — "nothing
    /// merge-blocking but the migration" versus "no blockers, but a few nits" — so it
    /// counts only inside the match's own clause, which a comma ends.
    private static func namesAnException(after matchEnd: String.Index, in body: String) -> Bool {
        let afterText = body[matchEnd...]
        let sentence = afterText[..<(afterText.firstIndex(where: { sentenceBoundaryCharacters.contains($0) })
            ?? afterText.endIndex)]
        let clause = sentence[..<(sentence.firstIndex(where: { clauseBoundaryCharacters.contains($0) })
            ?? sentence.endIndex)]
        if words(in: clause).contains("but") {
            return true
        }
        let tokens = words(in: sentence)
        for (index, token) in tokens.enumerated() {
            if exceptionWords.contains(token) {
                return true
            }
            if ["apart", "aside", "save"].contains(token),
               index + 1 < tokens.count, tokens[index + 1] == "from" || tokens[index + 1] == "for" {
                return true
            }
        }
        return false
    }

    /// Lowercased words, split on anything that is not a letter, hyphen or apostrophe,
    /// so "(except" and "except," both read as "except".
    private static func words(in text: Substring) -> [String] {
        text.split(whereSeparator: { !$0.isLetter && $0 != "-" && $0 != "'" && $0 != "’" })
            .map { $0.lowercased() }
    }

    /// True when the text after the match, to the end of its line, is nothing but a
    /// "none"-shaped value — a findings-list line answering its own label with no
    /// further prose to qualify it, e.g. "Merge-blocking issues: none." but not
    /// "Merge-blocking findings: none have been fixed."
    private static func hasTrailingNoneValue(after matchEnd: String.Index, in body: String) -> Bool {
        guard let regex = noneValueRegex else { return false }
        let lineEnd = body[matchEnd...].firstIndex(of: "\n") ?? body.endIndex
        let afterText = String(body[matchEnd..<lineEnd])
        return regex.firstMatch(in: afterText, range: NSRange(afterText.startIndex..., in: afterText)) != nil
    }

    /// Boundary characters that end a clause: sentence/list punctuation, brackets,
    /// the pipe used in table rows, an em/en dash, or a line break. Walking back
    /// past one of these would attribute a negator from an earlier, unrelated
    /// clause to this match.
    private static let clauseBoundaryCharacters: Set<Character> = [
        ".", ";", ":", "!", "?", ",", "(", ")", "[", "]", "|", "—", "–", "\n",
    ]

    /// `*_\`"'` are trimmed from a token's ends only — markdown emphasis and
    /// quoting — never from the middle, so inner hyphens and apostrophes
    /// (`no-op`, `isn't`) survive intact.
    private static let tokenTrimCharacters = CharacterSet(charactersIn: "*_`\"'")

    private static let negators: Set<String> = [
        "no", "not", "nothing", "none", "zero", "without", "never", "neither", "nor",
    ]

    /// Closed on purpose (see `bodySaysUnmergeable`): a word that can sit between a
    /// negator and the gating phrase without breaking the negation, but carries no
    /// polarity of its own. Anything not on this list stops the backward walk.
    /// Deliberately absent: "other", "else" and "further" ("no other issue is
    /// merge-blocking" implies one is), "more" (a comparative), and "this", which can
    /// mean "so" ("no other issue is this merge-blocking").
    private static let fillerWords: Set<String> = [
        "a", "an", "any", "remaining", "real", "actual", "genuine", "new",
        "such", "single", "obvious", "outstanding", "true", "significant", "serious", "here",
        "left", "of", "these", "those", "them", "the", "is", "are", "was",
        "were", "be", "been", "seem", "seems", "look", "looks", "appear", "appears", "i",
        "we", "see", "saw", "found", "find", "identified", "really", "truly", "strictly",
        "currently", "remain", "remains", "findings", "finding", "issues", "issue",
        "defects", "defect", "problems", "problem", "or", "need", "needs", "reason", "to",
        "should-fix", "blocking", "gating", "critical",
    ]

    /// Words that, later in the same sentence, turn "no X" into "no X except this
    /// one". Comparatives belong here too — "nothing is more merge-blocking than …" —
    /// which is also why "more" is not a filler word. ("but" is handled separately; see
    /// `namesAnException`.)
    private static let exceptionWords: Set<String> = [
        "than", "except", "excepting", "besides", "beyond",
    ]

    /// Characters that end a sentence, for the exception scan in `namesAnException`.
    private static let sentenceBoundaryCharacters: Set<Character> = [".", ";", "!", "?", "\n"]

    private static let phraseRegex = try? NSRegularExpression(
        pattern: #"(?i)\b(not mergeable|unmergeable|cannot be merged|cannot merge|merge-blocking|must (?:be )?fixed|needs? to be fixed|do not (?:merge|ship|release)|not ready (?:for|to) merge|hold (?:the )?merge)\b"#
    )

    /// A complete trailing "none" value on the same line, e.g. "Merge-blocking
    /// issues: none." or "merge-blocking: **None**" — but not "...none have been
    /// fixed.", where trailing prose means the sentence isn't actually saying there
    /// are none.
    private static let noneValueRegex = try? NSRegularExpression(
        pattern: #"(?i)^(?:\s+[\w-]+){0,2}\s*[*_`]*\s*[:—–-]\s*[*_`]*\s*(?:none|nothing|n/?a)\s*[*_`]*\s*[.!]?\s*$"#
    )
}