# Changelog

All notable changes to Review Bot are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Each tagged release publishes the notes from its matching version section below, so
keep `## [Unreleased]` up to date as changes land. To cut a release, rename
`## [Unreleased]` to `## [<version>] - <date>` and start a fresh empty `## [Unreleased]`.

## [Unreleased]

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

[Unreleased]: https://github.com/melihucar/review-bot/compare/v0.1.7...HEAD
[0.1.7]: https://github.com/melihucar/review-bot/compare/v0.1.6...v0.1.7
[0.1.6]: https://github.com/melihucar/review-bot/compare/v0.1.5...v0.1.6
[0.1.5]: https://github.com/melihucar/review-bot/compare/v0.1.4...v0.1.5
[0.1.4]: https://github.com/melihucar/review-bot/compare/v0.1.3...v0.1.4
[0.1.3]: https://github.com/melihucar/review-bot/compare/v0.1.2...v0.1.3
[0.1.2]: https://github.com/melihucar/review-bot/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/melihucar/review-bot/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/melihucar/review-bot/releases/tag/v0.1.0
