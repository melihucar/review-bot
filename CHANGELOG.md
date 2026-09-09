# Changelog

All notable changes to Review Bot are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Each tagged release publishes the notes from its matching version section below, so
keep `## [Unreleased]` up to date as changes land. To cut a release, rename
`## [Unreleased]` to `## [<version>] - <date>` and start a fresh empty `## [Unreleased]`.

## [Unreleased]

### Added

- **Reviewer time limits are configurable.** Every reviewer was fixed at 15 minutes, and a pull request that ran over produced nothing at all — the reviewer was cut off at exactly 900 seconds and the panel shrank to whoever else finished. Each reviewer card now carries a **Time limit** stepper (1–240 minutes, default 15). It is per reviewer rather than global so raising one to finish a large diff does not silently raise the rest, and decoding clamps the value, since this one bounds a running process.

### Fixed

- **A pull request too large for GitHub's diff API is now reviewed from the local clone.** `gh pr diff` answers anything over 20,000 lines with an HTTP 406, which is a property of the API rather than of the pull request — so the review failed, retried, and burned its whole failure budget on a condition no retry could ever get past. Review Bot already fetches both the pull request head and its base branch before the review starts, so the same three-dot diff is now computed locally when the API refuses, with no line ceiling. `git diff base...head` is exactly what `gh pr diff` asks the API to render, so reviewers cannot tell which route produced the patch; a review only fails now if the clone cannot produce the diff either, and the message says so rather than pointing at GitHub's limit alone.
- **A reviewer that says it could not assess a pull request no longer produces an approval.** The review contract requires a trailing verdict line, so a reviewer that spent its whole turn failing to reach the diff still signed off with `NITS_ONLY` — "I found no problems" being literally true of a review that looked at nothing — and the panel read that as an approval. The body now overrides the verdict line: a review that states in its own words that it could not be assessed has its verdict withdrawn and does not count toward the decision, and it is not re-run inside the same review, because a second pass re-reads the same unreadable evidence. If another reviewer did finish, the decision is theirs and the withdrawal is disclosed in the posted body. If none did, Review Bot now posts a neutral comment carrying each reviewer's own account of why, rather than staying silent and retrying until the failure budget gives up without ever telling the author anything.

## [0.1.16] - 2026-09-09

### Added

- **A poll now reviews several pull requests at once instead of one after another.** Every request a poll discovered was reviewed in sequence, so the last one in a backlog of five waited out four full reviews — each of them minutes of CLI time — before it started, with the machine idle in between. Reviews now run concurrently, bounded by a new **Review up to N pull requests at once** setting on the dashboard (default 3, `1` restores the old behaviour). The bound is the point: each pull request runs *every* enabled reviewer, so an unbounded queue would put a dozen reviewer processes against the same API at the same time.
- The menu bar's queue lists every review currently running, not just one.

### Changed

- The git steps of a review — the fetch, `worktree add`, and the worktree cleanup — are serialized per repository, since concurrent reviews of pull requests in the same repository share one clone and would contend for git's ref and index locks. A loser of that race fails with something like "cannot lock ref", which nothing downstream could distinguish from a real failure: it would spend the request's retry budget and back the review off. The reviewer CLIs, where a review actually spends its time, still overlap freely.
- While several reviews run, the status line reports the queue's progress ("Reviewed 2 of 5 pull requests…") rather than flickering between the pull requests competing for it. A lone review still narrates itself as before.

### Fixed

- The menu bar showed only the most recently started review, so with concurrent reviews an earlier one would vanish from the queue while it was still running.

## [0.1.15] - 2026-08-27

### Changed

- **A reconciliation downgrade now has to justify itself.** Reconciliation exists to stop one reviewer's false blocker from gating a correct PR, so it can only ever loosen the decision — the baseline it replaces is already the strictest verdict. That makes the downgrade step the one place in the pipeline with final say and no counterweight, and a finding could be reduced below the gate on a bare severity reclassification after the adjudicator had already confirmed it was real and in scope. `DefaultPrompt.reconciliation` now separates validity from impact: once a finding survives substantiation and the scope gate, reducing it requires naming the concrete consequence — what happens at runtime, to a caller, to a stored record, or to a reader acting on the text — and why that does not warrant correcting before merge. "Polish", "documentation only", and "no realistic accident" are called out as conclusions that need their work shown rather than justifications, and a finding whose impact cannot be stated keeps the severity it was given. The step also corrects severity upward where the code supports it, so it is no longer framed as one-way.

### Fixed

- **opencode reviewed whatever directory the app was launched from, not the pull request.** Every spawned command inherited the app's environment verbatim, including `PWD`. Foundation sets a child's working directory through `currentDirectoryURL` — which changes the real `getcwd()` but leaves `PWD` pointing wherever the app was started — so the two disagreed. Most tools call `getcwd()` and never notice; `opencode` trusts `PWD` and resolves its project root from it. Launched from a terminal sitting in another repository, Review Bot therefore handed opencode that repository while its diff and thread came from the pull request, and opencode produced a fluent, specific, entirely irrelevant review of a codebase the PR had nothing to do with — with real file paths and real line numbers, so nothing in the output marked it as wrong, and its verdict counted toward the panel like any other. `ProcessRunner` now derives `PWD` from the directory the child actually runs in and drops the inherited `OLDPWD`, via the pure `composeEnvironment`. Claude and Codex were unaffected: they use the real working directory.
- **Reconciliation assumed the panel was exactly two reviewers.** `DefaultPrompt.reconciliation` builds its panel from however many reviewers ran, but its prose said "two independent automated reviews", "the two reviews to reconcile", and "do not average the two" — so enabling a third reviewer handed the adjudicator a document that miscounted its own contents and told it to weigh "the stricter one" of three. The wording is now arity-neutral. The tie-break guidance also no longer treats agreement as evidence: a panel mixes models of very different capability, so counting reviewers measures the panel rather than the code, and two weak reviewers agreeing must not outweigh one strong dissent.
- **A reviewer that failed was handed to the adjudicator as a review.** `runReconciliation` mapped every entry in `results`, which deliberately retains reviewers with no verdict so the posted body can disclose a partial panel. Their `output` is the CLI's error text, so an exhausted-quota notice or a model-not-supported line was pasted in under a `REVIEW (verdict: unavailable)` header — inviting the adjudicator to weigh a failure message as a dissenting opinion, in the one step that has final say over the decision. Such a reviewer also cannot be part of the disagreement being resolved, since `gateDisagreement` counts only parsed verdicts. The panel is now restricted to reviewers that reached a verdict, and the prompt states that an absent name is absence of evidence rather than agreement. The partial-panel disclosure in the posted comment is unchanged.

## [0.1.14] - 2026-08-27

### Fixed

- **The app did not poll until someone opened its menu.** `AppModel.start()` — which launches the scheduler — was called only from `.task` on `MenuBarView` and `DashboardView`. `MenuBarView` is the popover's *content*, and SwiftUI does not instantiate it until the menu bar icon is clicked, so a freshly launched Review Bot watched nothing at all until a human happened to click it. This hit hardest in the configuration the app is built for: started at login, it would sit idle indefinitely, and the icon looked identical to a bot that was working. The scheduler now starts from the menu bar label, which is always rendered; `start()` was already idempotent.
- **A partial-panel disclosure quoted the echoed prompt instead of the error.** `inlineDetail` truncated the captured failure from the head, but a CLI states its diagnosis last — Codex echoes the whole prompt, which embeds the repository's `REVIEW.md`, to stderr before reporting why it failed. The posted comment therefore carried a slab of internal review rules into a public PR thread and none of the actual error. It now keeps the tail, matching `conciseError`.

## [0.1.13] - 2026-08-27

### Changed

- **One reviewer's outage no longer throws away the other reviewer's work.** A review was posted only when *every* enabled reviewer finished with a readable verdict, so a single CLI failing meant no review at all — and, because the request stayed unmarked, the whole pipeline (fetch, worktree, full diff, every reviewer at up to 900s) re-ran each poll until the failure budget abandoned it. Observed on a pull request where Codex's usage limit was exhausted: four consecutive reviews, each with a complete and useful Claude review in hand, were discarded, and the only way to get a review out was to disable Codex by hand. The review now posts as long as at least one reviewer produced a verdict, and the posted body names the reviewer that did not contribute and why, so a partial panel is never mistaken for a unanimous one. Nothing is posted when *no* reviewer produced a verdict — that case still leaves the request for the next poll.
- **A reviewer that fails for a reason a retry cannot fix is no longer re-run inside the review.** An exhausted quota, a rejected credential, or a model the account may not use fails identically on the second call, so the retry only delayed the review the surviving reviewers could already produce. Classification is deliberately conservative: anything unrecognised is still treated as retryable. Timeouts continue not to be retried in place, as before.

### Fixed

- **A failed command reported the beginning of its output instead of the reason it failed.** `codex` echoes the whole review prompt to stdout before failing, so an exhausted usage limit was logged as `Codex failed (Reading additional input from stdin…` — the prompt, not the error, which is neither readable nor classifiable. Failures now prefer stderr, then the lines that announce an error, then the tail.
- **The merge preview never ran on the pull requests that needed it most.** It resolved the base branch from `baseRefOid`, which is the snapshot GitHub reports in `gh pr view` rather than the base ref's live tip. As soon as an author merges the base branch in — the ordinary way to resolve a conflict — that snapshot becomes an ancestor of the pull request head, so the "how far has the base moved" count collapsed to `0` and the preview was silently skipped. The effect was backwards: a branch that had been synced once, and so was most likely to drift again, was exactly the branch that got no preview. Observed on a pull request GitHub itself reported as `behind_by=1`, where the base had since moved a commit that touched a file the pull request also changed. The base is now resolved from `refs/remotes/origin/<baseRefName>`, falling back to `baseRefOid` only when that ref will not resolve.
- The base-branch fetch now names its destination (`+refs/heads/<name>:refs/remotes/origin/<name>`). A bare `refs/heads/<name>` refspec only lands in `FETCH_HEAD`; the remote-tracking ref the merge preview reads was updated merely as an opportunistic side effect of the clone's configured fetch refspec, which is not a guarantee.

## [0.1.12] - 2026-08-27

### Added

- **Merge preview: reviewers now see the pull request as it will land, not only as it was written.** `gh pr diff` is a three-dot diff — the PR against the commit it was *cut from* — and the review worktree is checked out at the PR's head, so nothing a reviewer could read reflected the base branch. A branch that went stale mid-review could therefore delete a symbol the base still called and no reviewer could see it. A new `.review-bot-merge.md` in the worktree reports the conflicting paths, the paths **both** sides changed since the merge base, the files the PR deletes that the base still modifies, and the base branch's own diff for those paths as inline evidence (restricted to the overlap, which is what makes it affordable; capped, with any dropped path named rather than silently missing). The overlap list is the point: the dangerous case has *no* merge conflict at all — when one side removes a `use` line and the other edits a different method, git auto-merges the two into code that no longer compiles. The file is written only when the base branch has actually moved ahead; a pull request that is current with its base produces no preview and costs nothing extra, since its diff is already exactly what lands.
- The scope gate gains one narrow exception to match: a defect that appears only once the PR merges may be `BLOCKING` even though its `path:line` is not an added line in the diff, since the diff cannot contain it by construction. It is limited to PR-versus-base interactions, requires the evidence to name the concrete breakage, and explicitly does not make staleness on its own a reportable finding. The reconciliation prompt honours the same exception, so an adjudicator no longer overturns a merge finding for lacking a diff anchor.

### Fixed

- Restored the `## [Unreleased]` section and the truncated release instructions in this file; both were lost when 0.1.11 was cut.

## [0.1.11] - 2026-08-24

### Added

- **Bounded retries for reviews that never post.** A review request whose reviewers fail (or return no verdict), or whose post GitHub rejects, is still retried — but attempts are now counted, spaced by a widening backoff (the first retry stays immediate, then the added gap doubles each time — 15m, 45m, 1h45m at the default poll interval, capped at 4 hours), and abandoned after a configurable budget. A new **Failure budget** box on the Reviewers tab sets that budget (default 5 attempts, or off for the previous unbounded behavior). Previously a permanently broken reviewer — a missing CLI, a bad model name, expired auth — re-ran the whole pipeline (fetch, worktree, full diff, every reviewer at up to 900s) on *every* poll forever and flooded the history with failures. A new commit or re-request starts the budget over, and **Run now** ignores both the backoff and the budget — so fixing the cause and clicking it resumes abandoned requests. While any request is paused this way, the status line says so instead of reporting a quiet "Watching 1 repository".
- Failure entries in history now say which attempt failed and what happens next ("Attempt 2 of 5 — retrying in about 15 minutes.").

### Changed

- **A reviewer that fails is run again within the same review** instead of discarding the whole review and waiting out a poll interval. The worktree, diff and thread are already prepared, so the retry costs one CLI invocation rather than the entire pipeline, and the other reviewers' work is not thrown away. Timeouts are not retried in place — re-running a hung CLI would just spend its 900s again — and are left to the poll-level backoff.
- The re-review limit caption now states that it counts reviews that were actually posted; failed attempts are governed by the new failure budget instead.

### Fixed

- **A failed `gh` timeline lookup no longer swallows a re-request** ([#6](https://github.com/melihucar/review-bot/issues/6)). The marker lookup fell back to the pull request's head commit whenever the command failed — and that key is usually one an earlier review already recorded, so a rate limit or a network blip turned a genuine re-request at the same commit into a silent skip: no review, no history entry, no log line. A failed lookup is now reported as a failure and retried on the next poll; the fallback stays for the honest case of a timeline with no `review_requested` event.
- Pull requests that cannot be inspected (metadata or timeline) are now bounded by the same failure budget and backoff as failing reviews, so a renamed repository or a token that lost access no longer posts a failure entry on every poll forever.

## [0.1.9] - 2026-08-18

### Changed

- **Prompt-injection hardening.** Pull-request threads are now treated as untrusted input end to end: reviewers are told explicitly that thread content (including planted `VERDICT:` lines) is data, never instructions; and before the bot may post an approval, deterministic checks verify that (a) no `VERDICT:` line was planted in the thread or diff, and (b) no reviewer's own prose contradicts its verdict (a permissive verdict that describes a merge blocker is not trusted). A flagged approval posts as a neutral comment with a disclosure instead, so the worst outcome of an injected thread is a comment, never an auto-approval. The Reviewers tab also warns when a small/experimental model is selected, since those measurably degrade under adversarial thread content.
- CI and release workflows now run on the Node 24 action runtime: `actions/checkout@v5` and `softprops/action-gh-release@v3` (both actions previously used the deprecated Node 20 runtime).

## [0.1.8] - 2026-08-17

### Added

- **opencode as a third reviewer** (Reviewers tab). Off by default; when enabled it runs `opencode run` in the worktree under a dedicated read-only agent — every tool except Read/Grep/Glob is denied, project `opencode.json` and `.opencode` files shipped in the pull request cannot override that, and plugins are disabled (`--pure`). The default model is `opencode/deepseek-v4-flash-free` at **max** reasoning effort, since the model is free. It participates in the same parallel run, strictest-verdict aggregation, and reconciliation path as Claude and Codex.

### Changed

- The default Claude reviewer is now `claude-opus-5` at **high** effort (was `claude-opus-4-8` at max). Existing configurations keep the model and effort they already have; only fresh installs and out-of-range effort values pick up the new default.

## [0.1.7] - 2026-07-20

### Fixed

- CLIs installed through a version manager (nvm, mise, volta, fnm, asdf) are now found when the app is launched from Finder or at login. Such an app inherits launchd's minimal `PATH`, which excluded those install dirs, so `claude`/`codex` showed as "not found" and no reviews could run ([#1](https://github.com/melihucar/review-bot/issues/1)). `ProcessRunner` now probes the login+interactive shell for its real `PATH` once at startup (behind a sentinel marker and a `perl alarm` timeout so a chatty or hanging rc file can't corrupt or stall it), prepends it, and keeps the previous fixed directory list as a fallback.

## [0.1.6] - 2026-07-20

### Added

- A **re-review limit** setting (Reviewers tab): cap how many times a single pull request is reviewed across new commits and re-requests. Set an integer limit or leave it unlimited (default). Once a PR reaches the limit, further commits and re-requests on it are skipped.

## [0.1.5] - 2026-07-18

### Added

- A **review scope** setting (Reviewers tab): choose whether reviewers see the **whole PR** every time (default) or **only the new changes** since the last posted review. Incremental mode diffs the current head against the commit last reviewed, so reviewers focus on new work and don't re-flag already-reviewed code; it falls back to the whole PR on the first review, on a re-request with no new commits, or when the prior commit is no longer available locally.

## [0.1.4] - 2026-07-18

### Added

- A configurable **decision policy** (new "Decisions" settings tab). For each reviewer severity — Should-fix, Nits only, Clean — you choose whether Review Bot **Approves**, **Leaves it to you** (posts a neutral comment), or **Requests changes**. `BLOCKING` always requests changes and is locked. Defaults match prior behavior, so existing configs are unchanged, and reviewer-disagreement reconciliation now follows the configured request-changes boundary.
- A roadmap section in the README outlining planned improvements.
- This `CHANGELOG.md`; each tagged release now sources its GitHub Release notes from the matching version section here.

## [0.1.3] - 2026-07-17

### Added

- Reviewer-disagreement reconciliation: when two reviewers land on opposite sides of the merge gate, a third read-only pass re-checks each blocking finding for substance and scope and decides the final verdict, so one reviewer's mistaken blocker no longer gates a correct pull request. The reconciliation and its verdict are shown in the posted review.

### Changed

- Hardened the review contract with a scope gate. A finding may only block or request changes when its `path:line` is a line the pull request adds or changes; pre-existing issues, code outside the diff, and behavior owned by third-party dependencies are surfaced as notes, never as merge blockers. Framework-behavior claims must be verified before they can block.

## [0.1.2] - 2026-07-16

### Changed

- Gated severity by scope: pre-existing defects found outside the pull request's changes are reported as notes and never block the merge.

## [0.1.1] - 2026-07-15

### Fixed

- A failed reviewer (for example a timeout) no longer posts a partial or broken review; the pull request is left unmarked and retried on the next poll.
- Stopped the review prompt from leaking into posted comments, history, or logs when a command fails or times out.

## [0.1.0] - 2026-07-15

### Added

- Initial release: a macOS menu-bar app that reviews GitHub pull requests requesting a review from the signed-in `gh` user, using local Claude and Codex CLIs in an isolated read-only worktree.
- Multiple repositories with independent enable/disable, a configurable polling interval, and pause/resume.
- Claude and Codex reviewers with per-reviewer model and effort settings, a global custom prompt, and mandatory `REVIEW.md` rules loaded from the trusted base commit.
- Strictest-verdict decision posted through `gh pr review`, with deduplication, activity history, logs, and saved review Markdown.
- DMG packaging and a tagged-release workflow that builds and publishes the app.

[Unreleased]: https://github.com/melihucar/review-bot/compare/v0.1.16...HEAD
[0.1.16]: https://github.com/melihucar/review-bot/compare/v0.1.15...v0.1.16
[0.1.15]: https://github.com/melihucar/review-bot/compare/v0.1.14...v0.1.15
[0.1.14]: https://github.com/melihucar/review-bot/compare/v0.1.13...v0.1.14
[0.1.13]: https://github.com/melihucar/review-bot/compare/v0.1.12...v0.1.13
[0.1.12]: https://github.com/melihucar/review-bot/compare/v0.1.11...v0.1.12
[0.1.11]: https://github.com/melihucar/review-bot/compare/v0.1.9...v0.1.11
[0.1.9]: https://github.com/melihucar/review-bot/compare/v0.1.8...v0.1.9
[0.1.8]: https://github.com/melihucar/review-bot/compare/v0.1.7...v0.1.8
[0.1.7]: https://github.com/melihucar/review-bot/compare/v0.1.6...v0.1.7
[0.1.6]: https://github.com/melihucar/review-bot/compare/v0.1.5...v0.1.6
[0.1.5]: https://github.com/melihucar/review-bot/compare/v0.1.4...v0.1.5
[0.1.4]: https://github.com/melihucar/review-bot/compare/v0.1.3...v0.1.4
[0.1.3]: https://github.com/melihucar/review-bot/compare/v0.1.2...v0.1.3
[0.1.2]: https://github.com/melihucar/review-bot/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/melihucar/review-bot/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/melihucar/review-bot/releases/tag/v0.1.0
