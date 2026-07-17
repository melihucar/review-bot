# Changelog

All notable changes to Review Bot are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Each tagged release publishes the notes from its matching version section below, so
keep `## [Unreleased]` up to date as changes land. To cut a release, rename
`## [Unreleased]` to `## [<version>] - <date>` and start a fresh empty `## [Unreleased]`.

## [Unreleased]

### Added

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

[Unreleased]: https://github.com/melihucar/review-bot/compare/v0.1.3...HEAD
[0.1.3]: https://github.com/melihucar/review-bot/compare/v0.1.2...v0.1.3
[0.1.2]: https://github.com/melihucar/review-bot/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/melihucar/review-bot/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/melihucar/review-bot/releases/tag/v0.1.0
