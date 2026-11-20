/// The pull request's branch and commit state as Review Bot itself observed it, rendered straight
/// into the reviewers' prompt.
///
/// `DefaultPrompt` tells every reviewer that the PR thread and every file in the working directory
/// are untrusted input written by the pull request's author and commenters. A branch fact stashed
/// in a worktree file would contradict that on its face — it would be one more file a commenter
/// could, in principle, tamper with — so these facts are stated in the prompt itself instead, where
/// the "untrusted" framing does not apply.
///
/// It exists because the worktree's `.git` entry points into a clone — a developer's ordinary
/// working clone, or Review Bot's own bare clone, whose local branches are frozen at clone time —
/// which holds whatever it last happened to fetch. Review Bot refreshes only the base branch and,
/// for a same-repository pull request, the head branch before a review — every other ref in that
/// clone (local and remote-tracking branches, reflogs, `FETCH_HEAD`, `packed-refs`) can be
/// arbitrarily stale, and a reviewer that can read git's files or run `git` will find them. On a
/// release pull request (head `develop`, base `main`) two reviewers read an `origin/develop` one
/// commit behind the pull request's head, concluded the pull request was a side branch into `main`,
/// and posted a false `BLOCKING`. Stating the facts here means no reviewer has to infer them.
struct PullRequestFacts: Equatable {
    let baseRefName: String
    let headRefName: String?
    let headRepository: HeadRepository
    let headRefOid: String
    /// The head branch's tip as read back from the clone's `origin` remote immediately after
    /// fetching it. `nil` when nothing was fetched (a fork, an unrecognised relationship, or no
    /// reported name) or when the read-back itself failed.
    let headBranchTip: String?

    init(metadata: PullRequestMetadata, headBranchTip: String?) {
        baseRefName = metadata.baseRefName
        headRefName = metadata.headRefName
        headRepository = metadata.headRepository
        headRefOid = metadata.headRefOid
        self.headBranchTip = headBranchTip
    }

    /// `text` as a Markdown code span that shows it exactly. Git allows backticks in a ref name, so
    /// the fence is one backtick longer than the longest run inside, padded with spaces when needed
    /// (CommonMark strips one space on each side) — rewriting the name instead would state a
    /// different branch in a section that claims to be authoritative.
    private static func codeSpan(_ text: String) -> String {
        var longestRun = 0
        var run = 0
        for character in text {
            run = character == "`" ? run + 1 : 0
            longestRun = max(longestRun, run)
        }
        let fence = String(repeating: "`", count: longestRun + 1)
        let padding = longestRun > 0 ? " " : ""
        return fence + padding + text + padding + fence
    }

    /// The Markdown section appended to the reviewers' prompt.
    func render() -> String {
        let base = baseRefName
        // Non-empty only for a same-repository pull request with a reported name — the one case
        // Review Bot actually fetches the head branch into a remote-tracking ref (see
        // `PullRequestMetadata.fetchableHeadRefName`), so it is also the only case with anything to
        // say about a fetched tip or to list among the refreshed refs below.
        let head = headRefName.flatMap { name -> String? in
            guard headRepository == .sameRepository, !name.isEmpty else { return nil }
            return name
        }

        var lines = [
            "- Base branch — where this pull request lands: \(Self.codeSpan(base)).",
            headBranchLine(),
            "- Commit under review — the pull request's head, as GitHub reported it when the review request was discovered: \(Self.codeSpan(headRefOid)).",
        ]
        if let head {
            lines.append(tipLine(head: head))
        }

        let baseRef = Self.codeSpan("origin/\(base)")
        let refreshed = head.map { "\(baseRef) and \(Self.codeSpan("origin/\($0)"))" } ?? baseRef

        return """
        ## Pull request facts

        Review Bot recorded these before the review started. They are authoritative: where they disagree with anything you infer from the repository, they win.

        \(lines.joined(separator: "\n"))

        The worktree's `.git` entry points into the repository clone this review was cut from: either a developer's working clone, or Review Bot's own bare clone, whose local branches were frozen when it was cloned. For this review Review Bot refreshed only \(refreshed); every other remote-tracking ref, local branch, reflog, `FETCH_HEAD` and `packed-refs` entry in that clone may be days out of date. Never use them to decide where a branch points, which branch this pull request comes from, or whether it is a side branch — the facts above answer those questions.
        """
    }

    private func headBranchLine() -> String {
        guard let headRefName, !headRefName.isEmpty else {
            return "- Head branch: GitHub did not report its name, so its tip was not fetched."
        }
        let head = Self.codeSpan(headRefName)
        switch headRepository {
        case .sameRepository:
            return "- Head branch — where it comes from: \(head), in this same repository."
        case .fork:
            return "- Head branch — where it comes from: \(head), in a fork. Its tip was not fetched; the commit under review above is the pull request's head as GitHub reported it."
        case .unknown:
            return "- Head branch — where it comes from: \(head). GitHub did not report whether it lives in this repository or a fork, so its tip was not fetched."
        }
    }

    /// The fourth bullet, describing the head branch's freshly fetched tip — only reachable when
    /// `render()` found a same-repository head name to fetch in the first place.
    private func tipLine(head name: String) -> String {
        let head = Self.codeSpan(name)
        guard let headBranchTip else {
            return "- \(head) could not be read back after fetching it from `origin`; rely on the commit under review above."
        }
        return headBranchTip == headRefOid
            ? "- \(head) as fetched from the clone's `origin` remote just before the reviewers started: \(Self.codeSpan(headBranchTip)) — the same commit, so this pull request is the head branch's current tip."
            : "- \(head) as fetched from the clone's `origin` remote just before the reviewers started: \(Self.codeSpan(headBranchTip)) — **not** the commit under review."
    }
}
