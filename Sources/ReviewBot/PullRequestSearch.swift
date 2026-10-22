import Foundation

/// How a poll lists pull requests without tripping GitHub's search limits.
///
/// `gh search prs` is GitHub's search API: 30 requests a minute per account, and a burst is
/// answered with a "secondary rate limit" 403 that lasts minutes. A poll used to run one
/// search per repository back to back — ten within seconds for ten repositories, every poll —
/// and with anything else on the account searching too, that burst was enough. Now a poll runs
/// one search per *owner* and keeps the results that belong to a watched repository, and a
/// rate limit holds every search until it has passed. This is the pure half; `ReviewEngine`
/// runs the commands and keeps the clock.
enum PullRequestSearch {
    /// Results one search asks for. An owner-wide search covers every watched repository of
    /// that owner, so it needs more room than `gh`'s default of 30 did per repository.
    static let limit = 100
    /// The hold after a first rate limit. GitHub asks for "a few minutes".
    static let firstHold: TimeInterval = 5 * 60
    /// Ceiling on the hold, however many limits in a row.
    static let maximumHold: TimeInterval = 60 * 60

    /// The owners whose searches cover `repositories`, each once, in configured order.
    /// GitHub owners are case-insensitive, so `Acme/a` and `acme/b` are one search.
    static func owners(of repositories: [RepositoryConfiguration]) -> [String] {
        var seen: Set<String> = []
        return repositories.compactMap { repository in
            let owner = owner(of: repository.githubSlug)
            guard !owner.isEmpty, seen.insert(owner.lowercased()).inserted else { return nil }
            return owner
        }
    }

    /// The part of `owner/name` before the slash; empty when there is none.
    static func owner(of slug: String) -> String {
        guard let slash = slug.firstIndex(of: "/") else { return "" }
        return String(slug[..<slash])
    }

    /// The open pull requests `owner`'s repositories ask the signed-in user to review.
    static func openRequestArguments(owner: String) -> [String] {
        [
            "search", "prs",
            "--owner", owner,
            "--review-requested=@me",
            "--state", "open",
            "--limit", String(limit),
            "--json", "number,title,url,repository",
        ]
    }

    /// `results` split by the watched repository each belongs to, keyed by the lower-cased
    /// slug. A result in a repository nobody watches is dropped — an owner-wide search finds
    /// those too.
    static func byRepository(
        _ results: [PullRequestSummary],
        watching repositories: [RepositoryConfiguration]
    ) -> [String: [PullRequestSummary]] {
        let watched = Set(repositories.map { $0.githubSlug.lowercased() })
        var grouped: [String: [PullRequestSummary]] = [:]
        for result in results {
            guard let slug = slug(of: result)?.lowercased(), watched.contains(slug) else { continue }
            grouped[slug, default: []].append(result)
        }
        return grouped
    }

    /// The `owner/name` a result belongs to: what the search said, or else the first two
    /// path components of its URL (`https://github.com/owner/name/pull/42`).
    static func slug(of result: PullRequestSummary) -> String? {
        if let named = result.repository?.nameWithOwner, !named.isEmpty { return named }
        guard let path = URL(string: result.url)?.pathComponents.filter({ $0 != "/" }),
              path.count >= 2
        else { return nil }
        return "\(path[0])/\(path[1])"
    }

    /// Whether a failed `gh` call was GitHub refusing for rate, primary or secondary. `gh`
    /// prints GitHub's message on stderr: "You have exceeded a secondary rate limit" or
    /// "API rate limit exceeded for user".
    static func isRateLimited(_ result: CommandResult) -> Bool {
        (result.stderr + "\n" + result.stdout).lowercased().contains("rate limit")
    }

    /// How long searches wait after `consecutiveLimits` rate limits in a row: 5, 10, 20, 40
    /// minutes, then an hour.
    static func hold(afterConsecutiveLimits consecutiveLimits: Int) -> TimeInterval {
        let doublings = max(0, consecutiveLimits - 1)
        guard doublings < 8 else { return maximumHold }
        return min(firstHold * TimeInterval(1 << doublings), maximumHold)
    }
}
