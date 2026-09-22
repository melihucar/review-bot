import Foundation

/// Keeps a pull request's diff within a size a reviewer CLI can actually finish reading
/// inside its 900-second budget.
///
/// A pull request that touches hundreds of files — or one that happens to vendor a large
/// generated or third-party file — can produce a diff running to tens of megabytes. Writing
/// that whole thing into `.review-bot-diff.patch` does not make the review more thorough; it
/// hands the reviewer CLI something it cannot finish reading before it times out, so the
/// pull request ends up as unreviewed as one that was never diffed at all. `fit` makes the
/// cut explicit and disclosed instead of leaving it to whatever the CLI does on its own when
/// it runs out of budget: a reviewer that only saw part of the change is told so, and
/// `ReviewEngine` repeats it in the posted review, rather than a partial diff being reviewed
/// as though it were the whole pull request.
///
/// Pure and dependency-free by design — no I/O, no knowledge of `ReviewEngine` or the
/// worktree — so every rule here is exercised directly in `DiffBudgetTests` without a git
/// repository or a mocked CLI anywhere in sight.
enum DiffBudget {
    /// Bytes of raw diff (the `diff --git` sections themselves, not the summary prose this
    /// type adds around them) a reviewer gets before truncation kicks in. Comfortably under
    /// the reviewer timeout: several megabytes of diff is the difference between a CLI that
    /// finishes with time to spare and one that times out having produced nothing.
    static let defaultLimit = 2_000_000

    struct Outcome: Equatable {
        /// What actually gets written to `.review-bot-diff.patch`. Identical to the input
        /// when nothing needed cutting; otherwise the summary/closing prose plus whichever
        /// file sections fit.
        let patch: String
        /// How many files the pull request changes, in total — including any this outcome
        /// could not show.
        let totalFiles: Int
        /// How many of those files have their section present in `patch`. Equal to
        /// `totalFiles` whenever no file was dropped entirely.
        let includedFiles: Int
        /// Whether a file that *is* present had its own hunks cut part-way through. Only the
        /// pathological single-oversized-file case can set this, but it has to be tracked
        /// separately: such a file is neither included-whole nor omitted, so without it a
        /// diff consisting of one enormous file would report nothing was truncated.
        let includesCutFile: Bool

        var omittedFiles: Int { totalFiles - includedFiles }

        /// How many files the reviewers saw *all* the changed lines of — `includedFiles` minus
        /// the one cut file, when there is one. This is the honest number to quote: a file whose
        /// hunks were cut short is present but not covered, so counting it as included would let
        /// a one-file oversized diff be described as fully reviewed.
        var completeFiles: Int { includedFiles - (includesCutFile ? 1 : 0) }

        /// Whether the reviewers saw less than the whole change — by a file being dropped or
        /// by one being cut short. This is what the posted review discloses, so it must be
        /// true in *every* case where a finding could be missing for want of diff.
        var isTruncated: Bool { omittedFiles > 0 || includesCutFile }
    }

    /// One file's diff section, plus the shape of its change extracted from it. `text` is the
    /// section verbatim, starting at its `diff --git ` header line and running up to (but not
    /// including) the next one.
    private struct FileChange {
        let path: String
        let text: String
        let added: Int
        let removed: Int
    }

    static func fit(_ diff: String, limit: Int = defaultLimit) -> Outcome {
        let sections = fileChanges(in: diff)

        // The common case, and it must be exact: every pull request under the limit — the
        // overwhelming majority — has to see byte-for-byte the same patch text it always has,
        // so nothing here may reformat, re-line-wrap, or otherwise touch a diff that already
        // fits.
        guard diff.utf8.count > limit else {
            return Outcome(
                patch: diff,
                totalFiles: sections.count,
                includedFiles: sections.count,
                includesCutFile: false
            )
        }

        // An oversized diff with no `diff --git ` boundary at all (a single blob with no
        // recognisable file headers) gives this nothing to split on. There is no whole-section
        // cut that would be honest here, so hand the text back untouched rather than mangle it.
        guard !sections.isEmpty else {
            return Outcome(patch: diff, totalFiles: 0, includedFiles: 0, includesCutFile: false)
        }

        var included: [FileChange] = []
        var usedBytes = 0
        // Only the *first* section, and only when it alone exceeds the whole limit, gets cut
        // rather than dropped outright — see the loop body for why.
        var cutFirstSection = false

        for (index, section) in sections.enumerated() {
            let cost = section.text.utf8.count
            if index == 0, cost > limit {
                // A patch with zero hunks in it is useless to every reviewer, and a single
                // 40 MB file should not be written whole just because it happens to be first.
                // This is the one place a file's hunks are shown incomplete rather than not at
                // all — everywhere else, `included` only ever holds whole sections.
                let marker = """


                [Review Bot cut this file's diff at the \(limit)-byte size limit; the hunks \
                above are incomplete and the file has further changes not shown here.]
                """
                included.append(
                    FileChange(
                        path: section.path,
                        text: truncated(section.text, toUTF8ByteLimit: limit) + marker,
                        added: section.added,
                        removed: section.removed
                    )
                )
                usedBytes = limit
                cutFirstSection = true
                continue
            }
            // Whole sections only, accumulated in order: the first one that would push the
            // total over the limit stops the accumulation rather than being skipped in favor
            // of a smaller one further down, so `included` is always a contiguous prefix and
            // never splits a file's hunks across the included/omitted boundary.
            guard usedBytes + cost <= limit else { break }
            included.append(section)
            usedBytes += cost
        }

        let omitted = Array(sections.dropFirst(included.count))
        // Deliberately the same expression as `Outcome.completeFiles`, over the same two values
        // that become its stored properties — the prose below and the posted review's disclosure
        // must never quote different counts for the same patch.
        let completeCount = included.count - (cutFirstSection ? 1 : 0)

        var pieces: [String] = [
            """
            Review Bot truncated this patch: it was too large for a reviewer to read in full \
            before its time budget runs out. This pull request changes \(sections.count) \
            file\(sections.count == 1 ? "" : "s") in total; complete hunks for \
            \(completeCount) of them are included below.
            """,
            """
            ## FULL CHANGE SUMMARY (\(sections.count) files)

            \(sections.map(summaryLine).joined(separator: "\n"))
            """,
        ]
        pieces.append(contentsOf: included.map(\.text))

        if !omitted.isEmpty {
            pieces.append(
                """
                ## TRUNCATED — \(omitted.count) file\(omitted.count == 1 ? "" : "s") not shown above

                \(omitted.map(summaryLine).joined(separator: "\n"))

                These files ARE part of this pull request and are in scope for review. They are \
                checked out in the working directory, so read them there if you need to look at \
                them — but because their changed lines are not shown above, any finding in one of \
                them must be anchored to what is visible in the file itself, and must say that the \
                diff for it was truncated.
                """
            )
        }

        return Outcome(
            patch: pieces.joined(separator: "\n\n"),
            totalFiles: sections.count,
            includedFiles: included.count,
            includesCutFile: cutFirstSection
        )
    }

    private static func summaryLine(_ change: FileChange) -> String {
        "- `\(change.path)`: +\(change.added) -\(change.removed)"
    }

    /// Splits a diff into its per-file `diff --git ` sections and extracts each one's path and
    /// added/removed line counts. Any text before the first such line — normally none, since a
    /// plain `git diff`/`gh pr diff` starts directly with the first file header — is dropped:
    /// it belongs to no file, so there is nothing for `fit` to attribute it to or truncate it
    /// alongside.
    private static func fileChanges(in diff: String) -> [FileChange] {
        let lines = diff.components(separatedBy: "\n")
        guard let firstHeader = lines.firstIndex(where: { $0.hasPrefix("diff --git ") }) else {
            return []
        }

        var sections: [[String]] = []
        for line in lines[firstHeader...] {
            if line.hasPrefix("diff --git ") {
                sections.append([line])
            } else {
                sections[sections.count - 1].append(line)
            }
        }

        return sections.map { lines in
            var added = 0
            var removed = 0
            for line in lines.dropFirst() {
                // The `+++`/`---` headers that open each file's hunks are not content changes —
                // checking them first keeps them from being counted as an added or removed
                // line, since both prefixes also match a bare "+"/"-".
                if line.hasPrefix("+++") || line.hasPrefix("---") { continue }
                if line.hasPrefix("+") { added += 1 } else if line.hasPrefix("-") { removed += 1 }
            }
            return FileChange(
                path: path(fromHeader: lines[0]),
                text: lines.joined(separator: "\n"),
                added: added,
                removed: removed
            )
        }
    }

    /// A `diff --git ` header reads `diff --git a/<old path> b/<new path>` — identical old and
    /// new paths for an ordinary change, different ones for a rename. Taking everything after
    /// the *last* ` b/` (rather than parsing quoted/escaped paths properly) is enough to get the
    /// current path right, including for a rename, without a full header grammar; if the marker
    /// is not present at all (a header git did not produce in the usual shape), fall back to the
    /// whole line rather than guess.
    private static func path(fromHeader header: String) -> String {
        guard let range = header.range(of: " b/", options: .backwards) else {
            return header
        }
        return String(header[range.upperBound...])
    }

    /// Cuts `text` to at most `limit` UTF-8 bytes without splitting a character in half, so a
    /// diff containing non-ASCII source is never cut into something that fails to decode.
    ///
    /// Indexing the UTF-8 view once and walking back to the nearest character boundary is the
    /// point: this runs on the one section big enough to blow the whole budget on its own, and
    /// measuring the text character by character would allocate millions of transient strings
    /// to do it.
    private static func truncated(_ text: String, toUTF8ByteLimit limit: Int) -> String {
        let utf8 = text.utf8
        guard utf8.count > limit,
              let cut = utf8.index(utf8.startIndex, offsetBy: limit, limitedBy: utf8.endIndex)
        else { return text }

        // A cut landing inside a multi-byte character has no position in the character view;
        // step back a byte at a time until it does. That is at most three bytes.
        var boundary = cut
        while boundary > utf8.startIndex {
            if let characterIndex = String.Index(boundary, within: text) {
                return String(text[..<characterIndex])
            }
            boundary = utf8.index(before: boundary)
        }
        return ""
    }
}
