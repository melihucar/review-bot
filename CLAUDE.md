# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

```bash
make build          # swift build (debug)
make run            # swift run ReviewBot (dev; launch-at-login only works from the packaged app)
make test           # swift test
make app            # scripts/build-app.sh → dist/Review Bot.app (ad-hoc signed by default)
make clean          # swift package clean

swift test --filter VerdictTests              # run one test case/suite
swift test --filter ReviewEngineFeatureTests  # run the mocked end-to-end workflow tests
```

Signed/notarizable build: `CODE_SIGN_IDENTITY="Developer ID Application: …" make app`.

Note: `Package.swift` uses swift-tools 6.0 but pins **Swift 5 language mode**, so strict concurrency checks are relaxed even though the code uses actors/`@MainActor`.

## Architecture

A macOS menu-bar app (`MenuBarExtra`, `LSUIElement` accessory — no Dock icon) that reviews GitHub PRs by shelling out to CLIs. **It stores no credentials**: all GitHub/AI access goes through the developer's already-authenticated `gh`, `claude`, and `codex` binaries.

**Everything runs through `ProcessRunner` (`CommandRunning` protocol), never a shell.** Commands are argument arrays (no interpolation into a shell string). `ProcessRunner` wraps each command in `perl -e 'alarm …; exec'` for a hard timeout, and augments `PATH` with Homebrew/`~/.local/bin`/npm dirs so GUI-launched processes find the CLIs. The protocol is the seam for testing — inject a mock `CommandRunning` to exercise the whole workflow without touching GitHub or an AI provider (see `ReviewEngineFeatureTests`).

**Layers:**
- `ReviewBotApp` → `MenuBarView` (popover) / `DashboardView` (settings window). `AppModel` (`@MainActor` `ObservableObject`) owns UI state and a 2-second scheduler loop that fires `ReviewEngine.poll` when the poll interval elapses (unless paused). "Run now" polls even while paused.
- `ReviewEngine` (`actor`) is the core workflow — discovery, worktree prep, running reviewers, aggregation, submission. See flow below.
- `Storage.swift` holds the persistence types: `StoragePaths` (all files under `~/Library/Application Support/ReviewBot/`), `SettingsStore` (auto-saves `config.json` on every mutation via `didSet`), `HistoryStore` (`history.json`, capped 2,000), `ReviewedStateStore` (`reviewed.json` dedup keys), and `ActivityLogger` (daily logs).

**Review flow (`ReviewEngine.poll` → `discoverPendingReviews` → `review`):**
1. `gh search prs --review-requested=@me` per enabled repo, then `gh pr view` for metadata.
2. Dedup key = `slug#number@headRefOid@requestMarker`, where `requestMarker` is the timestamp of the latest `review_requested` timeline event (falls back to head OID). This makes a **new commit or a re-request at the same commit** trigger a fresh review, while an already-completed request is skipped.
3. `git worktree add --detach` at the PR head under `worktrees/`; write `.review-bot-diff.patch` and `.review-bot-thread.md` (PR conversation + reviews + inline comments) into it.
4. Load trusted `REVIEW.md` via `git show <baseRefOid>:REVIEW.md` — **from the base commit, so a PR can't weaken its own review rules.**
5. Run enabled reviewers **in parallel** (`async let`), each read-only (`claude --allowedTools Read Grep Glob`; `codex exec -s read-only`), 900s timeout.
6. Each reviewer must emit a trailing `VERDICT: BLOCKING|SHOULD_FIX|NITS_ONLY|CLEAN` line (`VerdictParser`). `DecisionEvaluator` takes the **strictest** verdict: any `SHOULD_FIX`+ → request changes; all reviewers parsed and none strict → approve; any failure/unparseable verdict → neutral comment.
7. Aggregate to Markdown, save under `reviews/`, submit with `gh pr review`. **Only after GitHub accepts** is the dedup key persisted and the worktree removed — so a failed post is retried on the next poll.

**Prompt composition:** `DefaultPrompt.combined(with: customPrompt, repositoryRules:)` layers the built-in review contract + global custom prompt + per-repo `REVIEW.md`.

## Notes for changes

- Adding a reviewer CLI: extend `ReviewerName`, add a `run…` method in `ReviewEngine`, wire it into `runReviewers`, and surface config in `ReviewersSettingsView`. Keep the read-only sandbox flags.
- The settings window is created manually as an `NSWindow` (not SwiftUI `Settings` scene). Because the app is an accessory, `openSettings()` must promote the app to `.setActivationPolicy(.regular)` to bring the window forward, and revert to `.accessory` on close.
- Config decoding is defensive (`decodeIfPresent` with defaults) to survive schema migrations — preserve that when adding fields.
