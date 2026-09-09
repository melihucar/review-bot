import Foundation

/// Runs one review through DeepSeek's chat-completions API.
///
/// Claude and Codex are agents: they get a prompt and explore the worktree themselves. DeepSeek
/// is a plain completions endpoint, so the agent loop lives here — the model is offered the
/// read-only `WorktreeTools`, and each round of tool calls is executed locally and fed back until
/// it produces its final review. The diff, the PR thread, and the merge preview are also inlined in
/// the opening message so a model that never calls a tool (or cannot) still reviews the right code
/// with the same evidence the contract assumes it has.
struct DeepSeekReviewer {
    private enum Limits {
        static let inlinedDiffCharacters = 120_000
        static let inlinedThreadCharacters = 30_000
        /// `MergePreview` caps its inlined base-side diff at 60 KB, so this is enough for the
        /// whole file in all but the widest overlaps. What truncation costs is the tail of that
        /// evidence, never the conflict and both-changed path lists it opens with — which are
        /// the part the scope gate's merge exception actually rests on.
        static let inlinedMergePreviewCharacters = 40_000
        static let toolRounds = 16
    }

    /// Wall-clock ceiling for one review, matching the 900s `ProcessRunner` gives each CLI
    /// reviewer. Nothing else bounds this loop from the inside: DeepSeek is not a child process,
    /// so there is no `perl alarm` behind it, and the round cap bounds calls rather than time —
    /// sixteen slow rounds can outlast every other reviewer in the panel by a wide margin.
    ///
    /// Not `private`, because `ReviewEngine`'s hard stop has to sit *above* it: reaching this
    /// deadline ends the loop by asking for the review, and a cancellation racing it at the same
    /// instant would throw that away. Deriving the engine's ceiling from this constant is what
    /// keeps the two from drifting back into a tie.
    static let defaultReviewSeconds: TimeInterval = 900

    /// What a review has been billed so far, updated as the loop goes.
    ///
    /// A thrown failure carries its spend out in `PartialSpendFailure`, but a loop the caller
    /// *cancels* never returns anything at all — and by then it may have spent a dozen paid
    /// rounds. This is how those rounds are still counted: the caller holds the meter, so it can
    /// read the running figure whatever became of the task.
    actor SpendMeter {
        private var usage = TokenUsage()

        func record(_ spent: TokenUsage) {
            usage = usage + spent
        }

        /// `nil` when nothing has been billed, so a caller can hand it straight to a result whose
        /// `usage` means "this cost something".
        func total() -> TokenUsage? {
            usage.requests > 0 ? usage : nil
        }
    }

    /// A finished review and what producing it consumed.
    struct Generated {
        let text: String
        let usage: TokenUsage
    }

    /// A review that failed *after* the key had already been billed.
    ///
    /// The loop can spend a dozen paid rounds and fail on the last call, and a thrown error
    /// carries no usage — so the engine would record a review that cost real money as free, and
    /// then an in-review retry would spend it again on top of a total that never showed the
    /// first attempt. This carries the running figure out with the failure. It renders exactly
    /// like the error it wraps, so the message posted in a partial-panel disclosure and the
    /// phrases `ReviewerFailureClass.classify` matches on are unchanged; a caller that does not
    /// know about it is no worse off than before.
    struct PartialSpendFailure: LocalizedError {
        let underlying: Error
        /// Counted exactly as a completed review's usage is.
        let usage: TokenUsage

        var errorDescription: String? { underlying.localizedDescription }
    }

    /// Splits a thrown review failure into the parts `ReviewEngine` needs: the original error —
    /// for the message it discloses and for `ReviewerFailureClass.classify` — and whatever the
    /// key was billed before it, which is `nil` only when nothing was.
    static func outcome(of error: Error) -> (error: Error, usage: TokenUsage?) {
        guard let partial = error as? PartialSpendFailure else { return (error, nil) }
        return (partial.underlying, partial.usage)
    }

    private let client: any ChatCompleting
    private let model: String
    private let toolRounds: Int
    private let reviewSeconds: TimeInterval

    init(
        client: any ChatCompleting,
        model: String,
        toolRounds: Int = Limits.toolRounds,
        reviewSeconds: TimeInterval = Self.defaultReviewSeconds
    ) {
        self.client = client
        self.model = model
        self.toolRounds = max(1, toolRounds)
        self.reviewSeconds = max(0, reviewSeconds)
    }

    /// `meter`, when given, accumulates what each round is billed as the round completes, so a
    /// caller that abandons this task still knows what it cost.
    func review(
        prompt: String,
        worktree: URL,
        apiKey: String,
        meter: SpendMeter? = nil
    ) async throws -> Generated {
        // One budget for the whole review, taken before the first call so the fallback below
        // inherits what the first attempt already spent rather than starting the clock again.
        let deadline = Date().addingTimeInterval(reviewSeconds)

        do {
            return try await converse(
                messages: opening(prompt: prompt, worktree: worktree, toolsOffered: true),
                tools: WorktreeTools.definitions,
                worktree: worktree,
                apiKey: apiKey,
                deadline: deadline,
                meter: meter
            )
        } catch ChatCompletionError.toolsUnsupported {
            // Reasoning models reject `tools`. Everything the contract tells a reviewer to read
            // is inlined in the opening message, so a single-shot review still has what it needs
            // — but it is rebuilt, because the version above tells the model to call tools it is
            // about to be denied.
            return try await converse(
                messages: opening(prompt: prompt, worktree: worktree, toolsOffered: false),
                tools: nil,
                worktree: worktree,
                apiKey: apiKey,
                deadline: deadline,
                meter: meter
            )
        }
    }

    private func opening(prompt: String, worktree: URL, toolsOffered: Bool) -> [ChatMessage] {
        [
            .system(prompt),
            .user(openingMessage(worktree: worktree, toolsOffered: toolsOffered)),
        ]
    }

    private func converse(
        messages: [ChatMessage],
        tools: [ChatTool]?,
        worktree: URL,
        apiKey: String,
        deadline: Date,
        meter: SpendMeter?
    ) async throws -> Generated {
        let worktreeTools = WorktreeTools(root: worktree)
        var messages = messages
        var usage = TokenUsage()

        for round in 0..<toolRounds {
            // Out of time: stop investigating and ask for the review, the same exit the round cap
            // takes. Throwing here instead would discard a dozen paid rounds of reading, and the
            // model has enough in context by now to write something worth posting. Checked from
            // the second round on, so a budget already spent still yields one honest attempt.
            if round > 0, Date() >= deadline {
                return try await requestFinalReview(
                    after: messages,
                    accumulated: usage,
                    apiKey: apiKey,
                    meter: meter
                )
            }

            let completion: ChatCompletionResult
            do {
                completion = try await client.complete(
                    ChatCompletionRequest(model: model, messages: messages, tools: tools),
                    apiKey: apiKey
                )
            } catch {
                throw failure(error, spent: usage)
            }
            let spent = completion.usage ?? TokenUsage(requests: 1)
            usage = usage + spent
            await meter?.record(spent)
            let reply = completion.message
            messages.append(reply)

            let calls = reply.toolCalls ?? []
            if !calls.isEmpty {
                for call in calls {
                    messages.append(
                        .toolResult(
                            worktreeTools.execute(
                                name: call.function.name,
                                argumentsJSON: call.function.arguments
                            ),
                            callID: call.id
                        )
                    )
                }
                // Keep going until the model stops asking for tools, or the rounds run out and we
                // request the review below.
                if round < toolRounds - 1 { continue }
            } else if let content = reply.content {
                // An absent tool call does not mean the model is finished — it writes its
                // reasoning into `content` too, so "no tool call" can just as easily mean it
                // paused to think. Only accept this turn as the review when it actually is one.
                let candidate = Self.trimmedToContract(content)
                if Self.followsContract(candidate) {
                    return Generated(text: candidate, usage: usage)
                }
            }

            return try await requestFinalReview(
                after: messages,
                accumulated: usage,
                apiKey: apiKey,
                meter: meter
            )
        }

        throw failure(ChatCompletionError.emptyResponse, spent: usage)
    }

    /// Attaches what the key has already been billed to a failure, so the engine can report a
    /// review that cost money and produced nothing as exactly that.
    ///
    /// Two failures are handed back untouched. A model that rejects `tools` has not been billed
    /// for a review, and `review(_:)` matches on that case to retry without them — a wrapper
    /// would silently defeat the fallback. And a failure that already carries a spend keeps the
    /// deeper, larger figure rather than being re-wrapped around a partial one.
    private func failure(_ error: Error, spent usage: TokenUsage) -> Error {
        if let chatError = error as? ChatCompletionError, case .toolsUnsupported = chatError {
            return error
        }
        if error is PartialSpendFailure { return error }
        guard usage.requests > 0 else { return error }
        return PartialSpendFailure(underlying: error, usage: usage)
    }

    /// Asks explicitly for the review, with the structure restated and no tools offered, and uses
    /// that reply — discarding whatever narration preceded it.
    private func requestFinalReview(
        after messages: [ChatMessage],
        accumulated: TokenUsage,
        apiKey: String,
        meter: SpendMeter? = nil
    ) async throws -> Generated {
        var messages = messages
        messages.append(.user(DefaultPrompt.finalReviewRequest))

        let completion: ChatCompletionResult
        do {
            completion = try await client.complete(
                ChatCompletionRequest(model: model, messages: messages, tools: nil),
                apiKey: apiKey
            )
        } catch {
            throw failure(error, spent: accumulated)
        }
        let spent = completion.usage ?? TokenUsage(requests: 1)
        await meter?.record(spent)
        let usage = accumulated + spent
        guard let content = completion.message.content, !content.isEmpty else {
            // Every round before this one was still billed, and this is the likeliest place a
            // long, expensive loop ends with nothing to post.
            throw failure(ChatCompletionError.emptyResponse, spent: usage)
        }
        return Generated(text: Self.trimmedToContract(content), usage: usage)
    }

    /// The contract's first heading, in the typographic variants models actually emit: `## Summary`,
    /// `##Summary`, `### Summary`, `## **Summary**`, `**## Summary**`, `## Summary:`, and
    /// `## Summary of changes`. Requiring the heading to sit alone on its line was too strict — a
    /// single trailing colon left a whole monologue in the posted review.
    private static let summaryHeading = #"^[ \t]*\**[ \t]*#{1,4}[ \t]*\**[ \t]*Summary\b"#

    /// Drops any narration DeepSeek emits before the review proper.
    ///
    /// Claude and Codex return only their final message, but a chat completion arrives as one blob
    /// that often opens with the model thinking out loud. That would be posted verbatim to GitHub.
    /// When the contract's first heading is present, everything before it is scratch work; when it
    /// is not, the output is left alone rather than risk discarding the whole review.
    static func trimmedToContract(_ output: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "(?m)" + summaryHeading),
              let match = regex.firstMatch(
                  in: output,
                  range: NSRange(output.startIndex..., in: output)
              ),
              let range = Range(match.range, in: output),
              range.lowerBound != output.startIndex else {
            return output
        }
        return String(output[range.lowerBound...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// True when the output already opens with the contract's structure, so it is a finished review
    /// rather than more thinking-out-loud.
    static func followsContract(_ output: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: summaryHeading) else { return false }
        return regex.firstMatch(
            in: output,
            range: NSRange(output.startIndex..., in: output)
        ) != nil
    }

    private func openingMessage(worktree: URL, toolsOffered: Bool) -> String {
        let tools = WorktreeTools(root: worktree)
        let diff = tools.rawContents(of: ".review-bot-diff.patch")
            ?? missing(".review-bot-diff.patch", toolsOffered: toolsOffered)
        let thread = tools.rawContents(of: ".review-bot-thread.md")
            ?? missing(".review-bot-thread.md", toolsOffered: toolsOffered)

        let howToInvestigate = toolsOffered
            ? """
            Use `read_file`, `search`, and `list_files` to open the files the diff touches and to \
            confirm how the changed code is used elsewhere before you rate any finding. Re-read \
            any file reproduced below with `read_file` if it was truncated.
            """
            : """
            You have no tools on this attempt — everything you can see is reproduced below and \
            there is no way to open another file. Rate findings on that alone, and say what you \
            could not check rather than assuming it.
            """

        return """
        Review the pull request checked out in this worktree, following the contract above.

        \(howToInvestigate) Every `BLOCKING` or `SHOULD_FIX` finding must cite a line this diff \
        adds or changes.

        --- BEGIN .review-bot-diff.patch ---
        \(clip(diff, to: Limits.inlinedDiffCharacters, continuable: toolsOffered))
        --- END .review-bot-diff.patch ---

        --- BEGIN .review-bot-thread.md ---
        \(clip(thread, to: Limits.inlinedThreadCharacters, continuable: toolsOffered))
        --- END .review-bot-thread.md ---

        \(mergePreviewSection(tools, toolsOffered: toolsOffered))
        """
    }

    /// The merge preview, inlined like the diff and thread rather than left to `read_file`.
    ///
    /// The contract grants the scope gate exactly one exception — a defect that appears only once
    /// the pull request merges — and rests it on the evidence in `.review-bot-merge.md`. Telling a
    /// model to consult a file it cannot open is worse than not mentioning it: on the
    /// tools-unsupported path there are no tools at all, and even with tools a reviewer that never
    /// thinks to ask reaches the exception with nothing behind it.
    private func mergePreviewSection(_ tools: WorktreeTools, toolsOffered: Bool) -> String {
        guard let contents = tools.rawContents(of: ".review-bot-merge.md") else {
            // Absence is itself the answer the contract asks for, so state it rather than leaving
            // the model to infer it from a file that is merely not mentioned.
            return """
            There is no `.review-bot-merge.md` in this worktree: the diff is what lands, and you \
            have no evidence for any finding about the merge.
            """
        }
        return """
        --- BEGIN .review-bot-merge.md ---
        \(clip(contents, to: Limits.inlinedMergePreviewCharacters, continuable: toolsOffered))
        --- END .review-bot-merge.md ---
        """
    }

    private func missing(_ path: String, toolsOffered: Bool) -> String {
        toolsOffered
            ? "(unavailable — read \(path) with read_file)"
            : "(unavailable, and this attempt has no tools to read it with)"
    }

    /// `continuable` is false when the model has no tools, where pointing it at `read_file` for
    /// the rest would describe a capability it does not have.
    private func clip(_ value: String, to limit: Int, continuable: Bool) -> String {
        guard value.count > limit else { return value }
        let advice = continuable
            ? "use read_file with an offset to continue."
            : "the rest is not available on this attempt."
        return String(value.prefix(limit)) + "\n… truncated here; " + advice
    }
}
