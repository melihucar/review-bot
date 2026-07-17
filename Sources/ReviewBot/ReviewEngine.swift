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
        case .noReviewersEnabled: "Enable Claude or Codex before running reviews."
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
    private let logger: ActivityLogger

    private struct PendingPullRequest {
        let summary: PullRequestSummary
        let metadata: PullRequestMetadata
        let repository: RepositoryConfiguration
        let requestMarker: String
        let reviewKey: String
    }

    init(paths: StoragePaths, runner: any CommandRunning = ProcessRunner()) {
        self.paths = paths
        self.runner = runner
        reviewedState = ReviewedStateStore(paths: paths)
        logger = ActivityLogger(directory: paths.logsDirectory)
        try? paths.prepare()
    }

    func poll(
        configuration: ReviewBotConfiguration,
        onEvent: @escaping EventSink,
        onStatus: @escaping StatusSink
    ) async {
        let repositories = configuration.repositories.filter(\.enabled)
        guard !repositories.isEmpty else {
            await onStatus("Add and enable a repository to begin")
            return
        }
        guard configuration.claude.enabled || configuration.codex.enabled else {
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
            for repository in repositories {
                let discovered = await discoverPendingReviews(
                    repository: repository,
                    githubUser: githubUser,
                    onEvent: onEvent,
                    onStatus: onStatus
                )
                pendingReviews.append(contentsOf: discovered)
            }

            for pendingReview in pendingReviews {
                await review(
                    pendingReview,
                    configuration: configuration,
                    onEvent: onEvent,
                    onStatus: onStatus
                )
            }

            await onStatus("Watching \(repositories.count) repositor\(repositories.count == 1 ? "y" : "ies")")
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
        onEvent: @escaping EventSink,
        onStatus: @escaping StatusSink
    ) async -> [PendingPullRequest] {
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
                    let reviewKey = "\(repository.githubSlug)#\(pullRequest.number)@\(metadata.headRefOid)@\(requestMarker)"
                    guard !reviewedState.contains(reviewKey) else { continue }

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
                    await logger.append(
                        "Could not inspect \(repository.githubSlug)#\(pullRequest.number): \(error.localizedDescription)"
                    )
                    await onEvent(
                        HistoryEntry(
                            kind: .failed,
                            repositoryName: repository.name,
                            repositorySlug: repository.githubSlug,
                            pullRequestNumber: pullRequest.number,
                            pullRequestTitle: pullRequest.title,
                            pullRequestURL: pullRequest.url,
                            message: error.localizedDescription
                        )
                    )
                }
            }
            return pending
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
            return []
        }
    }

    private func review(
        _ pendingReview: PendingPullRequest,
        configuration: ReviewBotConfiguration,
        onEvent: @escaping EventSink,
        onStatus: @escaping StatusSink
    ) async {
        let pullRequest = pendingReview.summary
        let metadata = pendingReview.metadata
        let repository = pendingReview.repository
        var worktreeURL: URL?
        var worktreeAdded = false

        do {
            await onStatus("Preparing \(repository.name) #\(pullRequest.number)…")

            let fetch = try await runner.run(
                "git",
                arguments: [
                    "-C", repository.path,
                    "fetch", "--quiet", "origin",
                    "refs/pull/\(pullRequest.number)/head",
                    "refs/heads/\(metadata.baseRefName)",
                ],
                timeout: 180
            )
            guard fetch.succeeded else {
                throw ReviewEngineError.commandFailed("Git fetch failed: \(conciseError(fetch))")
            }

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
            worktreeAdded = true

            try await prepareReviewContext(
                number: pullRequest.number,
                repository: repository,
                worktree: worktree
            )

            await emit(
                kind: .reviewStarted,
                repository: repository,
                pullRequest: pullRequest,
                message: reviewerDescription(configuration),
                onEvent: onEvent
            )
            await onStatus("Reviewing \(repository.name) #\(pullRequest.number)…")

            let results = await runReviewers(
                configuration: configuration,
                worktree: worktree,
                repositoryRules: await loadRepositoryReviewRules(
                    repository: repository,
                    baseCommitSHA: metadata.baseRefOid
                )
            )

            // Only post when every enabled reviewer finished with a parseable verdict.
            // If any reviewer failed or returned no verdict, post nothing and leave the
            // request unmarked so the next poll retries it.
            let unfinished = results.filter { $0.failure != nil || $0.verdict == nil }
            guard !results.isEmpty, unfinished.isEmpty else {
                let detail = unfinished.isEmpty
                    ? "no reviewer produced a result"
                    : unfinished.map { result in
                        if let failure = result.failure {
                            return "\(result.reviewer.rawValue) failed (\(failure))"
                        }
                        return "\(result.reviewer.rawValue) returned no verdict"
                    }.joined(separator: "; ")
                throw ReviewEngineError.reviewIncomplete(
                    "Review not posted, will retry next check — \(detail)"
                )
            }

            let strictDecision = DecisionEvaluator.evaluate(results)
            var decision = strictDecision
            var adjudication: ReviewerResult?
            if DecisionEvaluator.gateDisagreement(results) {
                await onStatus("Reviewers disagreed on \(repository.name) #\(pullRequest.number); reconciling…")
                let adjudicated = await runReconciliation(
                    results: results,
                    configuration: configuration,
                    worktree: worktree
                )
                if let verdict = adjudicated.verdict {
                    decision = DecisionEvaluator.decision(for: verdict)
                    adjudication = adjudicated
                } else {
                    await logger.append(
                        "Reconciliation for \(repository.githubSlug)#\(pullRequest.number) produced no verdict; using strictest (\(strictDecision.title))."
                    )
                }
            }
            let reviewBody = aggregateReview(
                pullRequest: pullRequest,
                commitSHA: metadata.headRefOid,
                results: results,
                decision: decision,
                adjudication: adjudication
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
            await logger.append(
                "PR \(repository.githubSlug)#\(pullRequest.number) failed: \(error.localizedDescription)"
            )
            await onEvent(
                HistoryEntry(
                    kind: .failed,
                    repositoryName: repository.name,
                    repositorySlug: repository.githubSlug,
                    pullRequestNumber: pullRequest.number,
                    pullRequestTitle: pullRequest.title,
                    pullRequestURL: pullRequest.url,
                    message: error.localizedDescription
                )
            )
        }

        if let worktreeURL, worktreeAdded {
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
        }
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
        guard result.succeeded else { return fallback }

        return result.stdout
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .sorted()
            .last ?? fallback
    }

    private func prepareReviewContext(
        number: Int,
        repository: RepositoryConfiguration,
        worktree: URL
    ) async throws {
        let diff = try await runner.run(
            "gh",
            arguments: ["pr", "diff", String(number), "--repo", repository.githubSlug],
            timeout: 120
        )
        guard diff.succeeded else {
            throw ReviewEngineError.commandFailed("Could not download the PR diff: \(conciseError(diff))")
        }
        try Data(diff.stdout.utf8).write(
            to: worktree.appendingPathComponent(".review-bot-diff.patch"),
            options: .atomic
        )

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
        let thread = """
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

        if configuration.claude.enabled, configuration.codex.enabled {
            async let claude = runClaude(
                configuration: configuration.claude,
                prompt: prompt,
                worktree: worktree
            )
            async let codex = runCodex(
                configuration: configuration.codex,
                prompt: prompt,
                worktree: worktree
            )
            return await [claude, codex]
        }

        if configuration.claude.enabled {
            return [await runClaude(
                configuration: configuration.claude,
                prompt: prompt,
                worktree: worktree
            )]
        }

        if configuration.codex.enabled {
            return [await runCodex(
                configuration: configuration.codex,
                prompt: prompt,
                worktree: worktree
            )]
        }

        return []
    }

    private func runReconciliation(
        results: [ReviewerResult],
        configuration: ReviewBotConfiguration,
        worktree: URL
    ) async -> ReviewerResult {
        let prompt = DefaultPrompt.reconciliation(
            reviews: results.map {
                (
                    reviewer: $0.reviewer.rawValue,
                    body: VerdictParser.bodyWithoutTrailer($0.output),
                    verdict: $0.verdict?.rawValue ?? "unavailable"
                )
            }
        )
        // Both reviewers are enabled whenever verdicts disagree; prefer Claude as adjudicator.
        if configuration.claude.enabled {
            return await runClaude(
                configuration: configuration.claude,
                prompt: prompt,
                worktree: worktree
            )
        }
        return await runCodex(
            configuration: configuration.codex,
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
                timeout: 900
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
            return failedReviewer(.claude, configuration, message: error.localizedDescription)
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
            return failedReviewer(.codex, configuration, message: error.localizedDescription)
        }
    }

    private func failedReviewer(
        _ reviewer: ReviewerName,
        _ configuration: ReviewerConfiguration,
        message: String
    ) -> ReviewerResult {
        ReviewerResult(
            reviewer: reviewer,
            model: configuration.model,
            output: "_\(reviewer.rawValue) review failed: \(message)_",
            verdict: nil,
            failure: message
        )
    }

    private func aggregateReview(
        pullRequest: PullRequestSummary,
        commitSHA: String,
        results: [ReviewerResult],
        decision: ReviewDecision,
        adjudication: ReviewerResult?
    ) -> String {
        let verdictSummary = results.map {
            "\($0.reviewer.rawValue): `\($0.verdict?.rawValue ?? "unavailable")`"
        }.joined(separator: ", ")
        let details = results.map { result in
            """
            <details><summary><strong>\(result.reviewer.rawValue) — \(result.model)</strong></summary>

            \(VerdictParser.bodyWithoutTrailer(result.output))

            </details>
            """
        }.joined(separator: "\n\n")
        let note: String
        switch decision {
        case .approve:
            note = "All enabled reviewers found only optional nits or no issues."
        case .requestChanges:
            note = "At least one enabled reviewer found a blocking or should-fix issue."
        case .comment:
            note = "At least one reviewer failed or returned an unreadable verdict, so this review is neutral."
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

        **Decision: \(decision.title)** — \(note)\(reconciliationSection)

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

    private func conciseError(_ result: CommandResult) -> String {
        let value = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? result.stdout
            : result.stderr
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "command exited with status \(result.exitCode)" }
        return String(trimmed.prefix(600))
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
