import Foundation

enum ReviewEngineError: LocalizedError {
    case commandFailed(String)
    case invalidResponse(String)
    case noReviewersEnabled
    case reviewIncomplete(String)

    var errorDescription: String? {
        switch self {
        case let .commandFailed(message): message
        case let .invalidResponse(message): message
        case .noReviewersEnabled: "Enable Claude, Codex, opencode, or Gemini before running reviews."
        case let .reviewIncomplete(message): message
        }
    }
}

actor ReviewEngine {
    typealias EventSink = (HistoryEntry) async -> Void
    typealias StatusSink = (String) async -> Void

    private let paths: StoragePaths
    private let runner: any CommandRunning
    /// Only ever read through `ResolvedCredentials.resolve`, which takes the blocking Keychain
    /// call off this actor's executor. Nothing here may call `apiKey(for:)` directly.
    private let credentialStore: any CredentialStoring
    private let reviewedState: ReviewedStateStore
    private let lastReviewed: LastReviewedStore
    private let attempts: ReviewAttemptStore
    private let logger: ActivityLogger
    private let now: @Sendable () -> Date
    /// Serializes the git steps of concurrent reviews that share a clone.
    private let gitGate = RepositoryGate()

    private struct PendingPullRequest: Sendable {
        let summary: PullRequestSummary
        let metadata: PullRequestMetadata
        let repository: RepositoryConfiguration
        let requestMarker: String
        let reviewKey: String
    }

    /// Every seam has a production default, so the app constructs the engine with `paths` alone
    /// while tests replace the pieces they need: `runner` for the CLIs and git/gh, `credentials`
    /// for the Keychain, and `now` for the retry backoff, which is otherwise untestable in a
    /// poll-interval-sized test.
    init(
        paths: StoragePaths,
        runner: any CommandRunning = ProcessRunner(),
        credentials: any CredentialStoring = KeychainCredentialStore(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.paths = paths
        self.runner = runner
        credentialStore = credentials
        self.now = now
        reviewedState = ReviewedStateStore(paths: paths)
        lastReviewed = LastReviewedStore(paths: paths)
        attempts = ReviewAttemptStore(paths: paths, now: now())
        logger = ActivityLogger(directory: paths.logsDirectory)
        try? paths.prepare()
    }

    /// - Parameter manual: a poll the user asked for ("Run now"). It ignores the
    ///   retry backoff and the failure budget, so fixing whatever broke the
    ///   reviewers — a missing CLI, a bad model name, expired auth — and clicking
    ///   Run now resumes abandoned requests without editing stored state.
    func poll(
        configuration: ReviewBotConfiguration,
        manual: Bool = false,
        onEvent: @escaping EventSink,
        onStatus: @escaping StatusSink
    ) async {
        let repositories = configuration.repositories.filter(\.enabled)
        guard !repositories.isEmpty else {
            await onStatus("Add and enable a repository to begin")
            return
        }
        guard configuration.claude.enabled
            || configuration.codex.enabled
            || configuration.opencode.enabled
            || configuration.gemini.enabled else {
            await onStatus(ReviewEngineError.noReviewersEnabled.localizedDescription)
            return
        }

        do {
            await onStatus("Checking GitHub authentication…")
            let userResult = try await runner.run(
                "gh",
                arguments: ["api", "user", "--jq", ".login"],
                timeout: 30
            )
            guard userResult.succeeded else {
                throw ReviewEngineError.commandFailed(
                    "GitHub authentication failed: \(conciseError(userResult))"
                )
            }
            let githubUser = userResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)

            var pendingReviews: [PendingPullRequest] = []
            var deferredRequests = 0
            for repository in repositories {
                let discovered = await discoverPendingReviews(
                    repository: repository,
                    githubUser: githubUser,
                    configuration: configuration,
                    manual: manual,
                    onEvent: onEvent,
                    onStatus: onStatus
                )
                pendingReviews.append(contentsOf: discovered.pending)
                deferredRequests += discovered.deferred
            }

            await runPendingReviews(
                pendingReviews,
                configuration: configuration,
                onEvent: onEvent,
                onStatus: onStatus
            )

            await onStatus(
                watchingStatus(
                    repositoryCount: repositories.count,
                    deferredRequests: deferredRequests
                )
            )
        } catch {
            await logger.append("Poll failed: \(error.localizedDescription)")
            await onStatus(error.localizedDescription)
            await onEvent(
                HistoryEntry(
                    kind: .failed,
                    repositoryName: "Review Bot",
                    repositorySlug: "",
                    pullRequestNumber: nil,
                    pullRequestTitle: nil,
                    pullRequestURL: nil,
                    message: error.localizedDescription
                )
            )
        }
    }

    private func discoverPendingReviews(
        repository: RepositoryConfiguration,
        githubUser: String,
        configuration: ReviewBotConfiguration,
        manual: Bool,
        onEvent: @escaping EventSink,
        onStatus: @escaping StatusSink
    ) async -> (pending: [PendingPullRequest], deferred: Int) {
        let maxRounds = configuration.maxReviewRoundsPerPR
        var deferred = 0
        do {
            await onStatus("Checking \(repository.name)…")
            let result = try await runner.run(
                "gh",
                arguments: [
                    "search", "prs",
                    "--repo", repository.githubSlug,
                    "--review-requested=@me",
                    "--state", "open",
                    "--json", "number,title,url",
                ],
                timeout: 60
            )
            guard result.succeeded else {
                throw ReviewEngineError.commandFailed(
                    "Could not list pull requests for \(repository.githubSlug): \(conciseError(result))"
                )
            }

            let pullRequests: [PullRequestSummary]
            do {
                pullRequests = try JSONDecoder().decode(
                    [PullRequestSummary].self,
                    from: Data(result.stdout.utf8)
                )
            } catch {
                throw ReviewEngineError.invalidResponse(
                    "GitHub returned an unexpected response for \(repository.githubSlug)."
                )
            }

            var pending: [PendingPullRequest] = []
            for pullRequest in pullRequests {
                // Inspecting a pull request can fail on its own (metadata or timeline),
                // which is now reported rather than silently degraded — so it needs the
                // same bound as a failing review, or a renamed repo or a lost token
                // would post one failure per poll forever.
                let inspectionKey = "\(repository.githubSlug)#\(pullRequest.number)@discovery"
                let inspection = manual ? RetryDecision.run : RetryPolicy.decide(
                    attempt: attempts.attempt(for: inspectionKey),
                    budget: configuration.failureBudget,
                    pollIntervalMinutes: configuration.pollIntervalMinutes,
                    now: now()
                )
                if let deferral = deferralLog(
                    inspection,
                    repository: repository,
                    number: pullRequest.number,
                    subject: "inspection of"
                ) {
                    await logger.append(deferral)
                    deferred += 1
                    continue
                }

                do {
                    let metadata = try await pullRequestMetadata(
                        number: pullRequest.number,
                        repository: repository
                    )
                    let requestMarker = try await latestReviewRequestMarker(
                        number: pullRequest.number,
                        repository: repository,
                        githubUser: githubUser,
                        fallback: metadata.headRefOid
                    )
                    attempts.clear(inspectionKey, at: now())

                    let reviewKey = "\(repository.githubSlug)#\(pullRequest.number)@\(metadata.headRefOid)@\(requestMarker)"
                    guard !reviewedState.contains(reviewKey) else { continue }

                    // A request that keeps failing is retried on a widening schedule and
                    // eventually abandoned, so a broken reviewer can't re-run the whole
                    // pipeline on every poll forever. A manual run ignores both.
                    let retry = manual ? RetryDecision.run : RetryPolicy.decide(
                        attempt: attempts.attempt(for: reviewKey),
                        budget: configuration.failureBudget,
                        pollIntervalMinutes: configuration.pollIntervalMinutes,
                        now: now()
                    )
                    if let deferral = deferralLog(
                        retry,
                        repository: repository,
                        number: pullRequest.number
                    ) {
                        await logger.append(deferral)
                        deferred += 1
                        continue
                    }

                    // Stop re-reviewing a PR once it has hit its configured round cap.
                    if let maxRounds {
                        let prPrefix = "\(repository.githubSlug)#\(pullRequest.number)@"
                        if reviewedState.count(withPrefix: prPrefix) >= maxRounds {
                            await logger.append(
                                "Skipping \(repository.githubSlug)#\(pullRequest.number): reached the \(maxRounds)-review limit."
                            )
                            continue
                        }
                    }

                    await emit(
                        kind: .requestDetected,
                        repository: repository,
                        pullRequest: pullRequest,
                        message: "Review requested at \(shortMarker(requestMarker)).",
                        onEvent: onEvent
                    )
                    pending.append(
                        PendingPullRequest(
                            summary: pullRequest,
                            metadata: metadata,
                            repository: repository,
                            requestMarker: requestMarker,
                            reviewKey: reviewKey
                        )
                    )
                } catch {
                    let failures = attempts.recordFailure(for: inspectionKey, at: now())
                    let message = error.localizedDescription + " " + RetryPolicy.note(
                        failures: failures,
                        budget: configuration.failureBudget,
                        pollIntervalMinutes: configuration.pollIntervalMinutes
                    )
                    await logger.append(
                        "Could not inspect \(repository.githubSlug)#\(pullRequest.number): \(message)"
                    )
                    await onEvent(
                        HistoryEntry(
                            kind: .failed,
                            repositoryName: repository.name,
                            repositorySlug: repository.githubSlug,
                            pullRequestNumber: pullRequest.number,
                            pullRequestTitle: pullRequest.title,
                            pullRequestURL: pullRequest.url,
                            message: message
                        )
                    )
                }
            }
            return (pending, deferred)
        } catch {
            await logger.append("Repository \(repository.githubSlug) failed: \(error.localizedDescription)")
            await onEvent(
                HistoryEntry(
                    kind: .failed,
                    repositoryName: repository.name,
                    repositorySlug: repository.githubSlug,
                    pullRequestNumber: nil,
                    pullRequestTitle: nil,
                    pullRequestURL: nil,
                    message: error.localizedDescription
                )
            )
            return ([], deferred)
        }
    }

    /// The log line for work discovery is skipping, or `nil` when it may run.
    private func deferralLog(
        _ decision: RetryDecision,
        repository: RepositoryConfiguration,
        number: Int,
        subject: String = "review of"
    ) -> String? {
        switch decision {
        case .run:
            return nil
        case let .exhausted(failures):
            return "Skipping \(subject) \(repository.githubSlug)#\(number): \(failures) failed attempts, giving up until a new commit, a re-request, or a manual run."
        case let .backOff(remaining):
            return "Backing off \(subject) \(repository.githubSlug)#\(number): retrying in \(RetryPolicy.durationDescription(remaining))."
        }
    }

    /// Reviews everything this poll discovered, `configuration.maxConcurrentReviews`
    /// at a time.
    ///
    /// A review is minutes of CLI time, so reviewing a queue one pull request at a
    /// time meant the newest request waited out every older one — a backlog of five
    /// took five times as long as it needed to, with the machine idle in between. The
    /// cap is the counterweight: each pull request runs *every* enabled reviewer, so
    /// an unbounded fan-out would put a dozen CLI processes against the same API at
    /// once.
    private func runPendingReviews(
        _ pendingReviews: [PendingPullRequest],
        configuration: ReviewBotConfiguration,
        onEvent: @escaping EventSink,
        onStatus: @escaping StatusSink
    ) async {
        guard !pendingReviews.isEmpty else { return }
        let total = pendingReviews.count
        let limit = max(1, min(configuration.maxConcurrentReviews, total))
        // There is one status line and it can only describe one thing. A lone review
        // narrates itself as before; a queue would just flicker between its members,
        // so the poll reports the queue's progress instead and the per-pull-request
        // detail stays in the menu bar queue and the history.
        let announcesStatus = total == 1
        if !announcesStatus {
            await onStatus(Self.queueStatus(completed: 0, total: total))
        }

        var completed = 0
        await withTaskGroup(of: Void.self) { group in
            var inFlight = 0
            for pendingReview in pendingReviews {
                if inFlight == limit {
                    _ = await group.next()
                    inFlight -= 1
                    completed += 1
                    if !announcesStatus {
                        await onStatus(Self.queueStatus(completed: completed, total: total))
                    }
                }
                group.addTask {
                    await self.review(
                        pendingReview,
                        configuration: configuration,
                        announcesStatus: announcesStatus,
                        onEvent: onEvent,
                        onStatus: onStatus
                    )
                }
                inFlight += 1
            }

            while await group.next() != nil {
                completed += 1
                if !announcesStatus {
                    await onStatus(Self.queueStatus(completed: completed, total: total))
                }
            }
        }
    }

    private static func queueStatus(completed: Int, total: Int) -> String {
        completed == 0
            ? "Reviewing \(total) pull requests…"
            : "Reviewed \(completed) of \(total) pull requests…"
    }

    /// - Parameter announcesStatus: whether this review owns the status line. False
    ///   when it is one of several running at once — see `runPendingReviews`.
    private func review(
        _ pendingReview: PendingPullRequest,
        configuration: ReviewBotConfiguration,
        announcesStatus: Bool = true,
        onEvent: @escaping EventSink,
        onStatus: @escaping StatusSink
    ) async {
        let announce: StatusSink = announcesStatus ? onStatus : { _ in }
        let pullRequest = pendingReview.summary
        let metadata = pendingReview.metadata
        let repository = pendingReview.repository
        var worktreeURL: URL?
        var worktreeAdded = false
        var spent: TokenUsage?

        do {
            await announce("Preparing \(repository.name) #\(pullRequest.number)…")

            let repositoryDirectory = paths.worktreesDirectory.appendingPathComponent(
                safeFilename(repository.githubSlug),
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: repositoryDirectory,
                withIntermediateDirectories: true
            )
            let worktree = repositoryDirectory.appendingPathComponent(
                "pr-\(pullRequest.number)-\(metadata.headRefOid.prefix(8))-\(UUID().uuidString.prefix(8))",
                isDirectory: true
            )
            worktreeURL = worktree

            let headBranchTip = try await checkOutPullRequest(pendingReview, at: worktree)
            worktreeAdded = true
            // Before any reviewer is started, not inside `runGemini`: the reviewers run
            // concurrently in this one worktree, so the checkout has to be settled while
            // nothing is reading it.
            try ownGeminiWorkspaceConfiguration(in: worktree)

            let priorHead = lastReviewed.head(
                for: "\(repository.githubSlug)#\(pullRequest.number)"
            )
            let context = try await prepareReviewContext(
                number: pullRequest.number,
                repository: repository,
                worktree: worktree,
                scope: configuration.reviewScope,
                priorHead: priorHead,
                metadata: metadata
            )
            let facts = PullRequestFacts(metadata: metadata, headBranchTip: headBranchTip).render()

            await emit(
                kind: .reviewStarted,
                repository: repository,
                pullRequest: pullRequest,
                message: reviewerDescription(configuration),
                onEvent: onEvent
            )
            await announce("Reviewing \(repository.name) #\(pullRequest.number)…")

            // Resolved once, here, before any reviewer starts — and off this actor. Reading a
            // Keychain item is a synchronous call that can block on a modal prompt, so doing it
            // from inside a reviewer's run method would stall its siblings and the poll loop
            // behind them. One resolution also means at most one prompt per reviewer per
            // review, and it covers the adjudicator `runReconciliation` may pick below.
            let credentials = await ResolvedCredentials.resolve(
                Self.reviewersNeedingKeys(in: configuration),
                from: credentialStore
            )

            let results = await runReviewers(
                configuration: configuration,
                worktree: worktree,
                repositoryRules: await loadRepositoryReviewRules(
                    repository: repository,
                    baseCommitSHA: metadata.baseRefOid
                ),
                pullRequestFacts: facts,
                credentials: credentials
            )

            // Whatever has been billed so far, in a variable declared outside the `do` so a
            // review that spends real money and then fails still records the spend. Assigned
            // here — above the incomplete-review throw below, not after it — because a panel
            // where every metered reviewer failed burned tokens on every attempt too, and its
            // history entry is the only place that spend can ever be recorded. Re-computed once
            // the adjudicator has run, since reconciliation is a metered call of its own.
            spent = usageTotal(results: results, adjudication: nil, configuration: configuration)

            // Post as long as *someone* finished. A reviewer that failed is named in the posted
            // body rather than suppressing the review: holding the whole panel hostage to one CLI
            // means an exhausted quota throws away the findings the other reviewer already
            // produced, and keeps doing so until the failure budget abandons the request
            // entirely — so a provider outage reads to the author as no review at all.
            // Nobody finishing is different in kind: there is no review to post, so leave the
            // request unmarked for the next poll.
            let unfinished = results.filter { $0.verdict == nil }
            guard results.contains(where: { $0.verdict != nil }) else {
                let detail = results.isEmpty
                    ? "no reviewer produced a result"
                    : unfinished.map { result in
                        if let failure = result.failure {
                            return "\(result.reviewer.rawValue) failed (\(failure))"
                        }
                        return "\(result.reviewer.rawValue) returned no verdict"
                    }.joined(separator: "; ")
                throw ReviewEngineError.reviewIncomplete(
                    "Review not posted — \(detail)"
                )
            }
            if !unfinished.isEmpty {
                await logger.append(
                    "Posting \(repository.githubSlug)#\(pullRequest.number) without "
                        + unfinished.map(\.reviewer.rawValue).joined(separator: ", ")
                        + "; the review discloses that it is a partial panel and will not approve."
                )
            }

            let policy = configuration.decisionPolicy
            let strictDecision = DecisionEvaluator.evaluate(results, policy: policy)
            var decision = strictDecision
            // The adjudication that *decided* the review — nil when reconciliation produced no
            // verdict, in which case the strictest verdict stands and there is nothing to
            // disclose in the posted body.
            var adjudication: ReviewerResult?
            // The adjudication that was *billed*: every reconciliation that ran, verdict or not.
            // Kept apart from `adjudication` because a call that came back useless was charged
            // exactly like one that came back decisive.
            var adjudicationSpend: ReviewerResult?
            if DecisionEvaluator.gateDisagreement(results, policy: policy) {
                await announce("Reviewers disagreed on \(repository.name) #\(pullRequest.number); reconciling…")
                let adjudicated = await runReconciliation(
                    results: results,
                    configuration: configuration,
                    worktree: worktree,
                    pullRequestFacts: facts,
                    credentials: credentials
                )
                adjudicationSpend = adjudicated
                if let verdict = adjudicated.verdict {
                    decision = DecisionEvaluator.decision(for: verdict, policy: policy)
                    adjudication = adjudicated
                } else {
                    await logger.append(
                        "Reconciliation for \(repository.githubSlug)#\(pullRequest.number) produced no verdict; using strictest (\(strictDecision.title))."
                    )
                }
                spent = usageTotal(
                    results: results,
                    adjudication: adjudicationSpend,
                    configuration: configuration
                )
            }
            // An approval reached without every enabled reviewer weighing in is capped to a
            // neutral comment — see `DecisionEvaluator.withholdingApprovalFromPartialPanel`.
            // This runs after reconciliation, so an adjudicated approval from a partial panel is
            // capped too, and before the injection guard below, which then only has to consider
            // a decision that can still approve.
            let uncapped = decision
            decision = DecisionEvaluator.withholdingApprovalFromPartialPanel(decision, results: results)
            let approvalWithheld = uncapped == .approve && decision != .approve

            var guardReason: InjectionGuard.Reason?
            if decision == .approve {
                guardReason = InjectionGuard.flagIfApproveUnsafe(
                    thread: context.thread,
                    diff: context.diff,
                    results: results,
                    adjudication: adjudication
                )
                if guardReason != nil {
                    decision = .comment
                }
            }
            let reviewBody = aggregateReview(
                pullRequest: pullRequest,
                commitSHA: metadata.headRefOid,
                results: results,
                decision: decision,
                adjudication: adjudication,
                guardReason: guardReason,
                approvalWithheldForPartialPanel: approvalWithheld,
                usageReport: usageReport(
                    results: results,
                    adjudication: adjudicationSpend,
                    configuration: configuration
                )
            )
            let reviewFile = try saveReview(
                reviewBody,
                repository: repository,
                pullRequestNumber: pullRequest.number,
                commitSHA: metadata.headRefOid
            )

            // Never post a review onto a commit it did not read. A review takes minutes, and a
            // push can land meanwhile: an approval of the old commit may still count toward the
            // new one's required approvals, so the re-read is the real protection — if the head
            // moved, post nothing. The request stays open, the next poll discovers the new head
            // under a fresh dedup key, and this failure count, keyed to the old head, never
            // matters again. `commit_id` is the backstop for the second or so between the re-read
            // and the post: GitHub attaches a review that names no commit (all `gh pr review` can
            // send) to whatever the head is by then, while a pinned one lands on the commit it
            // describes. GitHub clears the review request on any review, so a review that loses
            // that race needs a re-request. A head that moves faster than a review completes is
            // reviewed again each poll — accepted over posting a stale approval.
            let current = try await pullRequestMetadata(number: pullRequest.number, repository: repository)
            guard current.headRefOid == metadata.headRefOid else {
                throw ReviewEngineError.reviewIncomplete(
                    "Not posted — the head moved from \(metadata.headRefOid.prefix(8)) to "
                        + "\(current.headRefOid.prefix(8)) while the review ran. The next poll "
                        + "reviews the new head. Saved at \(reviewFile.path)"
                )
            }

            let post = try await runner.run(
                "gh",
                arguments: [
                    "api", "--method", "POST",
                    "repos/\(repository.githubSlug)/pulls/\(pullRequest.number)/reviews",
                    "-f", "commit_id=\(metadata.headRefOid)",
                    "-f", "event=\(decision.reviewEvent)",
                    "-F", "body=@\(reviewFile.path)",
                ],
                timeout: 120
            )
            guard post.succeeded else {
                throw ReviewEngineError.commandFailed(
                    "Generated the review, but GitHub rejected it: \(conciseError(post)). Saved at \(reviewFile.path)"
                )
            }

            reviewedState.insert(pendingReview.reviewKey)
            attempts.clear(pendingReview.reviewKey, at: now())
            lastReviewed.record(
                "\(repository.githubSlug)#\(pullRequest.number)",
                head: metadata.headRefOid
            )
            let verdicts = results.map {
                "\($0.reviewer.rawValue): \($0.verdict?.rawValue ?? "unavailable")"
            }.joined(separator: ", ")
            let reconciledNote = adjudication.map {
                " Reconciled by \($0.reviewer.rawValue) → \($0.verdict?.rawValue ?? "unavailable")."
            } ?? ""
            let withheldNote = approvalWithheld ? " Approval withheld: partial panel." : ""
            // Recorded whether or not the report is posted, so spend stays traceable either way.
            let total = spent
            let usageNote = total.map { usage in
                " \(TokenUsage.abbreviated(usage.totalTokens)) tokens"
                    + (usage.costSummary.map { ", \($0)" } ?? "")
                    + "."
            } ?? ""
            await emit(
                kind: decision.historyKind,
                repository: repository,
                pullRequest: pullRequest,
                message: "\(decision.title) — \(verdicts).\(reconciledNote)\(withheldNote)\(usageNote)",
                usage: total,
                onEvent: onEvent
            )
        } catch {
            // Nothing posted, so the dedup key stays unwritten and the next poll retries —
            // but the attempt is counted, which is what bounds and paces that retry. Any tokens
            // the reviewers already burned are recorded too: a metered panel that finished and
            // then failed to reach GitHub cost exactly as much as one that posted.
            let failures = attempts.recordFailure(for: pendingReview.reviewKey, at: now())
            let message = error.localizedDescription + " " + RetryPolicy.note(
                failures: failures,
                budget: configuration.failureBudget,
                pollIntervalMinutes: configuration.pollIntervalMinutes
            )
            await logger.append(
                "PR \(repository.githubSlug)#\(pullRequest.number) failed: \(message)"
            )
            await onEvent(
                HistoryEntry(
                    kind: .failed,
                    repositoryName: repository.name,
                    repositorySlug: repository.githubSlug,
                    pullRequestNumber: pullRequest.number,
                    pullRequestTitle: pullRequest.title,
                    pullRequestURL: pullRequest.url,
                    message: message,
                    usage: spent
                )
            )
        }

        if let worktreeURL, worktreeAdded {
            // Gated like the checkout: `worktree remove` and the `prune` fallback both
            // rewrite the shared clone's worktree administration, which a concurrent
            // review of the same repository may be adding to right now.
            await gitGate.acquire(repository.githubSlug)
            let cleanup = try? await runner.run(
                "git",
                arguments: [
                    "-C", repository.path,
                    "worktree", "remove", "--force", worktreeURL.path,
                ],
                timeout: 60
            )
            if cleanup?.succeeded != true {
                try? FileManager.default.removeItem(at: worktreeURL)
                _ = try? await runner.run(
                    "git",
                    arguments: ["-C", repository.path, "worktree", "prune"],
                    timeout: 30
                )
            }
            await gitGate.release(repository.githubSlug)
        }
    }

    /// Fetches the pull request and checks its head out in a fresh worktree.
    ///
    /// Held under `gitGate` for the whole sequence: reviews now overlap, and two of
    /// them fetching into the same clone contend for git's ref locks. The gate must be
    /// released on every path — an early `throw` that skipped it would strand every
    /// other pull request in the repository for the rest of the poll.
    ///
    /// Returns the head branch's tip as read back from the clone's `origin` remote right after
    /// fetching it — only non-`nil` for a same-repository pull request with a reported head name,
    /// which is the only case the head branch is fetched at all (see
    /// `PullRequestMetadata.fetchableHeadRefName`); `nil` otherwise, including when the read-back
    /// itself failed. `PullRequestFacts` renders whichever of these actually happened into the
    /// reviewers' prompt.
    private func checkOutPullRequest(
        _ pendingReview: PendingPullRequest,
        at worktree: URL
    ) async throws -> String? {
        let repository = pendingReview.repository
        let metadata = pendingReview.metadata
        let headRefName = metadata.fetchableHeadRefName
        var headTip: String?
        await gitGate.acquire(repository.githubSlug)
        do {
            var fetchArguments = [
                "-C", repository.path,
                "fetch", "--quiet", "origin",
                "refs/pull/\(pendingReview.summary.number)/head",
                // Explicit destination: a bare `refs/heads/<name>` refspec only lands in
                // FETCH_HEAD, and updating `refs/remotes/origin/<name>` alongside it is
                // merely an opportunistic side effect of the clone's configured fetch
                // refspec. `mergePreview` reads that remote-tracking ref, so name it here
                // rather than depending on how this particular clone happens to be set up.
                "+refs/heads/\(metadata.baseRefName)"
                    + ":refs/remotes/origin/\(metadata.baseRefName)",
            ]
            if let headRefName {
                // A same-repository head branch must exist while its pull request stays open —
                // deleting it closes the PR — so a failure fetching it here is a closed-PR race,
                // not a transient error, and failing the review is acceptable.
                fetchArguments.append(
                    "+refs/heads/\(headRefName):refs/remotes/origin/\(headRefName)"
                )
            }
            let fetch = try await runner.run("git", arguments: fetchArguments, timeout: 180)
            guard fetch.succeeded else {
                throw ReviewEngineError.commandFailed("Git fetch failed: \(conciseError(fetch))")
            }

            // Resolved here, inside the gate, rather than after releasing it: a concurrent review
            // of another pull request sharing this clone could move the ref the moment the gate
            // opened, and a read taken outside the lock could then answer for the wrong review.
            // Best-effort: a read-back that fails leaves `headTip` nil, and the facts say so.
            if let headRefName,
               let revParse = try? await runner.run(
                   "git",
                   arguments: [
                       "-C", repository.path,
                       "rev-parse", "--verify", "--quiet",
                       "refs/remotes/origin/\(headRefName)^{commit}",
                   ],
                   timeout: 30
               ),
               revParse.succeeded {
                let trimmed = revParse.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                headTip = trimmed.isEmpty ? nil : trimmed
            }

            // `metadata` was captured at discovery, and a queued review can start many minutes
            // later. If the head branch has moved on since, the commit we would check out is no
            // longer what the pull request proposes, and the review would describe a stale head —
            // so abort before creating the worktree. The old dedup key never recurs and the next
            // discovery keys the new head, so the review is deferred, not lost.
            if let headTip, headTip != metadata.headRefOid {
                throw ReviewEngineError.reviewIncomplete(
                    "The head moved from \(metadata.headRefOid.prefix(8)) to \(headTip.prefix(8)) before the review started; the next poll reviews the new head."
                )
            }

            let addWorktree = try await runner.run(
                "git",
                arguments: [
                    "-C", repository.path,
                    "worktree", "add", "--quiet", "--detach",
                    worktree.path, metadata.headRefOid,
                ],
                timeout: 60
            )
            guard addWorktree.succeeded else {
                throw ReviewEngineError.commandFailed(
                    "Could not create the review worktree: \(conciseError(addWorktree))"
                )
            }
        } catch {
            await gitGate.release(repository.githubSlug)
            throw error
        }
        await gitGate.release(repository.githubSlug)
        return headTip
    }

    /// Replaces the pull request's own Gemini configuration in the scratch checkout
    /// with Review Bot's.
    ///
    /// Gemini CLI reads `<workspace>/.gemini/settings.json` as *executable*
    /// configuration: `hooks` entries are shell commands it runs around the agent
    /// loop, and `mcpServers` entries are child processes it spawns. Neither is a
    /// tool call, so the read-only `--policy` never sees them, and a `SessionStart`
    /// hook runs before the model is asked anything — the review's own prompt and
    /// verdict are irrelevant to it. The worktree is checked out at the pull
    /// request's head, so leaving that path to the branch under review hands it a
    /// shell on the machine running Review Bot. A `.env` beside it is the same
    /// story one step removed: the CLI loads it into the environment those children
    /// inherit.
    ///
    /// No flag closes this. The worktree must be *trusted* — a headless run in an
    /// untrusted folder aborts outright — and trusted is exactly the state in which
    /// Gemini honours the workspace's settings. Nor can a higher settings tier take
    /// a hook back: `hooks` entries concatenate across tiers and `mcpServers`
    /// shallow-merge, so a later tier can only add. What Review Bot does own is the
    /// checkout it prepared, so it owns this path in it: the branch's `.gemini` and
    /// `.env` are removed and Review Bot's own settings are written in their place.
    /// Nothing is hidden from the review — every one of those files is in
    /// `.review-bot-diff.patch`, which is what the reviewers are told to read.
    ///
    /// Done for every review rather than only when Gemini is enabled: the cost is a
    /// directory in a throwaway checkout, and the alternative is a sandbox that
    /// silently depends on a settings toggle elsewhere.
    private func ownGeminiWorkspaceConfiguration(in worktree: URL) throws {
        let manager = FileManager.default
        let directory = worktree.appendingPathComponent(".gemini", isDirectory: true)
        // `removeItem` throws when the path is absent, which is the ordinary case.
        try? manager.removeItem(at: directory)
        try? manager.removeItem(at: worktree.appendingPathComponent(".env"))
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        // Gemini CLI strips comments before parsing, so the file can say why it is
        // here to whoever opens the worktree — or to a reviewer that reads it.
        let settings = """
        // Written by Review Bot, replacing whatever this pull request shipped at
        // this path. Gemini CLI runs `hooks` as shell commands and spawns
        // `mcpServers` as child processes, so the branch under review must not own
        // this file. MCP is blocked at the command line as well.
        {
          "hooksConfig": { "enabled": false },
          "advanced": { "ignoreLocalEnv": true }
        }
        """
        try Data(settings.utf8).write(
            to: directory.appendingPathComponent("settings.json"),
            options: .atomic
        )
    }

    private func watchingStatus(repositoryCount: Int, deferredRequests: Int) -> String {
        let watching = "Watching \(repositoryCount) repositor\(repositoryCount == 1 ? "y" : "ies")"
        guard deferredRequests > 0 else { return watching }
        return watching
            + " — \(deferredRequests) request\(deferredRequests == 1 ? "" : "s") paused after repeated failures; Run now retries"
    }

    private func pullRequestMetadata(
        number: Int,
        repository: RepositoryConfiguration
    ) async throws -> PullRequestMetadata {
        let result = try await runner.run(
            "gh",
            arguments: [
                "pr", "view", String(number),
                "--repo", repository.githubSlug,
                "--json", "title,headRefOid,headRefName,isCrossRepository,baseRefName,baseRefOid,url",
            ],
            timeout: 60
        )
        guard result.succeeded else {
            throw ReviewEngineError.commandFailed(
                "Could not read PR #\(number): \(conciseError(result))"
            )
        }
        do {
            return try JSONDecoder().decode(PullRequestMetadata.self, from: Data(result.stdout.utf8))
        } catch {
            throw ReviewEngineError.invalidResponse("Could not decode PR #\(number) metadata.")
        }
    }

    private func latestReviewRequestMarker(
        number: Int,
        repository: RepositoryConfiguration,
        githubUser: String,
        fallback: String
    ) async throws -> String {
        let expression = ".[] | select(.event==\"review_requested\" and .requested_reviewer.login==\"\(githubUser)\") | .created_at"
        let result = try await runner.run(
            "gh",
            arguments: [
                "api", "repos/\(repository.githubSlug)/issues/\(number)/timeline",
                "--paginate", "--jq", expression,
            ],
            timeout: 60
        )
        // Never fall back to the head OID on a failed lookup: that key is usually one
        // an earlier review already recorded, so a rate limit or a network blip would
        // silently swallow a genuine re-request at the same commit. Fail instead, and
        // let the caller record it and retry. The fallback stays for the honest case —
        // a timeline with no `review_requested` event for this user.
        guard result.succeeded else {
            throw ReviewEngineError.commandFailed(
                "Could not read the review request timeline for #\(number): \(conciseError(result))"
            )
        }

        return result.stdout
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .sorted()
            .last ?? fallback
    }

    /// The untrusted text the reviewers will read: the PR thread and the diff.
    /// `InjectionGuard` scans both for planted verdicts before an approval may post.
    private struct ReviewContext {
        let thread: String
        let diff: String
    }

    private func prepareReviewContext(
        number: Int,
        repository: RepositoryConfiguration,
        worktree: URL,
        scope: ReviewScope,
        priorHead: String?,
        metadata: PullRequestMetadata
    ) async throws -> ReviewContext {
        let currentHead = metadata.headRefOid
        let narrowedDiff = scope == .incremental
            ? await incrementalDiffText(
                repository: repository,
                priorHead: priorHead,
                currentHead: currentHead
            )
            : nil

        let diffText: String
        if let narrowedDiff {
            diffText = narrowedDiff
        } else {
            let diff = try await runner.run(
                "gh",
                arguments: ["pr", "diff", String(number), "--repo", repository.githubSlug],
                timeout: 120
            )
            guard diff.succeeded else {
                throw ReviewEngineError.commandFailed("Could not download the PR diff: \(conciseError(diff))")
            }
            diffText = diff.stdout
        }
        try Data(diffText.utf8).write(
            to: worktree.appendingPathComponent(".review-bot-diff.patch"),
            options: .atomic
        )

        // When we narrowed the diff to the new commits, tell the reviewers so they focus on the
        // delta and don't re-flag already-reviewed code. Prepended to the thread they already read.
        let scopeNote = narrowedDiff != nil && priorHead != nil
            ? """
            ## Review scope

            This is an **incremental** review. `.review-bot-diff.patch` contains only the changes made \
            since commit `\(priorHead!.prefix(8))`, which was already reviewed. The full pull request is \
            checked out for context — read any file you need — but only flag defects in this delta; \
            code from earlier commits is out of scope and was covered by the previous review.


            """
            : ""

        // What the diff cannot show: how this pull request interacts with a base branch that has
        // moved since it was cut. Best-effort in one direction only — a repository whose base ref
        // could not be resolved still gets a review, just without the merge section. Writing the
        // file is not best-effort: the alternative to a written preview is a *removed* one, since
        // this is the single context file the bot does not always overwrite and the prompt reads
        // its absence as "the PR is current with its base".
        let mergePreviewFile = worktree.appendingPathComponent(".review-bot-merge.md")
        if let preview = await mergePreview(repository: repository, metadata: metadata) {
            try Data(preview.render().utf8).write(to: mergePreviewFile, options: .atomic)
        } else {
            try removePullRequestCopy(of: mergePreviewFile)
        }

        async let conversation = captureCommand {
            try await self.runner.run(
                "gh",
                arguments: [
                    "pr", "view", String(number),
                    "--repo", repository.githubSlug,
                    "--comments",
                ],
                timeout: 90
            )
        }
        async let reviews = captureCommand {
            try await self.runner.run(
                "gh",
                arguments: [
                    "api", "repos/\(repository.githubSlug)/pulls/\(number)/reviews",
                    "--jq", #".[] | "\n### \(.user.login) — \(.state) (\(.submitted_at // "?"))\n\(.body // "_(no summary)_")""#,
                ],
                timeout: 90
            )
        }
        async let inlineComments = captureCommand {
            try await self.runner.run(
                "gh",
                arguments: [
                    "api", "repos/\(repository.githubSlug)/pulls/\(number)/comments",
                    "--jq", #".[] | "- `\(.path):\(.line // .original_line // "?")` — **\(.user.login)**: \(.body)""#,
                ],
                timeout: 90
            )
        }

        let contextResults = await (conversation, reviews, inlineComments)
        let thread = scopeNote + """
        ## Pull request and conversation

        \(contextResults.0.successfulOutput)

        ## Formal reviews

        \(contextResults.1.successfulOutput)

        ## Inline review comments

        \(contextResults.2.successfulOutput)
        """
        try Data(thread.utf8).write(
            to: worktree.appendingPathComponent(".review-bot-thread.md"),
            options: .atomic
        )
        return ReviewContext(thread: thread, diff: diffText)
    }

    /// Removes a Review Bot context file that the pull request itself committed at the same path.
    ///
    /// The review worktree is checked out at the pull request's head, so every `.review-bot-*`
    /// path is content the author controls until the bot overwrites it — and the prompt presents
    /// those files to the reviewers as Review Bot's own evidence, verdict lines included. Files
    /// the bot always writes are safe by construction; this is for the ones it may not write.
    /// A removal that fails throws: reviewing against planted context is worse than not reviewing.
    private func removePullRequestCopy(of file: URL) throws {
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        do {
            try FileManager.default.removeItem(at: file)
        } catch {
            throw ReviewEngineError.commandFailed(
                "Could not remove the \(file.lastPathComponent) committed by the pull request: "
                    + error.localizedDescription
            )
        }
    }

    /// How this pull request interacts with a base branch that may have moved since it was cut, or
    /// `nil` when that cannot be determined (the base ref is not present locally, so there is
    /// nothing honest to say).
    ///
    /// Every command here is read-only plumbing against the shared clone — the review worktree is
    /// never touched, and no merge is ever performed. `merge-tree --write-tree` computes the merge
    /// in memory and writes only to the object store.
    private func mergePreview(
        repository: RepositoryConfiguration,
        metadata: PullRequestMetadata
    ) async -> MergePreview? {
        func git(_ arguments: [String], timeout: Int = 60) async -> CommandResult? {
            let result = try? await runner.run(
                "git",
                arguments: ["-C", repository.path] + arguments,
                timeout: timeout
            )
            return result
        }
        func lines(_ result: CommandResult?) -> [String] {
            guard let result, result.succeeded else { return [] }
            return result.stdout
                .split(whereSeparator: \.isNewline)
                .map(String.init)
                .filter { !$0.isEmpty }
        }

        // `baseRefOid` is a snapshot GitHub took of the base ref, not its live tip. Once an author
        // merges the base branch in, that snapshot becomes an ancestor of the head, `behind`
        // collapses to 0, and the preview silently disappears — precisely in the case it exists
        // for, since a branch that has been synced once is the one most likely to drift again.
        // `prepareReviewContext` fetches the base into `refs/remotes/origin/<name>` immediately
        // before this, so prefer that ref and fall back to the snapshot only when it will not
        // resolve (an unusual remote layout, or a base branch deleted since the fetch).
        let head = metadata.headRefOid
        let trackedBase = await git([
            "rev-parse", "--verify", "--quiet",
            "refs/remotes/origin/\(metadata.baseRefName)^{commit}",
        ])
        let base = trackedBase.flatMap { result -> String? in
            guard result.succeeded else { return nil }
            let oid = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            return oid.isEmpty ? nil : oid
        } ?? metadata.baseRefOid

        guard let mergeBaseResult = await git(["merge-base", base, head]),
              mergeBaseResult.succeeded,
              case let mergeBase = mergeBaseResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines),
              !mergeBase.isEmpty
        else { return nil }

        // Already current with the base: the three-dot diff is exactly what lands, so skip the
        // remaining plumbing rather than paying for it to describe an empty overlap.
        let behind = lines(await git(["rev-list", "--count", "\(mergeBase)..\(base)"])).first
            .flatMap(Int.init) ?? 0
        guard behind > 0 else { return nil }

        // Commits are not content. A release pull request (base `main`, head `develop`) is merged
        // with a merge commit, so `main` collects commits `develop` never receives while its tree
        // stays equal to the `develop` commit each release shipped. `behind` counts every one of
        // those merges, so on its own it describes a base that "moved" without changing a line —
        // noise that grows with every release, and that reviewers have read as evidence the pull
        // request is a stale side branch. Exit 0 here means the base changed no content since the
        // merge base, so there is nothing to preview and "behind N" is never reported. Exit 1 is
        // a real change; any other answer is unknown, and unknown is not clean — both fall
        // through. `--no-ext-diff` keeps a configured external diff driver out of a probe whose
        // exit code decides control flow.
        let baseTreeDiff = await git(["diff", "--quiet", "--no-ext-diff", mergeBase, base], timeout: 120)
        if baseTreeDiff?.exitCode == 0 { return nil }

        // `merge-tree` exits 1 on conflicts and >1 on real errors (notably a git older than 2.38,
        // which has no `--write-tree`). Only treat 0 and 1 as an answer.
        let mergeTree = await git(["merge-tree", "--write-tree", "--name-only", base, head], timeout: 120)
        let mergeTreeOutput = (mergeTree?.exitCode ?? 2) <= 1 ? mergeTree?.stdout : nil

        let prChanged = lines(await git(["diff", "--name-only", mergeBase, head], timeout: 120))
        let baseChanged = lines(await git(["diff", "--name-only", mergeBase, base], timeout: 120))
        let prDeleted = lines(
            await git(["diff", "--diff-filter=D", "--name-only", mergeBase, head], timeout: 120)
        )

        // The base branch's own changes, restricted to the paths this pull request also touched.
        // Unrestricted this is routinely an order of magnitude larger and none of the excess is
        // evidence, so the restriction is what makes inlining it affordable at all.
        let overlap = Set(prChanged).intersection(Set(baseChanged)).sorted()
        let baseSideDiff = overlap.isEmpty
            ? ""
            : (await git(["diff", mergeBase, base, "--"] + overlap, timeout: 120))
                .flatMap { $0.succeeded ? $0.stdout : nil } ?? ""

        return MergePreview.compose(
            baseRefName: metadata.baseRefName,
            behindCount: behind,
            mergeTreeOutput: mergeTreeOutput,
            prChangedPaths: prChanged,
            baseChangedPaths: baseChanged,
            prDeletedPaths: prDeleted,
            baseSideDiff: baseSideDiff
        )
    }

    /// The unified diff between the last-reviewed commit and the current head, or `nil` when an
    /// incremental diff isn't possible or meaningful (no prior head, head unchanged, the prior
    /// commit is no longer present locally, or the delta is empty). Callers fall back to the full
    /// PR diff on `nil`.
    private func incrementalDiffText(
        repository: RepositoryConfiguration,
        priorHead: String?,
        currentHead: String
    ) async -> String? {
        guard let priorHead, priorHead != currentHead else { return nil }

        // The prior commit may have been garbage-collected or force-pushed away; only diff against
        // it if it is still an object we can read.
        let exists = try? await runner.run(
            "git",
            arguments: ["-C", repository.path, "cat-file", "-e", "\(priorHead)^{commit}"],
            timeout: 30
        )
        guard exists?.succeeded == true else { return nil }

        let diff = try? await runner.run(
            "git",
            arguments: ["-C", repository.path, "diff", priorHead, currentHead],
            timeout: 120
        )
        guard let diff, diff.succeeded else { return nil }
        return diff.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : diff.stdout
    }

    private func runReviewers(
        configuration: ReviewBotConfiguration,
        worktree: URL,
        repositoryRules: String?,
        pullRequestFacts: String?,
        credentials: ResolvedCredentials
    ) async -> [ReviewerResult] {
        let prompt = DefaultPrompt.combined(
            with: configuration.customPrompt,
            repositoryRules: repositoryRules,
            pullRequestFacts: pullRequestFacts
        )

        // Runs every enabled reviewer in parallel, preserving a deterministic
        // output order (Claude, Codex, opencode, Gemini) regardless of completion order.
        let enabled: [(ReviewerName, ReviewerConfiguration)] = [
            (.claude, configuration.claude),
            (.codex, configuration.codex),
            (.opencode, configuration.opencode),
            (.gemini, configuration.gemini),
        ].filter { $0.1.enabled }

        let order = Dictionary(uniqueKeysWithValues: enabled.enumerated().map { ($0.element.0, $0.offset) })
        var results = await withTaskGroup(of: ReviewerResult.self) { group in
            for (name, reviewer) in enabled {
                group.addTask {
                    await self.runReviewer(
                        name,
                        configuration: reviewer,
                        prompt: prompt,
                        worktree: worktree,
                        credentials: credentials
                    )
                }
            }
            return await group.reduce(into: []) { $0.append($1) }
        }
        results.sort { order[$0.reviewer, default: 0] < order[$1.reviewer, default: 0] }
        return results
    }

    /// How many times one reviewer may be run within a single review. The worktree,
    /// diff and thread are already prepared at this point, so a second run costs one
    /// CLI invocation rather than the whole pipeline — worth it for a crash, a
    /// transient API error, or a missing verdict line, which would otherwise discard
    /// every other reviewer's work and wait out a poll interval.
    private static let reviewerAttemptsPerReview = 2

    private func runReviewer(
        _ name: ReviewerName,
        configuration: ReviewerConfiguration,
        prompt: String,
        worktree: URL,
        credentials: ResolvedCredentials
    ) async -> ReviewerResult {
        var result = await runReviewerOnce(
            name,
            configuration: configuration,
            prompt: prompt,
            worktree: worktree,
            credentials: credentials
        )
        var attempt = 1
        while attempt < Self.reviewerAttemptsPerReview, result.isWorthRetrying {
            await logger.append(
                "\(name.rawValue) \(result.failure.map { "failed (\($0))" } ?? "returned no verdict"); running it again before giving up on this review."
            )
            var retried = await runReviewerOnce(
                name,
                configuration: configuration,
                prompt: prompt,
                worktree: worktree,
                credentials: credentials
            )
            // The abandoned attempt was still billed — including, and especially, when it
            // *failed*, which is the commonest reason to be here at all. Carrying its usage
            // forward rather than letting the second result replace it is the difference
            // between reporting what a metered reviewer cost and reporting half of it, so
            // `failedReviewer` has to keep a failed attempt's usage for this to add up.
            if let alreadySpent = result.usage {
                retried.usage = (retried.usage ?? TokenUsage()) + alreadySpent
            }
            result = retried
            attempt += 1
        }
        if result.failureClass == .terminal, let failure = result.failure {
            await logger.append(
                "\(name.rawValue) failed for a reason a second call cannot fix (\(failure)); skipping the in-review retry and reviewing without it."
            )
        }
        return result
    }

    /// The single door every reviewer run goes through — the panel's and reconciliation's alike —
    /// which is what lets the credential check live here rather than in each `run…` method.
    private func runReviewerOnce(
        _ name: ReviewerName,
        configuration: ReviewerConfiguration,
        prompt: String,
        worktree: URL,
        credentials: ResolvedCredentials
    ) async -> ReviewerResult {
        if let missing = missingCredential(
            for: name,
            configuration: configuration,
            credentials: credentials
        ) {
            return failedReviewer(name, configuration, message: missing)
        }
        switch name {
        case .claude:
            return await runClaude(
                configuration: configuration,
                prompt: prompt,
                worktree: worktree,
                credentials: credentials
            )
        case .codex:
            return await runCodex(
                configuration: configuration,
                prompt: prompt,
                worktree: worktree,
                credentials: credentials
            )
        case .opencode:
            return await runOpencode(
                configuration: configuration,
                prompt: prompt,
                worktree: worktree,
                credentials: credentials
            )
        case .gemini:
            // Session-only (see `ReviewerName.apiKeyEnvironmentVariable`), so no credentials.
            return await runGemini(configuration: configuration, prompt: prompt, worktree: worktree)
        }
    }

    private func runReconciliation(
        results: [ReviewerResult],
        configuration: ReviewBotConfiguration,
        worktree: URL,
        pullRequestFacts: String?,
        credentials: ResolvedCredentials
    ) async -> ReviewerResult {
        // Only reviewers that reached a verdict are adjudicated. `results` keeps the ones that
        // failed so the posted body can disclose a partial panel, but a failed reviewer has no
        // review to reconcile: its `output` is the CLI's error text — an exhausted-quota notice,
        // a model-not-supported line — and pasting that in under a `REVIEW (verdict: unavailable)`
        // header invites the adjudicator to weigh a stack trace as a dissenting opinion. It also
        // cannot be part of the disagreement being resolved, because `gateDisagreement` counts
        // only parsed verdicts.
        let panel = results.compactMap { result in
            result.verdict.map {
                (
                    reviewer: result.reviewer.rawValue,
                    body: VerdictParser.bodyWithoutTrailer(result.output),
                    verdict: $0.rawValue
                )
            }
        }
        let prompt = DefaultPrompt.reconciliation(reviews: panel, pullRequestFacts: pullRequestFacts)

        // Among the enabled reviewers, prefer Claude as adjudicator, then Codex, then Gemini,
        // then opencode — but only among the ones that just produced a verdict on this pull
        // request. A reviewer whose panel run failed is unlikely to answer this call either, and
        // an adjudicator that fails falls back to the strictest verdict, which is the lone
        // blocker reconciliation exists to check. The case that made this concrete: Claude out
        // of quota, Codex `SHOULD_FIX`, opencode `CLEAN` — the disagreement reconciles through
        // Claude, Claude fails again, and the blocker gates the pull request unexamined. Codex
        // adjudicates it instead. Preferring a survivor never weakens the check: reconciliation
        // only runs when two reviewers parsed verdicts, so it always has a candidate that
        // finished, and the fallback below keeps the old configuration-only order for any
        // caller where none did.
        // Dispatching through `runReviewerOnce` rather than reaching for a `run…`
        // method directly is what keeps the credential check in one place: an
        // adjudicator must not start under a login it was not configured to use
        // either. It is `runReviewerOnce` and not `runReviewer` because
        // reconciliation is a single extra pass — a retry here would double the
        // adjudication, not rescue it.
        let enabled: [(name: ReviewerName, configuration: ReviewerConfiguration)] = [
            (.claude, configuration.claude),
            (.codex, configuration.codex),
            (.gemini, configuration.gemini),
            (.opencode, configuration.opencode),
        ].filter { $0.configuration.enabled }
        let finished = Set(results.filter { $0.verdict != nil }.map(\.reviewer))
        let preferred = enabled.first ?? (name: .opencode, configuration: configuration.opencode)
        let adjudicator = enabled.first { finished.contains($0.name) } ?? preferred
        if adjudicator.name != preferred.name {
            await logger.append(
                "\(preferred.name.rawValue) produced no verdict on this pull request, so \(adjudicator.name.rawValue) adjudicates the disagreement instead."
            )
        }
        return await runReviewerOnce(
            adjudicator.name,
            configuration: adjudicator.configuration,
            prompt: prompt,
            worktree: worktree,
            credentials: credentials
        )
    }

    private func loadRepositoryReviewRules(
        repository: RepositoryConfiguration,
        baseCommitSHA: String
    ) async -> String? {
        guard let result = try? await runner.run(
            "git",
            arguments: [
                "-C", repository.path,
                "show", "\(baseCommitSHA):REVIEW.md",
            ],
            timeout: 30
        ), result.succeeded else {
            return nil
        }
        let rules = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return rules.isEmpty ? nil : rules
    }

    /// Hooks are switched off through `--settings` because no tool or permission flag governs
    /// them, and a hook runs as a command on the reviewer's machine with the pull request's
    /// worktree as its working directory. `disableAllHooks` turns hooks off from the user, project
    /// and local sources, the developer's own included. Organization-managed settings outrank
    /// `--settings` and can still override it; that policy belongs to whoever manages them.
    private static let claudeSandboxSettingsJSON = #"{"disableAllHooks":true}"#

    /// `runClaude` backs both an ordinary review and the reconciliation pass
    /// (`runReconciliation`), so every flag here applies to both. Each one closes a specific way
    /// the reviewer could act on more than the pull request's diff, verified against Claude Code
    /// 2.1.212:
    ///
    /// - `--tools Read,Grep,Glob` limits the built-in tool set to read-only inspection: no shell,
    ///   no file edits, no web access, no subagents.
    /// - `--permission-mode dontAsk` denies anything not pre-approved without prompting, and
    ///   overrides a developer's own default permission mode. Reads inside the working directory
    ///   (the worktree) are allowed by default; reads outside it are denied.
    /// - `--allowedTools` is deliberately absent. An allow rule for `Read` is what let reads
    ///   escape the worktree in the first place, and `--allowedTools` only ever *adds*
    ///   permissions — it cannot be used to narrow anything.
    /// - `--setting-sources user`: project and local settings come from the pull request's own
    ///   tree and must never load. The developer's user settings still load, so provider
    ///   configuration kept there (`env`, `apiKeyHelper`) keeps working — the standard `claude`
    ///   login lives in the macOS Keychain and needs no settings at all. Stated honestly: a
    ///   directory or read rule a developer grants in their own user settings still applies, so
    ///   the reviewer is confined to the worktree plus whatever the developer's own settings —
    ///   or an organization's managed settings, which always load — explicitly allow.
    /// - `--settings claudeSandboxSettingsJSON` turns off hooks, the developer's own included —
    ///   see `claudeSandboxSettingsJSON` above.
    /// - `--strict-mcp-config`, with no `--mcp-config` supplied, loads no MCP servers at all —
    ///   neither the developer's nor an `.mcp.json` the pull request ships.
    /// - `--disallowedTools mcp__*` is defense in depth in case an MCP server is loaded anyway.
    ///
    /// An older `claude` CLI that rejects one of these flags fails the reviewer outright, which
    /// the posted review discloses like any other reviewer failure.
    /// The reviewers this review may have to hand a key to. Reconciliation picks its adjudicator
    /// from the enabled reviewers too, so one resolution covers the panel and the adjudicator
    /// both. A reviewer left on session auth is not asked about at all: reading a Keychain item
    /// can raise a modal prompt, and someone who chose the signed-in CLIs should never see one.
    private static func reviewersNeedingKeys(
        in configuration: ReviewBotConfiguration
    ) -> [ReviewerName] {
        ReviewerName.allCases.filter { reviewer in
            let settings = configuration.settings(for: reviewer)
            return settings.enabled && reviewer.supportsAPIKeyAuth && settings.authMode == .apiKey
        }
    }
    /// The environment a CLI reviewer runs with. In `.apiKey` mode the resolved key is injected;
    /// in `.session` mode the variable is explicitly removed, so the CLI uses its own login even
    /// when a key is exported in the developer's shell. A reviewer with no key variable at all —
    /// opencode, which is credentialed through its own config directory — gets no changes, which
    /// is why it needs `OPENCODE_CONFIG_DIR`/`OPENCODE_CONFIG_CONTENT` merged in on top.
    private func environmentOverrides(
        for reviewer: ReviewerName,
        configuration: ReviewerConfiguration,
        credentials: ResolvedCredentials
    ) -> EnvironmentOverrides {
        guard let variable = reviewer.apiKeyEnvironmentVariable else { return [:] }
        guard configuration.authMode == .apiKey else { return [variable: nil] }
        return [variable: credentials.apiKey(for: reviewer)]
    }
    /// `nil` when the reviewer is ready to run, or a message explaining what is missing.
    /// Checked in `runReviewerOnce`, which both the panel and `runReconciliation` dispatch
    /// through — an adjudicator must not start under a login it was not configured to use
    /// either. The message is one `ReviewerFailureClass.classify` calls terminal, so the
    /// in-review retry does not spend a second call — nor the review-level failure budget — on
    /// something only Settings can fix.
    private func missingCredential(
        for reviewer: ReviewerName,
        configuration: ReviewerConfiguration,
        credentials: ResolvedCredentials
    ) -> String? {
        // A reviewer Review Bot cannot hand a key to can never be missing one, whatever mode a
        // hand-edited or migrated `config.json` claims it is in.
        guard reviewer.supportsAPIKeyAuth else { return nil }
        guard configuration.authMode == .apiKey else { return nil }
        guard credentials.apiKey(for: reviewer) == nil else { return nil }
        // A denied Keychain prompt is indistinguishable from an absent item here, and denial is
        // easy to hit because each rebuild re-signs the app and re-triggers the prompt.
        return "\(reviewer.rawValue) is set to API-key auth but its key could not be read — "
            + "either none is saved, or macOS Keychain access was denied. "
            + "Check Settings → Reviewers, or switch it back to the signed-in CLI."
    }
    private func runClaude(
        configuration: ReviewerConfiguration,
        prompt: String,
        worktree: URL,
        credentials: ResolvedCredentials
    ) async -> ReviewerResult {
        do {
            let result = try await runner.run(
                "claude",
                arguments: [
                    "-p", prompt,
                    "--model", configuration.model,
                    "--effort", configuration.effort.rawValue,
                    "--tools", "Read,Grep,Glob",
                    "--permission-mode", "dontAsk",
                    "--setting-sources", "user",
                    "--settings", Self.claudeSandboxSettingsJSON,
                    "--strict-mcp-config",
                    "--disallowedTools", "mcp__*",
                    // JSON rather than text so the CLI's own token counts and dollar cost come
                    // back with the review. Parsed defensively — see `claudeOutput`.
                    "--output-format", "json",
                ],
                currentDirectory: worktree,
                environment: environmentOverrides(
                    for: .claude,
                    configuration: configuration,
                    credentials: credentials
                ),
                stopEarly: Self.stopOnTerminalFailure,
                timeout: 900
            )
            let parsed = claudeOutput(result.stdout)
            guard result.succeeded else {
                // A failing CLI that still emitted the envelope explains itself in `result`;
                // raw JSON in the history would not.
                let explanation = parsed.parsedEnvelope
                    ? parsed.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    : ""
                return failedReviewer(
                    .claude,
                    configuration,
                    message: explanation.isEmpty
                        ? conciseError(result)
                        : String(explanation.prefix(600)),
                    // Billed all the same, and this is the branch the retry usually comes from.
                    usage: parsed.usage
                )
            }
            if let failure = parsed.failure {
                return failedReviewer(
                    .claude,
                    configuration,
                    message: failure,
                    usage: parsed.usage
                )
            }
            return ReviewerResult(
                reviewer: .claude,
                model: configuration.model,
                output: parsed.text,
                verdict: VerdictParser.parse(parsed.text),
                failure: nil,
                usage: parsed.usage
            )
        } catch {
            return failedReviewer(.claude, configuration, error: error)
        }
    }

    private struct CLIReviewOutput {
        let text: String
        let usage: TokenUsage?
        let failure: String?
        /// False when stdout was not the JSON envelope, so callers know `text` is raw output.
        let parsedEnvelope: Bool
    }

    /// Reads Claude's `--output-format json` envelope.
    ///
    /// Falls back to treating stdout as the review verbatim when it is not that envelope, so a
    /// CLI that accepts the flag but prints something else — or a mocked runner in the tests —
    /// behaves exactly as it did before. That is a parsing fallback, not a compatibility probe:
    /// `--output-format json` is passed unconditionally, so a `claude` old enough to *reject*
    /// the flag exits non-zero and the reviewer fails rather than being re-run as text — there
    /// is no capability probe, and a probing re-run would spend a second billed call on every
    /// review to guard against a CLI nobody has reported. Cost comes straight from the CLI, so
    /// there is no price table to keep current.
    private func claudeOutput(_ stdout: String) -> CLIReviewOutput {
        guard let envelope = try? JSONDecoder().decode(
            ClaudeResultEnvelope.self,
            from: Data(stdout.utf8)
        ), let result = envelope.result else {
            return CLIReviewOutput(text: stdout, usage: nil, failure: nil, parsedEnvelope: false)
        }

        let usage = TokenUsage(
            // Cache *writes* are fresh input tokens that happen to have been stored; only reads
            // were served from cache.
            inputTokens: (envelope.usage?.inputTokens ?? 0)
                + (envelope.usage?.cacheCreationInputTokens ?? 0),
            cachedInputTokens: envelope.usage?.cacheReadInputTokens ?? 0,
            outputTokens: envelope.usage?.outputTokens ?? 0,
            requests: 1,
            costUSD: envelope.totalCostUSD
        )
        return CLIReviewOutput(
            text: result,
            usage: usage,
            failure: envelope.isError == true
                ? String(result.trimmingCharacters(in: .whitespacesAndNewlines).prefix(600))
                : nil,
            parsedEnvelope: true
        )
    }

    private struct ClaudeResultEnvelope: Decodable {
        struct Usage: Decodable {
            let inputTokens: Int?
            let outputTokens: Int?
            let cacheReadInputTokens: Int?
            let cacheCreationInputTokens: Int?

            private enum CodingKeys: String, CodingKey {
                case inputTokens = "input_tokens"
                case outputTokens = "output_tokens"
                case cacheReadInputTokens = "cache_read_input_tokens"
                case cacheCreationInputTokens = "cache_creation_input_tokens"
            }
        }

        let result: String?
        let isError: Bool?
        let totalCostUSD: Double?
        let usage: Usage?

        private enum CodingKeys: String, CodingKey {
            case result
            case isError = "is_error"
            case totalCostUSD = "total_cost_usd"
            case usage
        }
    }

    private func runCodex(
        configuration: ReviewerConfiguration,
        prompt: String,
        worktree: URL,
        credentials: ResolvedCredentials
    ) async -> ReviewerResult {
        let outputFile = worktree.appendingPathComponent(".review-bot-codex.md")
        do {
            // codex writes its review here, but the worktree is the pull request's head: a PR can
            // commit its own `.review-bot-codex.md`, and a run that exits 0 without producing one
            // would be read back as codex's review, planted verdict line included. Clear it first,
            // so the only file this reviewer can read is the one this run wrote.
            try removePullRequestCopy(of: outputFile)
            let result = try await runner.run(
                "codex",
                arguments: [
                    "exec",
                    "-C", worktree.path,
                    "-s", "read-only",
                    "-m", configuration.model,
                    "-c", "model_reasoning_effort=\"\(configuration.effort.rawValue)\"",
                    "-o", outputFile.path,
                    prompt,
                ],
                currentDirectory: worktree,
                environment: environmentOverrides(
                    for: .codex,
                    configuration: configuration,
                    credentials: credentials
                ),
                stopEarly: Self.stopOnTerminalFailure,
                timeout: 900
            )
            guard result.succeeded,
                  let output = try? String(contentsOf: outputFile, encoding: .utf8) else {
                return failedReviewer(.codex, configuration, message: conciseError(result))
            }
            return ReviewerResult(
                reviewer: .codex,
                model: configuration.model,
                output: output,
                verdict: VerdictParser.parse(output),
                failure: nil
            )
        } catch {
            return failedReviewer(.codex, configuration, error: error)
        }
    }

    private func runOpencode(
        configuration: ReviewerConfiguration,
        prompt: String,
        worktree: URL,
        credentials: ResolvedCredentials
    ) async -> ReviewerResult {
        // The opencode reviewer runs as a dedicated read-only agent defined in
        // Review Bot's own data directory (never inside the worktree, so a pull
        // request can't supply it). The same deny-all-except-read permission map
        // is also inlined via OPENCODE_CONFIG_CONTENT, which the merge order
        // applies after any opencode.json the pull request itself ships.
        guard ensureOpencodeAgent() else {
            return failedReviewer(
                .opencode,
                configuration,
                message: "could not write the read-only opencode agent file"
            )
        }
        let permissions = #"{"permission":{"*":"deny","read":"allow","grep":"allow","glob":"allow"}}"#
        // opencode reads no API key of its own, so `environmentOverrides` contributes nothing
        // here today. It is still the base of the merge rather than a hardcoded pair, so
        // opencode stays the same shape as every other CLI reviewer if that ever changes; the
        // sandbox variables win any collision, since they are what makes the run read-only.
        let environment = environmentOverrides(
            for: .opencode,
            configuration: configuration,
            credentials: credentials
        )
            .merging(
                [
                    "OPENCODE_CONFIG_DIR": paths.opencodeConfigDirectory.path,
                    "OPENCODE_CONFIG_CONTENT": permissions,
                ]
            ) { _, sandbox in sandbox }
        do {
            let result = try await runner.run(
                "opencode",
                arguments: [
                    "run",
                    // opencode says nothing on its streams when a request fails — an
                    // exhausted usage limit is logged to its own log file and the process
                    // simply never exits (measured: fifteen minutes to the kill, every
                    // review). Printing its error log to stderr is what lets the watch below
                    // see the failure and stop the run in seconds.
                    "--print-logs",
                    "--log-level", "ERROR",
                    "--agent", "review-bot",
                    "--model", configuration.model,
                    "--variant", configuration.effort.rawValue,
                    "--pure",
                    prompt,
                ],
                currentDirectory: worktree,
                environment: environment,
                stopEarly: Self.stopOnTerminalFailure,
                timeout: 900
            )
            guard result.succeeded else {
                return failedReviewer(
                    .opencode,
                    configuration,
                    message: Self.opencodeFailure(from: conciseError(result))
                )
            }
            return ReviewerResult(
                reviewer: .opencode,
                model: configuration.model,
                output: result.stdout,
                verdict: VerdictParser.parse(result.stdout),
                failure: nil
            )
        } catch {
            return failedReviewer(.opencode, configuration, error: error)
        }
    }

    /// The watch every CLI reviewer runs under: the moment a line of its output reads as a
    /// terminal failure — an exhausted quota, a rejected login, an unusable model — the run is
    /// stopped rather than left to its time limit. The classification is the same one that
    /// decides the in-review retry, so a failure that stops a run early is also one that is
    /// not retried, and the panel goes on without that reviewer within seconds.
    static let stopOnTerminalFailure: OutputWatch = { line in
        ReviewerFailureClass.classify(line) == .terminal
    }

    /// opencode's error log lines are `key=value` records ending in `error.error="…"`. The
    /// quoted message is what the developer needs to read; the rest is noise in a posted
    /// disclosure. Anything that is not such a line is returned as it came.
    static func opencodeFailure(from message: String) -> String {
        guard let pattern = try? NSRegularExpression(pattern: #"error\.error="([^"]*)""#) else { return message }
        let whole = NSRange(message.startIndex..., in: message)
        // The last record is the one the run ended on.
        guard let match = pattern.matches(in: message, range: whole).last,
              let range = Range(match.range(at: 1), in: message) else {
            return message
        }
        let quoted = message[range].trimmingCharacters(in: .whitespaces)
        return quoted.isEmpty ? message : quoted
    }

    /// Writes the read-only agent definition opencode runs reviewers under.
    /// Returns `false` (and the reviewer then fails cleanly) if the file cannot
    /// be created.
    private func ensureOpencodeAgent() -> Bool {
        let file = paths.opencodeAgentFile
        do {
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let agent = """
            ---
            description: Review Bot's read-only pull request reviewer
            mode: all
            permission:
              "*": deny
              read: allow
              grep: allow
              glob: allow
            ---
            """
            try Data(agent.utf8).write(to: file, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    private func runGemini(
        configuration: ReviewerConfiguration,
        prompt: String,
        worktree: URL
    ) async -> ReviewerResult {
        guard ensureGeminiPolicy() else {
            return failedReviewer(
                .gemini,
                configuration,
                message: "could not write the read-only Gemini policy file"
            )
        }
        do {
            let result = try await runner.run(
                "gemini",
                arguments: [
                    "--model", configuration.model,
                    "--policy", paths.geminiPolicyFile.path,
                    // The worktree is a scratch checkout the user has never opened,
                    // so Gemini would otherwise refuse it as an untrusted folder.
                    // Trusting it is also what makes `ownGeminiWorkspaceConfiguration`
                    // necessary: a trusted workspace's `.gemini` is configuration the
                    // CLI executes.
                    "--skip-trust",
                    // Reviews must not depend on whichever extensions the user
                    // happens to have installed — or on ones the branch ships.
                    "--extensions", "none",
                    // Gemini has no `--disallowedTools mcp__*`: the only lever is an
                    // allowlist, and a name no server answers to blocks every one of
                    // them. That includes the user's own — an MCP tool is not one of
                    // the names the read-only policy denies, so a configured server
                    // would hand a reviewer of untrusted code a way out of Read,
                    // Grep and Glob. The name is generated per run so that a pull
                    // request cannot claim it by naming a server after the constant.
                    "--allowed-mcp-server-names", "review-bot-no-mcp-\(UUID().uuidString)",
                    "--output-format", "json",
                    "--prompt", prompt,
                ],
                currentDirectory: worktree,
                environment: [:],
                stopEarly: Self.stopOnTerminalFailure,
                timeout: 900
            )
            guard result.succeeded else {
                return failedReviewer(.gemini, configuration, message: conciseError(result))
            }
            let output = Self.geminiResponse(result.stdout)
            return ReviewerResult(
                reviewer: .gemini,
                model: configuration.model,
                output: output,
                verdict: VerdictParser.parse(output),
                failure: nil
            )
        } catch {
            return failedReviewer(.gemini, configuration, error: error)
        }
    }

    /// Writes the policy that keeps the Gemini reviewer read-only. Returns `false`
    /// (and the reviewer then fails cleanly) if the file cannot be created.
    ///
    /// `--policy` loads it into Gemini's *user* tier, which outranks the
    /// `.gemini/` settings and policies a pull request can ship in its own tree
    /// (those are workspace tier). Headless Gemini already denies the mutating
    /// tools, so this is a second lock on the same door — except for the plan-mode
    /// pair, which is not belt-and-braces: a non-interactive run auto-approves
    /// `exit_plan_mode`, and leaving plan mode switches the CLI into YOLO.
    private func ensureGeminiPolicy() -> Bool {
        let file = paths.geminiPolicyFile
        do {
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let policy = """
            [[rule]]
            toolName = [
              "run_shell_command",
              "write_file",
              "replace",
              "activate_skill",
              "web_fetch",
              "google_web_search",
              "enter_plan_mode",
              "exit_plan_mode"
            ]
            decision = "deny"
            priority = 900
            """
            try Data(policy.utf8).write(to: file, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// `gemini --output-format json` wraps the answer in `{"response": …}`, which
    /// keeps the reviewer's Markdown clean of the CLI's own chatter. Falls back to
    /// raw stdout so a build that prints plain text still yields a parsable verdict.
    static func geminiResponse(_ stdout: String) -> String {
        struct Payload: Decodable { let response: String }
        guard let payload = try? JSONDecoder().decode(
            Payload.self,
            from: Data(stdout.utf8)
        ) else {
            return stdout
        }
        return payload.response
    }

    private func failedReviewer(
        _ reviewer: ReviewerName,
        _ configuration: ReviewerConfiguration,
        error: Error
    ) -> ReviewerResult {
        var timedOut = false
        if let commandError = error as? CommandExecutionError,
           case .timedOut = commandError {
            timedOut = true
        }
        return failedReviewer(
            reviewer,
            configuration,
            message: error.localizedDescription,
            timedOut: timedOut
        )
    }

    /// A failure that still reports what it consumed must carry it. A provider bills a call that
    /// errored exactly like one that succeeded, and a failure is the *dominant* trigger for the
    /// in-review retry (`ReviewerResult.isWorthRetrying`), so dropping the usage here would
    /// under-report the retried review — the one case this feature exists to get right.
    /// `usage` stays `nil` where there is genuinely nothing to report: a command that threw
    /// before producing output, a timeout, a missing key caught before the CLI ever ran.
    private func failedReviewer(
        _ reviewer: ReviewerName,
        _ configuration: ReviewerConfiguration,
        message: String,
        timedOut: Bool = false,
        usage: TokenUsage? = nil
    ) -> ReviewerResult {
        ReviewerResult(
            reviewer: reviewer,
            model: configuration.model,
            output: "_\(reviewer.rawValue) review failed: \(message)_",
            verdict: nil,
            failure: message,
            timedOut: timedOut,
            usage: usage
        )
    }

    /// Everything the developer is billed per token for, across the reviewers and the adjudicator.
    ///
    /// A result is counted on its `usage`, not on whether it succeeded — a reviewer whose call
    /// errored, and an adjudicator that came back without a verdict, were both billed.
    /// Session-auth CLI reviewers are deliberately excluded: their cost is a flat subscription, so
    /// attributing dollars to one review would be fiction. Always computed, regardless of whether
    /// the report is posted, so history and the logs can total spend either way.
    private func meteredUsage(
        results: [ReviewerResult],
        adjudication: ReviewerResult?,
        configuration: ReviewBotConfiguration
    ) -> [(reviewer: ReviewerName, model: String, usage: TokenUsage, isAdjudicator: Bool)] {
        let entries = results.map { ($0, false) } + (adjudication.map { [($0, true)] } ?? [])
        return entries.compactMap { result, isAdjudicator in
            guard configuration.settings(for: result.reviewer).authMode == .apiKey,
                  let usage = result.usage else {
                return nil
            }
            return (result.reviewer, result.model, usage, isAdjudicator)
        }
    }

    private func usageTotal(
        results: [ReviewerResult],
        adjudication: ReviewerResult?,
        configuration: ReviewBotConfiguration
    ) -> TokenUsage? {
        let metered = meteredUsage(
            results: results,
            adjudication: adjudication,
            configuration: configuration
        )
        guard !metered.isEmpty else { return nil }
        return metered.map(\.usage).reduce(TokenUsage(), +)
    }

    /// The usage section appended to the posted review, or `nil` when it is switched off or there
    /// is nothing metered to report.
    private func usageReport(
        results: [ReviewerResult],
        adjudication: ReviewerResult?,
        configuration: ReviewBotConfiguration
    ) -> String? {
        guard configuration.includeUsageInReview else { return nil }
        let metered = meteredUsage(
            results: results,
            adjudication: adjudication,
            configuration: configuration
        )
        guard !metered.isEmpty,
              let total = usageTotal(
                  results: results,
                  adjudication: adjudication,
                  configuration: configuration
              ) else {
            return nil
        }

        let rows = metered.map { entry in
            let label = entry.isAdjudicator
                ? "\(entry.reviewer.rawValue) (reconciliation)"
                : entry.reviewer.rawValue
            let cost = entry.usage.costSummary ?? "not reported"
            return "| \(label) | `\(entry.model)` | \(entry.usage.tokenSummary) | \(cost) |"
        }.joined(separator: "\n")

        let totalCost = total.costSummary.map { " — **\($0)**" } ?? ""
        return """


        <details><summary><strong>Token usage and cost\(totalCost)</strong></summary>

        | Reviewer | Model | Tokens | Cost |
        | --- | --- | --- | --- |
        \(rows)

        \(TokenUsage.abbreviated(total.totalTokens)) tokens in total, as reported by the \
        reviewers themselves. Only reviewers billed per token are listed; reviewers using a \
        signed-in CLI are covered by its subscription.

        </details>
        """
    }

    private func aggregateReview(
        pullRequest: PullRequestSummary,
        commitSHA: String,
        results: [ReviewerResult],
        decision: ReviewDecision,
        adjudication: ReviewerResult?,
        guardReason: InjectionGuard.Reason?,
        approvalWithheldForPartialPanel: Bool,
        usageReport: String?
    ) -> String {
        let verdictSummary = results.map {
            "\($0.reviewer.rawValue): `\($0.verdict?.rawValue ?? "unavailable")`"
        }.joined(separator: ", ")
        // Only reviewers that produced a verdict get a details block; a failed one has no
        // review body to show, and an empty disclosure triangle reads as an empty review
        // rather than an absent one. The blockquote below names them instead.
        let details = results.filter { $0.verdict != nil }.map { result in
            """
            <details><summary><strong>\(result.reviewer.rawValue) — \(result.model)</strong></summary>

            \(VerdictParser.bodyWithoutTrailer(result.output))

            </details>
            """
        }.joined(separator: "\n\n")
        let note: String
        switch decision {
        case .approve:
            note = "No reviewer found an issue the current decision policy blocks on."
        case .requestChanges:
            note = "At least one reviewer found an issue the current decision policy treats as blocking."
        case .comment:
            if approvalWithheldForPartialPanel {
                note = "The decision policy would approve this, but **a partial panel never approves**, so it posts as a neutral comment. Re-request the review once every enabled reviewer can run."
            } else {
                note = guardReason == nil
                    ? "This review is neutral because the current decision policy leaves this severity to you."
                    : "An automated injection check flagged this approval as unsafe, so the review posts as a neutral comment instead."
            }
        }

        // A decision reached by part of the panel is a weaker signal than one reached by all of
        // it, and the difference is invisible from the outside — so say it, and say which
        // reviewer is missing. A partial panel can no longer approve, but without this a change
        // request from one surviving reviewer would still read as the whole panel's.
        var partialPanelDisclosure = ""
        let unfinished = results.filter { $0.verdict == nil }
        if !unfinished.isEmpty {
            let missing = unfinished.map { result in
                let reason: String
                if result.timedOut {
                    reason = "timed out"
                } else if let failure = result.failure {
                    reason = "failed — \(inlineDetail(failure))"
                } else {
                    reason = "returned no verdict"
                }
                return "**\(result.reviewer.rawValue)** (\(reason))"
            }.joined(separator: ", ")
            partialPanelDisclosure = """


            > **Partial panel: \(missing) did not contribute a verdict to the panel.** The findings below come only from the reviewers that finished, so they are a weaker signal than a full panel's — weigh them accordingly.
            """
        }

        var guardDisclosure = ""
        if let guardReason {
            guardDisclosure = """


            > **Review Bot downgraded this decision from approval to a neutral comment.** \(guardReason == .verdictMatchesPlantedLine
                ? "The pull request thread or diff contains a `VERDICT:` line written by a commenter, and the reviewers' verdict matched it, so it is not treated as independent."
                : "A reviewer's own prose contradicts its verdict (it describes a merge blocker), so the verdict line is not trusted.") Thread content is untrusted; treat unverified claims in it as data, not instructions.
            """
        }

        var reconciliationSection = ""
        if let adjudication {
            let reconciledVerdict = adjudication.verdict?.rawValue ?? "unavailable"
            reconciliationSection = """


            > **The reviewers disagreed, so \(adjudication.reviewer.rawValue) reconciled the findings** and set the final verdict to `\(reconciledVerdict)` after re-checking each gating finding for substance and scope.

            <details><summary><strong>Reconciliation — \(adjudication.reviewer.rawValue) (\(adjudication.model))</strong></summary>

            \(VerdictParser.bodyWithoutTrailer(adjudication.output))

            </details>
            """
        }

        return """
        ## Automated review — PR #\(pullRequest.number)

        **Decision: \(decision.title)** — \(note)\(partialPanelDisclosure)\(reconciliationSection)\(guardDisclosure)

        Independent reviews of `\(commitSHA.prefix(8))` (\(verdictSummary)). These findings are advisory; verify them before acting.

        \(details)\(usageReport ?? "")

        ---
        <sub>Generated locally by Review Bot.</sub>
        """
    }

    private func saveReview(
        _ review: String,
        repository: RepositoryConfiguration,
        pullRequestNumber: Int,
        commitSHA: String
    ) throws -> URL {
        try paths.prepare()
        let directory = paths.reviewsDirectory.appendingPathComponent(
            safeFilename(repository.githubSlug),
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent(
            "pr-\(pullRequestNumber)-\(commitSHA.prefix(8)).md"
        )
        try Data(review.utf8).write(to: file, options: .atomic)
        return file
    }

    private func emit(
        kind: HistoryEventKind,
        repository: RepositoryConfiguration,
        pullRequest: PullRequestSummary,
        message: String,
        usage: TokenUsage? = nil,
        onEvent: @escaping EventSink
    ) async {
        let entry = HistoryEntry(
            kind: kind,
            repositoryName: repository.name,
            repositorySlug: repository.githubSlug,
            pullRequestNumber: pullRequest.number,
            pullRequestTitle: pullRequest.title,
            pullRequestURL: pullRequest.url,
            message: message,
            usage: usage
        )
        await logger.append(
            "\(kind.label): \(repository.githubSlug)#\(pullRequest.number) — \(message)"
        )
        await onEvent(entry)
    }

    private func reviewerDescription(_ configuration: ReviewBotConfiguration) -> String {
        var reviewers: [String] = []
        if configuration.claude.enabled {
            reviewers.append("Claude (\(configuration.claude.effort.label))")
        }
        if configuration.codex.enabled {
            reviewers.append("Codex (\(configuration.codex.effort.label))")
        }
        if configuration.opencode.enabled {
            reviewers.append("opencode (\(configuration.opencode.effort.label))")
        }
        // No effort for Gemini: its CLI has no such flag, so naming one would lie.
        if configuration.gemini.enabled {
            reviewers.append("Gemini")
        }
        return "Running " + reviewers.joined(separator: " and ") + "."
    }

    private func captureCommand(
        _ operation: @escaping () async throws -> CommandResult
    ) async -> Result<CommandResult, Error> {
        do {
            return .success(try await operation())
        } catch {
            return .failure(error)
        }
    }

    /// The reason a command failed, which is at the *end* of its output, not the beginning.
    /// `codex` echoes the whole review prompt to stdout before it fails, so taking the first
    /// characters reported the prompt instead of the error — an exhausted quota logged as
    /// "Reading additional input from stdin…", which is neither actionable to read nor
    /// classifiable by `ReviewerFailureClass`. Prefer stderr, then any lines that announce an
    /// error, then the tail.
    private func conciseError(_ result: CommandResult) -> String {
        let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if !stderr.isEmpty { return String(stderr.suffix(600)) }

        let stdout = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if stdout.isEmpty { return "command exited with status \(result.exitCode)" }

        let errorLines = stdout
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter {
                $0.range(
                    of: #"(?i)\b(error|failure|failed|fatal|panic|unauthorized)\b"#,
                    options: .regularExpression
                ) != nil
            }
        if !errorLines.isEmpty {
            return String(errorLines.suffix(4).joined(separator: " ").suffix(600))
        }
        return String(stdout.suffix(600))
    }

    /// Squeezes a captured failure onto one line for a posted Markdown blockquote. The text is a
    /// CLI's own output rather than anything a pull request controls, but it still lands in a
    /// public comment, so keep it short and strip the characters that would break out of the
    /// quote or open a code span.
    ///
    /// Keeps the **tail**, for the same reason `conciseError` does: a CLI states its diagnosis
    /// last, after whatever it echoed on the way there. Codex echoes the entire prompt — which
    /// embeds `REVIEW.md` — to stderr before failing, so taking the head published a slab of the
    /// repository's review rules to a public PR comment and none of the actual error.
    private func inlineDetail(_ value: String, limit: Int = 180) -> String {
        let flattened = value
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .replacingOccurrences(of: "`", with: "'")
        return flattened.count > limit
            ? "…" + String(flattened.suffix(limit)).trimmingCharacters(in: .whitespaces)
            : flattened
    }

    private func safeFilename(_ value: String) -> String {
        value.replacingOccurrences(
            of: #"[^A-Za-z0-9._-]+"#,
            with: "-",
            options: .regularExpression
        )
    }

    private func shortMarker(_ value: String) -> String {
        value.contains("T") ? value : String(value.prefix(8))
    }
}

private extension Result where Success == CommandResult, Failure == Error {
    var successfulOutput: String {
        switch self {
        case let .success(result) where result.succeeded:
            result.stdout
        case let .success(result):
            "_(Unavailable: command exited with status \(result.exitCode).)_"
        case let .failure(error):
            "_(Unavailable: \(error.localizedDescription))_"
        }
    }
}
