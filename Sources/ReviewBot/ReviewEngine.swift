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
        case .noReviewersEnabled: "Enable Claude, Codex, or opencode before running reviews."
        case let .reviewIncomplete(message): message
        }
    }
}

actor ReviewEngine {
    typealias EventSink = (HistoryEntry) async -> Void
    typealias StatusSink = (String) async -> Void

    private let paths: StoragePaths
    private let runner: any CommandRunning
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

    init(
        paths: StoragePaths,
        runner: any CommandRunning = ProcessRunner(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.paths = paths
        self.runner = runner
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
            || configuration.opencode.enabled else {
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

            let results = await runReviewers(
                configuration: configuration,
                worktree: worktree,
                repositoryRules: await loadRepositoryReviewRules(
                    repository: repository,
                    baseCommitSHA: metadata.baseRefOid
                )
            )

            // Post as long as *someone* finished. A reviewer that failed is named in the posted
            // body rather than suppressing the review: holding the whole panel hostage to one CLI
            // means an exhausted quota throws away the findings the other reviewer already
            // produced, and keeps doing so until the failure budget abandons the request
            // entirely — so a provider outage reads to the author as no review at all.
            // Nobody finishing is different in kind: there is no review to post, so leave the
            // request unmarked for the next poll.
            let unfinished = results.filter { $0.verdict == nil }
            // A reviewer that *reported* it could not assess the pull request is a different
            // thing from one that crashed. It ran, it looked, and it concluded the evidence was
            // not there — an answer, and one the author needs, because the alternative is a pull
            // request that silently never gets reviewed. So when nobody reached a verdict and at
            // least one reviewer said why, post that as a neutral comment rather than staying
            // quiet and retrying: retrying re-reads the same evidence, and silence means the
            // author learns nothing until the failure budget gives up without a word.
            let saidWhy = results.contains { $0.couldNotAssess }
            guard results.contains(where: { $0.verdict != nil }) || saidWhy else {
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
            var adjudication: ReviewerResult?
            if DecisionEvaluator.gateDisagreement(results, policy: policy) {
                await announce("Reviewers disagreed on \(repository.name) #\(pullRequest.number); reconciling…")
                let adjudicated = await runReconciliation(
                    results: results,
                    configuration: configuration,
                    worktree: worktree
                )
                if let verdict = adjudicated.verdict {
                    decision = DecisionEvaluator.decision(for: verdict, policy: policy)
                    adjudication = adjudicated
                } else {
                    await logger.append(
                        "Reconciliation for \(repository.githubSlug)#\(pullRequest.number) produced no verdict; using strictest (\(strictDecision.title))."
                    )
                }
            }
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
                guardReason: guardReason
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
            await emit(
                kind: decision.historyKind,
                repository: repository,
                pullRequest: pullRequest,
                message: "\(decision.title) — \(verdicts).\(reconciledNote)",
                onEvent: onEvent
            )
        } catch {
            // Nothing posted, so the dedup key stays unwritten and the next poll retries —
            // but the attempt is counted, which is what bounds and paces that retry.
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
                    message: message
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
            if diff.succeeded {
                diffText = diff.stdout
            } else if let local = await localDiffText(repository: repository, metadata: metadata) {
                // GitHub's diff endpoint refuses anything over 20,000 lines with a 406, which is a
                // property of the API rather than of the pull request: the commits are already in
                // the clone, so the same three-dot diff computes locally with no ceiling. Falling
                // back is strictly better than failing, and it is not a lesser answer — `git diff
                // base...head` is exactly what `gh pr diff` asks the API to render.
                diffText = local
            } else {
                throw ReviewEngineError.commandFailed(
                    "Could not download the PR diff: \(conciseError(diff)); computing it from the "
                        + "local clone did not work either."
                )
            }
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

    /// The pull request's three-dot diff computed from the clone instead of the API, or `nil` when
    /// the base cannot be resolved locally.
    ///
    /// `review` has already fetched both sides — the PR head and
    /// `refs/remotes/origin/<baseRefName>` — so this needs no network. `base...head` is git's own
    /// spelling of "merge-base to head", which is the same diff `gh pr diff` renders, so a reviewer
    /// cannot tell which route produced the patch it reads.
    private func localDiffText(
        repository: RepositoryConfiguration,
        metadata: PullRequestMetadata
    ) async -> String? {
        func git(_ arguments: [String], timeout: Int = 120) async -> CommandResult? {
            try? await runner.run("git", arguments: ["-C", repository.path] + arguments, timeout: timeout)
        }

        // Same rule as `mergePreview`: prefer the ref that was just fetched over `baseRefOid`,
        // which is GitHub's snapshot of the base at the time it answered and may be stale.
        let tracked = await git([
            "rev-parse", "--verify", "--quiet",
            "refs/remotes/origin/\(metadata.baseRefName)^{commit}",
        ])
        let base = tracked.flatMap { result -> String? in
            guard result.succeeded else { return nil }
            let oid = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            return oid.isEmpty ? nil : oid
        } ?? metadata.baseRefOid

        guard let diff = await git(["diff", "\(base)...\(metadata.headRefOid)"]), diff.succeeded
        else { return nil }

        // An empty patch is a real answer for a pull request that changes nothing, but it is also
        // what a silently wrong revision range produces. Since this path only runs after the API
        // already refused, treat empty as failure rather than sending reviewers an empty diff and
        // letting them approve it.
        return diff.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : diff.stdout
    }

    private func runReviewers(
        configuration: ReviewBotConfiguration,
        worktree: URL,
        repositoryRules: String?
    ) async -> [ReviewerResult] {
        let prompt = DefaultPrompt.combined(
            with: configuration.customPrompt,
            repositoryRules: repositoryRules
        )

        // Runs every enabled reviewer in parallel, preserving a deterministic
        // output order (Claude, Codex, opencode) regardless of completion order.
        let enabled: [(ReviewerName, ReviewerConfiguration)] = [
            (.claude, configuration.claude),
            (.codex, configuration.codex),
            (.opencode, configuration.opencode),
        ].filter { $0.1.enabled }

        let order = Dictionary(uniqueKeysWithValues: enabled.enumerated().map { ($0.element.0, $0.offset) })
        var results = await withTaskGroup(of: ReviewerResult.self) { group in
            for (name, reviewer) in enabled {
                group.addTask {
                    await self.runReviewer(
                        name,
                        configuration: reviewer,
                        prompt: prompt,
                        worktree: worktree
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
        worktree: URL
    ) async -> ReviewerResult {
        var result = withdrawnIfItCouldNotAssess(
            await runReviewerOnce(
                name,
                configuration: configuration,
                prompt: prompt,
                worktree: worktree
            )
        )
        var attempt = 1
        while attempt < Self.reviewerAttemptsPerReview, result.isWorthRetrying {
            await logger.append(
                "\(name.rawValue) \(result.failure.map { "failed (\($0))" } ?? "returned no verdict"); running it again before giving up on this review."
            )
            result = withdrawnIfItCouldNotAssess(
                await runReviewerOnce(
                    name,
                    configuration: configuration,
                    prompt: prompt,
                    worktree: worktree
                )
            )
            attempt += 1
        }
        if result.failureClass == .terminal, let failure = result.failure {
            await logger.append(
                "\(name.rawValue) failed for a reason a second call cannot fix (\(failure)); skipping the in-review retry and reviewing without it."
            )
        }
        return result
    }

    /// Drops the verdict of a reviewer whose own review says it could not assess the pull
    /// request, and records why in its place.
    ///
    /// The verdict line and the body are both the model's, and when they disagree the body is the
    /// honest one: a reviewer that reports it never read the diff and then emits `NITS_ONLY` has
    /// described its situation accurately and then answered a question it had no business
    /// answering. Taking the verdict would turn "I could not look" into an approval.
    ///
    /// Classified terminal, so it is not run again inside this review: a reviewer that has
    /// reasoned its way to "there is nothing here I can read" reaches the same conclusion the
    /// second time.
    private func withdrawnIfItCouldNotAssess(_ result: ReviewerResult) -> ReviewerResult {
        guard result.verdict != nil,
              VerdictParser.statesItCouldNotAssess(VerdictParser.bodyWithoutTrailer(result.output))
        else { return result }

        var withdrawn = result
        withdrawn.verdict = nil
        // The wording carries the classification: `failureClass` is derived from this message,
        // and "could not assess this pull request" is a terminal marker.
        withdrawn.failure = "reported that it could not assess this pull request, so its verdict "
            + "was not counted"
        return withdrawn
    }

    private func runReviewerOnce(
        _ name: ReviewerName,
        configuration: ReviewerConfiguration,
        prompt: String,
        worktree: URL
    ) async -> ReviewerResult {
        switch name {
        case .claude:
            await runClaude(configuration: configuration, prompt: prompt, worktree: worktree)
        case .codex:
            await runCodex(configuration: configuration, prompt: prompt, worktree: worktree)
        case .opencode:
            await runOpencode(configuration: configuration, prompt: prompt, worktree: worktree)
        }
    }

    private func runReconciliation(
        results: [ReviewerResult],
        configuration: ReviewBotConfiguration,
        worktree: URL
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
        // Reviewers are enabled whenever verdicts disagree; prefer Claude as
        // adjudicator, then Codex, then opencode.
        if configuration.claude.enabled {
            return await runClaude(
                configuration: configuration.claude,
                prompt: prompt,
                worktree: worktree
            )
        }
        if configuration.codex.enabled {
            return await runCodex(
                configuration: configuration.codex,
                prompt: prompt,
                worktree: worktree
            )
        }
        return await runOpencode(
            configuration: configuration.opencode,
            prompt: prompt,
            worktree: worktree
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

    private func runClaude(
        configuration: ReviewerConfiguration,
        prompt: String,
        worktree: URL
    ) async -> ReviewerResult {
        do {
            let result = try await runner.run(
                "claude",
                arguments: [
                    "-p", prompt,
                    "--model", configuration.model,
                    "--effort", configuration.effort.rawValue,
                    "--allowedTools", "Read", "Grep", "Glob",
                    "--output-format", "text",
                ],
                currentDirectory: worktree,
                timeout: configuration.timeoutSeconds
            )
            guard result.succeeded else {
                return failedReviewer(.claude, configuration, message: conciseError(result))
            }
            return ReviewerResult(
                reviewer: .claude,
                model: configuration.model,
                output: result.stdout,
                verdict: VerdictParser.parse(result.stdout),
                failure: nil
            )
        } catch {
            return failedReviewer(.claude, configuration, error: error)
        }
    }

    private func runCodex(
        configuration: ReviewerConfiguration,
        prompt: String,
        worktree: URL
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
                timeout: configuration.timeoutSeconds
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
        worktree: URL
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
                timeout: configuration.timeoutSeconds,
                environment: [
                    "OPENCODE_CONFIG_DIR": paths.opencodeConfigDirectory.path,
                    "OPENCODE_CONFIG_CONTENT": permissions,
                ]
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

    private func failedReviewer(
        _ reviewer: ReviewerName,
        _ configuration: ReviewerConfiguration,
        message: String,
        timedOut: Bool = false
    ) -> ReviewerResult {
        ReviewerResult(
            reviewer: reviewer,
            model: configuration.model,
            output: "_\(reviewer.rawValue) review failed: \(message)_",
            verdict: nil,
            failure: message,
            timedOut: timedOut
        )
    }

    private func aggregateReview(
        pullRequest: PullRequestSummary,
        commitSHA: String,
        results: [ReviewerResult],
        decision: ReviewDecision,
        adjudication: ReviewerResult?,
        guardReason: InjectionGuard.Reason?
    ) -> String {
        let verdictSummary = results.map {
            "\($0.reviewer.rawValue): `\($0.verdict?.rawValue ?? "unavailable")`"
        }.joined(separator: ", ")
        // Only reviewers that produced a verdict get a details block; a failed one has no
        // review body to show, and an empty disclosure triangle reads as an empty review
        // rather than an absent one. The blockquote below names them instead.
        // A details block needs something worth opening. A reviewer that produced a verdict has
        // its review; a reviewer that reported it could not assess the pull request has its
        // account of why, which is the entire value of the comment when nobody reached a verdict.
        // A reviewer that crashed or timed out has neither, and an empty disclosure triangle
        // reads as an empty review rather than an absent one — the blockquote names those.
        let details = results.filter { $0.verdict != nil || $0.couldNotAssess }.map { result in
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
            if results.allSatisfy({ $0.verdict == nil }), guardReason == nil {
                // Nobody assessed the pull request. Saying "this review is neutral" here would
                // describe a judgement that was never made; what the author needs is that no
                // review happened and why, so the reasons below are the whole message.
                note = "**No reviewer was able to assess this pull request**, so this comment "
                    + "reports why rather than offering a judgement. Nothing here should be read "
                    + "as approval."
                break
            }
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
                } else if result.couldNotAssess {
                    // Its own words, not a failure summary: this reviewer worked and told us it
                    // had nothing to go on, and the detail is what the author has to act on.
                    reason = "could not assess the pull request"
                } else if let failure = result.failure {
                    reason = "failed — \(inlineDetail(failure))"
                } else {
                    reason = "returned no verdict"
                }
                return "**\(result.reviewer.rawValue)** (\(reason))"
            }.joined(separator: ", ")
            partialPanelDisclosure = unfinished.count == results.count
                ? """


                > **No verdict was reached: \(missing).** This is not an approval and not a rejection — the pull request has not been reviewed. Each reviewer's own account of why is below; a new commit or a fresh review request starts over.
                """
                : """


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

        \(details)

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
        onEvent: @escaping EventSink
    ) async {
        let entry = HistoryEntry(
            kind: kind,
            repositoryName: repository.name,
            repositorySlug: repository.githubSlug,
            pullRequestNumber: pullRequest.number,
            pullRequestTitle: pullRequest.title,
            pullRequestURL: pullRequest.url,
            message: message
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
