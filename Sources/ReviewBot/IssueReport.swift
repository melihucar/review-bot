import Foundation

/// A GitHub issue prefilled from a failed review, so hitting "Report issue" in the Dashboard's
/// History tab produces a complete diagnostic instead of a blank form someone has to reconstruct
/// from memory. This type is deliberately pure — no AppKit, no `Bundle.main`, no implicit
/// `Date()` — so every value that varies by run (the app version, the clock, which CLIs are on
/// this machine) is supplied by the caller and the whole thing is deterministic under test.
/// `AppModel.reportFailure` is the only caller that gathers the live values and does the actual
/// clipboard/browser I/O; Review Bot itself never files the issue, because the report
/// necessarily names the repository and pull request the failure came from and those are often
/// private — the prefilled form is the review step.
struct IssueReport: Equatable {
    /// The slice of Review Bot's state worth attaching to a bug report. Rendered into the
    /// issue body's "Environment" table by `IssueReport.init`.
    struct Environment: Equatable {
        var appVersion: String
        var operatingSystem: String
        /// Keyed by CLI name ("gh", "claude", …). Rendered in a fixed sorted order — see
        /// `environmentSection` — so the report is identical regardless of the order
        /// `AppModel.refreshToolAvailability` happened to populate the dictionary in.
        var toolAvailability: [String: Bool]
        /// Each enabled reviewer with its configured model, e.g. "Claude (claude-opus-5)" — a
        /// wrong or retired model id is a common cause of the very failure being reported.
        var enabledReviewers: [String]
        var pollIntervalMinutes: Int
        var maxConcurrentReviews: Int
        /// Pre-rendered by the caller, e.g. "5 attempts" or "unlimited" — `FailureBudget`'s
        /// shape (an `Int?` limit) is a modeling detail this type has no reason to know about.
        var failureBudget: String
        /// Pre-rendered by the caller from `ReviewScope.label`, for the same reason.
        var reviewScope: String
        /// `StoragePaths.root.path` — where the reader can find that day's detailed log.
        var dataFolderPath: String
    }

    static let defaultRepository = "melihucar/review-bot"

    /// Bytes of *percent-encoded* body the prefill URL may carry. GitHub rejects a request line
    /// past roughly 8 KB, and the title plus the rest of the query string eat into that budget
    /// before the body even starts — so the URL carries a capped body and the untruncated one
    /// goes to the clipboard instead.
    ///
    /// Measured after encoding, not before, and that distinction is the whole point: every
    /// space and newline in the report becomes a three-byte `%XX` escape, so a body counted in
    /// characters can sit comfortably under a 6000-*character* cap and still encode to well
    /// past 8 KB — overrunning the exact limit the cap exists to respect.
    static let urlBodyEncodedLimit = 6000

    let title: String
    let body: String

    init(entry: HistoryEntry, environment: Environment, generatedAt: Date) {
        title = IssueReport.renderTitle(entry: entry)
        body = IssueReport.renderBody(entry: entry, environment: environment, generatedAt: generatedAt)
    }

    /// The body as carried in the prefill URL: `body` unchanged when its encoded form already
    /// fits under `urlBodyEncodedLimit`, otherwise clipped with an explicit marker so the reader
    /// knows the full report — not just what made it into the link — is sitting on their
    /// clipboard.
    var urlBody: String {
        guard IssueReport.encodedLength(of: body) > IssueReport.urlBodyEncodedLimit else { return body }
        let marker = "\n\n[… truncated — the full report is on your clipboard; paste it in before submitting.]"
        let budget = IssueReport.urlBodyEncodedLimit - IssueReport.encodedLength(of: marker)
        // The marker alone cannot exceed a 6000-byte budget, but clipping to a negative one
        // would trap — so degrade to an empty body rather than crash if the limit is ever
        // tightened below the marker's own encoded size.
        guard budget > 0 else { return "" }
        return IssueReport.clipped(body, toEncodedLength: budget) + marker
    }

    /// `https://github.com/<repository>/issues/new?title=…&body=…`, prefilled so opening it
    /// hands the reader a ready-to-review draft rather than a blank form.
    ///
    /// Deliberately does not use `URLComponents.queryItems`: it encodes a space as `+`, and
    /// GitHub's prefill decodes a `+` in the query as a literal space rather than treating it as
    /// `application/x-www-form-urlencoded`'s space escape — which would silently turn every `+`
    /// already present in the report (diff hunks, "C++", etc.) into a space. Percent-encoding by
    /// hand against the unreserved set sidesteps that entirely.
    func formURL(repository: String = IssueReport.defaultRepository) -> URL? {
        guard let encodedTitle = IssueReport.percentEncode(title),
              let encodedBody = IssueReport.percentEncode(urlBody) else {
            return nil
        }
        return URL(string: "https://github.com/\(repository)/issues/new?title=\(encodedTitle)&body=\(encodedBody)")
    }

    // MARK: - Title

    private static func renderTitle(entry: HistoryEntry) -> String {
        let subject = subject(repositoryName: entry.repositoryName, pullRequestNumber: entry.pullRequestNumber)
        return "Review failed: \(subject) — \(shortReason(from: entry.message))"
    }

    /// "<repo> #<n>" when both are known; the repository name alone when there is no pull
    /// request (a poll- or repository-level failure never has one); "Review Bot" itself only
    /// when even the repository name is blank — so the title always names something concrete
    /// rather than trailing off into "#nil" or an empty subject.
    private static func subject(repositoryName: String, pullRequestNumber: Int?) -> String {
        let name = repositoryName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return "Review Bot" }
        guard let number = pullRequestNumber else { return name }
        return "\(name) #\(number)"
    }

    /// The leading part of a failure message, clipped at a word boundary to roughly 60
    /// characters. Failure messages are built as `error.localizedDescription + " " +
    /// RetryPolicy.note(…)` (see `ReviewEngine`), so the real reason is always the prefix and the
    /// long "Attempt 5 of 5 — giving up on this request…" retry note is always the suffix;
    /// clipping early keeps that note from dominating the title without this type needing to
    /// know anything about its shape.
    private static func shortReason(from message: String) -> String {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "unknown failure" }
        let limit = 60
        guard trimmed.count > limit else { return trimmed }
        let endIndex = trimmed.index(trimmed.startIndex, offsetBy: limit)
        let prefix = trimmed[..<endIndex]
        if let lastSpace = prefix.lastIndex(of: " ") {
            return prefix[..<lastSpace].trimmingCharacters(in: .whitespaces) + "…"
        }
        return prefix + "…"
    }

    // MARK: - Body

    private static func renderBody(
        entry: HistoryEntry,
        environment: Environment,
        generatedAt: Date
    ) -> String {
        [
            disclosureSection,
            whatHappenedSection(entry: entry, generatedAt: generatedAt),
            environmentSection(environment),
            logsSection(environment),
        ].joined(separator: "\n\n")
    }

    /// Makes the prefill explicit up front, since a person opening a browser tab a minute after
    /// clicking "Report issue" may not remember Review Bot wrote any of this for them.
    private static var disclosureSection: String {
        """
        > Review Bot filled in this report from a failed review. It necessarily names the \
        repository and pull request the failure came from — both are often private — and \
        redacts nothing. Please read it over before submitting.
        """
    }

    private static func whatHappenedSection(entry: HistoryEntry, generatedAt: Date) -> String {
        var lines = [
            "## What happened",
            "",
            "```",
            entry.message,
            "```",
            "",
            "- **When**: the review failed at \(isoString(entry.date)); this report was " +
                "generated at \(isoString(generatedAt)).",
            "- **Repository**: \(repositoryDisplay(entry))",
        ]

        if let number = entry.pullRequestNumber {
            if let urlString = entry.pullRequestURL, URL(string: urlString) != nil {
                lines.append("- **Pull request**: [#\(number)](\(urlString))")
            } else {
                lines.append("- **Pull request**: #\(number)")
            }
        } else {
            // Poll-level and repository-level failures (a bad `gh` call, an unreadable
            // REVIEW.md) never have a pull request at all — say so instead of leaving the
            // bullet blank or printing "#nil".
            lines.append("- **Pull request**: none — this failure was not tied to a specific pull request.")
        }

        if let title = entry.pullRequestTitle, !title.isEmpty {
            lines.append("- **Pull request title**: \(title)")
        }

        return lines.joined(separator: "\n")
    }

    /// The repository slug when there is one, the plain name when the slug is blank (some
    /// failures happen before `gh` ever resolves a slug), and an explicit "unknown" only when
    /// both are empty — this section is a bullet list rather than a table, but the same rule
    /// applies: never render nothing where a reader expects a value.
    private static func repositoryDisplay(_ entry: HistoryEntry) -> String {
        let slug = entry.repositorySlug.trimmingCharacters(in: .whitespacesAndNewlines)
        if !slug.isEmpty { return slug }
        let name = entry.repositoryName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "unknown" : name
    }

    private static func environmentSection(_ environment: Environment) -> String {
        let reviewers = environment.enabledReviewers.isEmpty
            ? "none enabled"
            : environment.enabledReviewers.joined(separator: ", ")
        // Sorted by CLI name rather than left in dictionary order: Swift dictionaries make no
        // ordering guarantee, and an issue report that renders differently from run to run on
        // the exact same machine would be a strange thing to hand someone debugging it.
        let toolsFound = environment.toolAvailability
            .sorted { $0.key < $1.key }
            .map { name, found in "\(name) \(found ? "✓" : "✗")" }
            .joined(separator: ", ")

        let rows: [(String, String)] = [
            ("Review Bot version", environment.appVersion),
            ("macOS", environment.operatingSystem),
            ("Reviewers enabled", reviewers),
            ("CLIs found", toolsFound.isEmpty ? "unknown" : toolsFound),
            ("Poll interval", "\(environment.pollIntervalMinutes) minutes"),
            ("Concurrent reviews", "\(environment.maxConcurrentReviews)"),
            ("Failure budget", environment.failureBudget),
            ("Review scope", environment.reviewScope),
        ]
        let table = (["| Field | Value |", "| --- | --- |"] + rows.map { "| \($0.0) | \($0.1) |" })
            .joined(separator: "\n")

        return "## Environment\n\n\(table)"
    }

    private static func logsSection(_ environment: Environment) -> String {
        """
        ## Logs

        This failure is also recorded in that day's log under \
        `\(environment.dataFolderPath)/logs/`. Open it from Dashboard → History → \
        **Show data folder**, and attach it here if you can — it usually has more detail than \
        fits in the message above.
        """
    }

    private static let isoFormatter = ISO8601DateFormatter()

    private static func isoString(_ date: Date) -> String {
        isoFormatter.string(from: date)
    }

    // MARK: - Percent-encoding

    /// RFC 3986's unreserved set — letters, digits, `-`, `.`, `_`, `~`. Everything else,
    /// including the characters this feature exists to get right (space, `&`, `#`, `+`), is
    /// percent-encoded, which is what keeps a `+` from being misread as a space on GitHub's side.
    private static let unreservedCharacters = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )

    private static func percentEncode(_ value: String) -> String? {
        value.addingPercentEncoding(withAllowedCharacters: unreservedCharacters)
    }

    /// Whether `percentEncode` will pass this UTF-8 byte through as-is. Kept byte-wise rather
    /// than reusing `unreservedCharacters`: a `CharacterSet` answers questions about scalars,
    /// but what the URL is billed for is bytes, and every byte of a multi-byte scalar is
    /// escaped individually. The set is the same one — RFC 3986's unreserved characters, all
    /// of them ASCII — so the two can only agree.
    private static func isUnreserved(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "A")...UInt8(ascii: "Z"),
             UInt8(ascii: "a")...UInt8(ascii: "z"),
             UInt8(ascii: "0")...UInt8(ascii: "9"),
             UInt8(ascii: "-"), UInt8(ascii: "."), UInt8(ascii: "_"), UInt8(ascii: "~"):
            return true
        default:
            return false
        }
    }

    /// How many bytes `percentEncode` produces for `text`: one per unreserved byte, three
    /// (`%XX`) for every other.
    private static func encodedLength(of text: String) -> Int {
        text.utf8.reduce(0) { $0 + (isUnreserved($1) ? 1 : 3) }
    }

    /// The longest prefix of `text` whose encoded form fits in `limit` bytes, cut on a
    /// `Character` boundary so no escape sequence — and no grapheme — is split in half.
    private static func clipped(_ text: String, toEncodedLength limit: Int) -> String {
        var used = 0
        var end = text.startIndex
        for index in text.indices {
            let cost = encodedLength(of: String(text[index]))
            guard used + cost <= limit else { break }
            used += cost
            end = text.index(after: index)
        }
        return String(text[..<end])
    }
}
