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
        // Deliberately not an enumeration of the reviewers: that sentence went stale every time
        // one was added, and the settings tab lists them anyway.
        case .noReviewersEnabled: "Enable at least one AI reviewer before running reviews."
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
    private let chatClient: any ChatCompleting
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
    /// for the Keychain, `chatClient` so a DeepSeek test never reaches the real API, and `now`
    /// for the retry backoff, which is otherwise untestable in a poll-interval-sized test.
    init(
        paths: StoragePaths,
        runner: any CommandRunning = ProcessRunner(),
        credentials: any CredentialStoring = KeychainCredentialStore(),
        chatClient: any ChatCompleting = DeepSeekClient(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.paths = paths
        self.runner = runner
        credentialStore = credentials
        self.chatClient = chatClient
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
        // Derived from `ReviewerName.allCases` rather than a chain of `||`, which stops being
        // exhaustive the moment a reviewer is added: a DeepSeek-only configuration would then be
        // reported as having no reviewers and never poll at all.
        guard !configuration.enabledReviewers.isEmpty else {
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

            try await checkOutPullRequest(pendingReview, at: worktree)
            worktreeAdded = true

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
                        + "; the review discloses that it is a partial panel."
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
            var guardReason: InjectionGuard.Reason?
            if decision == .approve {
                // The guard sees Review Bot's own copies of the thread and the diff, which is
                // everything a CLI reviewer was handed. It is not everything a reviewer *read*:
                // DeepSeek opens files itself through `WorktreeTools`, and no reviewer's view of
                // the repository is bounded by the diff — so a `VERDICT:` line planted in a file
                // the pull request does not touch is outside this check by construction. The
                // review contract's untrusted-input section is what covers that case.
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

            let post = try await runner.run(
                "gh",
                arguments: [
                    "pr", "review", String(pullRequest.number),
                    "--repo", repository.githubSlug,
                    decision.ghArgument,
                    "--body-file", reviewFile.path,
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
                message: "\(decision.title) — \(verdicts).\(reconciledNote)\(usageNote)",
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
    private func checkOutPullRequest(
        _ pendingReview: PendingPullRequest,
        at worktree: URL
    ) async throws {
        let repository = pendingReview.repository
        await gitGate.acquire(repository.githubSlug)
        do {
            let fetch = try await runner.run(
                "git",
                arguments: [
                    "-C", repository.path,
                    "fetch", "--quiet", "origin",
                    "refs/pull/\(pendingReview.summary.number)/head",
                    // Explicit destination: a bare `refs/heads/<name>` refspec only lands in
                    // FETCH_HEAD, and updating `refs/remotes/origin/<name>` alongside it is
                    // merely an opportunistic side effect of the clone's configured fetch
                    // refspec. `mergePreview` reads that remote-tracking ref, so name it here
                    // rather than depending on how this particular clone happens to be set up.
                    "+refs/heads/\(pendingReview.metadata.baseRefName)"
                        + ":refs/remotes/origin/\(pendingReview.metadata.baseRefName)",
                ],
                timeout: 180
            )
            guard fetch.succeeded else {
                throw ReviewEngineError.commandFailed("Git fetch failed: \(conciseError(fetch))")
            }

            let addWorktree = try await runner.run(
                "git",
                arguments: [
                    "-C", repository.path,
                    "worktree", "add", "--quiet", "--detach",
                    worktree.path, pendingReview.metadata.headRefOid,
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
                "--json", "title,headRefOid,baseRefName,baseRefOid,url",
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
        // moved since it was cut. Best-effort — a repository whose base ref could not be resolved
        // still gets a review, just without the merge section.
        if let preview = await mergePreview(repository: repository, metadata: metadata) {
            try? Data(preview.render().utf8).write(
                to: worktree.appendingPathComponent(".review-bot-merge.md"),
                options: .atomic
            )
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
        credentials: ResolvedCredentials
    ) async -> [ReviewerResult] {
        let prompt = DefaultPrompt.combined(
            with: configuration.customPrompt,
            repositoryRules: repositoryRules
        )
        let reviewers = configuration.enabledReviewers
        guard !reviewers.isEmpty else { return [] }

        // Each reviewer suspends on network or process I/O, so the actor interleaves them and
        // they genuinely run in parallel. Results are re-ordered afterwards because a task
        // group yields in completion order, while the posted panel reads in `ReviewerName`
        // declaration order.
        return await withTaskGroup(of: (offset: Int, result: ReviewerResult).self) { group in
            for (offset, reviewer) in reviewers.enumerated() {
                group.addTask {
                    (
                        offset,
                        await self.runReviewer(
                            reviewer,
                            prompt: prompt,
                            worktree: worktree,
                            credentials: credentials
                        )
                    )
                }
            }
            var collected: [(offset: Int, result: ReviewerResult)] = []
            for await outcome in group {
                collected.append(outcome)
            }
            return collected.sorted { $0.offset < $1.offset }.map(\.result)
        }
    }

    /// How many times one reviewer may be run within a single review. The worktree,
    /// diff and thread are already prepared at this point, so a second run costs one
    /// CLI invocation rather than the whole pipeline — worth it for a crash, a
    /// transient API error, or a missing verdict line, which would otherwise discard
    /// every other reviewer's work and wait out a poll interval.
    private static let reviewerAttemptsPerReview = 2

    private func runReviewer(
        _ reviewer: ConfiguredReviewer,
        prompt: String,
        worktree: URL,
        credentials: ResolvedCredentials
    ) async -> ReviewerResult {
        var result = await runReviewerOnce(
            reviewer,
            prompt: prompt,
            worktree: worktree,
            credentials: credentials
        )
        var attempt = 1
        while attempt < Self.reviewerAttemptsPerReview, result.isWorthRetrying {
            await logger.append(
                "\(reviewer.name.rawValue) \(result.failure.map { "failed (\($0))" } ?? "returned no verdict"); running it again before giving up on this review."
            )
            var retried = await runReviewerOnce(
                reviewer,
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
                "\(reviewer.name.rawValue) failed for a reason a second call cannot fix (\(failure)); skipping the in-review retry and reviewing without it."
            )
        }
        return result
    }

    /// The one place a reviewer is actually dispatched — the panel's runs and reconciliation's
    /// alike, which is what lets the credential check live here rather than in each `run…`
    /// method. It is also the only compile-time guarantee that a newly added `ReviewerName` runs
    /// at all: `enabledReviewers`, the `poll` guard, `reviewerDescription` and `meteredUsage`
    /// all count reviewers without invoking them, so a reviewer missing from this switch would
    /// be announced and awaited but never called.
    private func runReviewerOnce(
        _ reviewer: ConfiguredReviewer,
        prompt: String,
        worktree: URL,
        credentials: ResolvedCredentials
    ) async -> ReviewerResult {
        let settings = reviewer.configuration
        // Checked here rather than inside each `run…` method, so a reviewer added later cannot
        // start without the credential it was configured to use. The message is one
        // `ReviewerFailureClass.classify` calls terminal, so the retry above does not spend a
        // second call — nor the review-level failure budget — on something only Settings fixes.
        if let missing = missingCredential(
            for: reviewer.name,
            configuration: settings,
            credentials: credentials
        ) {
            return failedReviewer(reviewer.name, settings, message: missing)
        }
        switch reviewer.name {
        case .claude:
            return await runClaude(
                configuration: settings,
                prompt: prompt,
                worktree: worktree,
                credentials: credentials
            )
        case .codex:
            return await runCodex(
                configuration: settings,
                prompt: prompt,
                worktree: worktree,
                credentials: credentials
            )
        case .opencode:
            return await runOpencode(
                configuration: settings,
                prompt: prompt,
                worktree: worktree,
                credentials: credentials
            )
        case .deepseek:
            return await runDeepSeek(
                configuration: settings,
                prompt: prompt,
                worktree: worktree,
                credentials: credentials
            )
        }
    }

    private func runReconciliation(
        results: [ReviewerResult],
        configuration: ReviewBotConfiguration,
        worktree: URL,
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
        let prompt = DefaultPrompt.reconciliation(reviews: panel)

        // The adjudicator is the first *enabled* CLI reviewer in `ReviewerName` order — Claude,
        // then Codex, then opencode. Expressed over `enabledReviewers` rather than as an
        // if-ladder ending in an unconditional `runOpencode`, which would spawn the opencode
        // process with a disabled configuration whenever neither of the first two was on.
        // DeepSeek is deliberately not a candidate: it is the reviewer that always bills a key,
        // and giving the last word to an extra metered pass is the wrong default. With none of
        // the three enabled there is nobody to ask, and the caller keeps the strictest verdict.
        let enabled = configuration.enabledReviewers
        let preference: [ReviewerName] = [.claude, .codex, .opencode]
        guard let adjudicator = preference
            .lazy
            .compactMap({ name in enabled.first { $0.name == name } })
            .first
        else {
            return failedReviewer(
                .claude,
                configuration.claude,
                message: "No reviewer was available to reconcile the disagreement."
            )
        }
        // Dispatching through `runReviewerOnce` rather than reaching for a `run…` method
        // directly is what keeps the credential check in one place: an adjudicator must not
        // start under a login it was not configured to use either. Deliberately
        // `runReviewerOnce` and not `runReviewer`: adjudication is one extra pass over work that
        // is already done, and for a metered adjudicator a silent second attempt is a second
        // bill for an answer the panel can live without.
        return await runReviewerOnce(
            adjudicator,
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
    ///
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
                    "--allowedTools", "Read", "Grep", "Glob",
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
    /// review to guard against a CLI nobody has reported. Cost comes straight from the CLI,
    /// which is the only place a dollar figure is reported at all — DeepSeek's API returns
    /// tokens and no price — so there is no price table to keep current.
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
                    "--agent", "review-bot",
                    "--model", configuration.model,
                    "--variant", configuration.effort.rawValue,
                    "--pure",
                    prompt,
                ],
                currentDirectory: worktree,
                environment: environment,
                timeout: 900
            )
            guard result.succeeded else {
                return failedReviewer(.opencode, configuration, message: conciseError(result))
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

    /// How much longer than its own budget the engine gives a DeepSeek review before cancelling
    /// it outright.
    ///
    /// The two bounds do different jobs and must never be equal. `DeepSeekReviewer`'s budget is
    /// the one meant to fire: reaching it ends the loop by *asking for the review*, so a dozen
    /// paid rounds of reading are still written up. But it is checked at the top of a round and
    /// then needs one more request to land, so a hard stop set to exactly the same duration wins
    /// every time — turning every graceful exit into a cancelled review that posts nothing.
    /// This margin is the room that closing request needs. It covers the ordinary case — one
    /// request, which `DeepSeekClient` bounds at 180s — with enough left over for a single
    /// backoff retry, and deliberately not for all three attempts the client will make against a
    /// provider that keeps answering 429: a closing request still retrying nine minutes in is not
    /// going to land, and cancelling it is right. The CLI reviewers need no equivalent because their bound is
    /// `ProcessRunner`'s `perl alarm`, and a CLI has no graceful exit to protect.
    private static let deepSeekClosingRequestMargin: TimeInterval = 300

    /// The engine's hard stop on a whole DeepSeek review. Derived from the reviewer's own budget
    /// rather than restated, so the two cannot drift back into a tie.
    private static var deepSeekReviewSeconds: Int {
        Int(DeepSeekReviewer.defaultReviewSeconds + deepSeekClosingRequestMargin)
    }

    private func runDeepSeek(
        configuration: ReviewerConfiguration,
        prompt: String,
        worktree: URL,
        credentials: ResolvedCredentials
    ) async -> ReviewerResult {
        guard let apiKey = credentials.apiKey(for: .deepseek) else {
            return failedReviewer(
                .deepseek,
                configuration,
                message: missingCredential(
                    for: .deepseek,
                    configuration: configuration,
                    credentials: credentials
                ) ?? "No DeepSeek API key is saved."
            )
        }
        let client = chatClient
        let model = configuration.model
        // Held by the engine rather than the loop, because a cancelled loop returns nothing at
        // all: this is the only way the rounds it had already paid for are still counted.
        let meter = DeepSeekReviewer.SpendMeter()
        do {
            // A sleeping task rather than a deadline handed to the reviewer, because this is
            // the *hard* stop: the loop is cancelled where it suspends, with no chance to
            // write anything up. The soft stop — the one that ends the loop by asking for the
            // review — is the reviewer's own, and the margin above is what lets it win.
            let generated = try await withThrowingTaskGroup(
                of: DeepSeekReviewer.Generated?.self
            ) { group -> DeepSeekReviewer.Generated? in
                group.addTask {
                    try await DeepSeekReviewer(client: client, model: model)
                        .review(
                            prompt: prompt,
                            worktree: worktree,
                            apiKey: apiKey,
                            meter: meter
                        )
                }
                group.addTask {
                    try? await Task.sleep(
                        nanoseconds: UInt64(Self.deepSeekReviewSeconds) * 1_000_000_000
                    )
                    return nil
                }
                let first = try await group.next() ?? nil
                group.cancelAll()
                return first
            }
            guard let generated else {
                // Flagged as a timeout by hand: `isWorthRetrying` reads that flag, and without
                // it the in-review retry answers a hung agent loop with a second one — a full
                // paid review's worth of rounds for an answer that is unlikely to arrive. The
                // meter is what keeps those abandoned rounds on the bill.
                return failedReviewer(
                    .deepseek,
                    configuration,
                    message: "DeepSeek did not finish within \(Self.deepSeekReviewSeconds) seconds.",
                    timedOut: true,
                    usage: await meter.total()
                )
            }
            return ReviewerResult(
                reviewer: .deepseek,
                model: configuration.model,
                output: generated.text,
                verdict: VerdictParser.parse(generated.text),
                failure: nil,
                usage: generated.usage
            )
        } catch {
            // Through the shared classifier rather than straight to `message:`, so a provider
            // timeout is recorded as a timeout here exactly as a `perl alarm` is for the CLIs.
            return failedReviewer(
                .deepseek,
                configuration,
                error: error,
                usage: await meter.total()
            )
        }
    }

    /// Classifies a thrown reviewer failure — in particular, whether it was a timeout, which
    /// `ReviewerResult.isWorthRetrying` reads to keep the in-review retry from answering a hung
    /// reviewer with a second full paid run.
    ///
    /// The unwrap comes first because a DeepSeek loop that had already been billed wraps
    /// whatever it caught in `PartialSpendFailure`, and that wrapper would otherwise hide the
    /// timeout inside it from every check below. `usage` overrides the wrapper's own figure
    /// where the caller has a better one — `runDeepSeek`'s meter, which also sees the rounds a
    /// cancelled loop paid for — and falls back to it otherwise.
    private func failedReviewer(
        _ reviewer: ReviewerName,
        _ configuration: ReviewerConfiguration,
        error: Error,
        usage: TokenUsage? = nil
    ) -> ReviewerResult {
        let (underlying, spent) = DeepSeekReviewer.outcome(of: error)
        var timedOut = false
        if let commandError = underlying as? CommandExecutionError,
           case .timedOut = commandError {
            timedOut = true
        } else if let urlError = underlying as? URLError, urlError.code == .timedOut {
            // The HTTP reviewers have no child process to alarm, so their equivalent of a
            // hung CLI arrives as a URLSession failure. Classifying it here keeps the "a
            // timeout is not retried in place" rule reviewer-agnostic.
            timedOut = true
        } else if let chatError = underlying as? ChatCompletionError,
                  case .timedOut = chatError {
            // `DeepSeekClient` converts the URLSession timeout above into this before it can
            // reach here, so this — not the `URLError` arm — is the case an HTTP reviewer's
            // timeout actually takes.
            timedOut = true
        }
        return failedReviewer(
            reviewer,
            configuration,
            message: underlying.localizedDescription,
            timedOut: timedOut,
            usage: usage ?? spent
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
            note = guardReason == nil
                ? "This review is neutral under the current decision policy (a reviewer failed, returned an unreadable verdict, or the policy leaves this severity to you)."
                : "An automated injection check flagged this approval as unsafe, so the review posts as a neutral comment instead."
        }

        // A decision reached by part of the panel is a weaker signal than one reached by all of
        // it, and the difference is invisible from the outside — so say it, and say which
        // reviewer is missing. Without this an approval from one surviving reviewer would be
        // indistinguishable from a unanimous one.
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


            > **Partial panel: \(missing) did not contribute a verdict.** The decision above reflects only the reviewers that finished, so it is a weaker signal than a full panel — weigh it accordingly.
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
        let reviewers = configuration.enabledReviewers.map { reviewer in
            let detail = reviewer.name.usesEffortSetting
                ? reviewer.configuration.effort.label
                : reviewer.configuration.model
            return "\(reviewer.name.rawValue) (\(detail))"
        }
        // Assembled from `enabledReviewers` rather than a branch per reviewer, which read
        // "A and B and C" once there were three of them — and needed editing for a fourth.
        guard let last = reviewers.last else { return "Running no reviewers." }
        guard reviewers.count > 1 else { return "Running \(last)." }
        return "Running " + reviewers.dropLast().joined(separator: ", ") + " and \(last)."
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
