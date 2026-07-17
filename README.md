# Review Bot

Review Bot is a native macOS menu-bar app that watches local GitHub repositories for pull requests requesting a review from the signed-in `gh` user. It reviews each new request in an isolated Git worktree with Claude, Codex, or both, then submits an approval, change request, or neutral review to GitHub.

The app stores no GitHub or AI credentials. It uses each developer's existing authenticated command-line tools.

## Features

- Add and independently enable multiple local Git repositories.
- Poll every 5, 15, or 30 minutes, or every hour.
- Pause and resume automatic monitoring from the menu bar or settings.
- See explicit Pending and Running review queues in the menu-bar popover.
- Run an immediate manual check even while monitoring is paused.
- Independently enable Claude and Codex and configure each model and effort level.
- Append a small developer-specific instruction prompt to every review.
- Enforce repository-specific rules from `REVIEW.md`.
- Run enabled reviewers independently in a read-only worktree.
- Post the strictest reviewer decision through `gh pr review`.
- Keep activity history, detailed logs, and generated review Markdown locally.
- Avoid duplicate reviews while allowing a new commit or a new review request at the same commit to trigger another review.
- Optionally launch at login after the app is installed in `/Applications`.

## Requirements

- macOS 14 or newer.
- Xcode 16 or newer, or a compatible Swift toolchain, to build the app.
- GitHub CLI (`gh`), authenticated with `gh auth login`.
- At least one authenticated reviewer CLI:
  - `claude`
  - `codex`
- Local Git repositories with an `origin` remote on `github.com`.

The configured GitHub account needs permission to read the repository and submit pull-request reviews.

## Build and install

```bash
make test
make app
```

This creates `dist/Review Bot.app`. Move it into `/Applications`, open it once from Finder, and look for the Review Bot icon in the menu bar.

The build script uses ad-hoc signing by default, which is suitable when each developer builds the app locally. For a team-distributed, notarized build, provide a Developer ID identity:

```bash
CODE_SIGN_IDENTITY="Developer ID Application: Example Corp (TEAMID)" make app
```

Notarization is intentionally left to the distributing organization's release pipeline.

For development without packaging:

```bash
make run
```

Launch-at-login registration only works reliably from the packaged app in `/Applications`.

## First-time setup

1. Open the menu-bar icon and choose **Settings…**.
2. Add one or more local Git repository folders.
3. Confirm the inferred `owner/repository` GitHub slug.
4. Enable Claude, Codex, or both and set their model and effort values.
5. Choose a polling interval.
6. Optionally add global custom review instructions.
7. Select **Run now** to verify the setup.

CLI availability is shown on the Reviewers tab. Review Bot searches common Homebrew, local-user, and npm binary directories in addition to the process `PATH`.

## `REVIEW.md` policy

Repositories may place a `REVIEW.md` file at their root. Review Bot loads the file from the pull request's base commit and includes its complete contents as mandatory instructions for every enabled reviewer.

Using the base-commit version is deliberate: a pull request cannot weaken its own review rules. A change to `REVIEW.md` starts governing later pull requests after that change is merged. Repository rules can add severity definitions, architectural checks, testing expectations, or project conventions, but cannot override Review Bot's read-only execution or required machine-readable verdict.

Example:

```markdown
# Review rules

- Treat destructive schema changes without a rollback plan as Blocking.
- Changes under `Sources/Billing` require billing integration tests.
- Public API removals require an explicit migration note.
```

## Review decisions

Every enabled reviewer must end with one verdict:

- `BLOCKING`
- `SHOULD_FIX`
- `NITS_ONLY`
- `CLEAN`

Review Bot uses the strictest result:

| Results | GitHub action |
| --- | --- |
| Every enabled reviewer returns a verdict; the strictest is `BLOCKING` or `SHOULD_FIX` | Request changes |
| Every enabled reviewer returns `NITS_ONLY` or `CLEAN` | Approve |
| Any enabled reviewer fails or returns no parseable verdict | Nothing is posted; the request is retried on the next poll |

Review Bot only posts when every enabled reviewer finishes with a parseable verdict. A failure (for example a reviewer timing out) posts nothing and leaves the request unmarked, so a later poll retries it rather than submitting a partial or broken review.

When two reviewers disagree across the gate — one wants changes while the other approves — Review Bot runs one more read-only reconciliation pass that re-checks each blocking finding against the actual diff and its scope, then uses that adjudicated verdict instead of blindly taking the strictest. This keeps one reviewer's mistaken blocker from stopping a correct pull request. The reconciliation and its verdict are shown in the posted review.

Every finding is also held to a scope gate: a defect may only block or request changes when it lives on a line the pull request adds or changes. Pre-existing issues, code outside the diff, and behavior owned by third-party dependencies are surfaced as notes, never as merge blockers.

Generated reviews clearly identify each reviewer and preserve their findings in collapsible sections.

## Runtime flow

1. Poll each enabled repository for open PRs with `review-requested:@me`.
2. Read the head commit and latest matching `review_requested` event.
3. Skip the request if that exact commit and request event was completed previously.
4. Fetch the PR head and create a detached worktree under Review Bot's private data directory.
5. Save the unified diff and existing PR discussion inside the worktree.
6. Load trusted `REVIEW.md` rules from the base commit.
7. Run enabled reviewers with read-only tools and a 15-minute timeout.
8. If any enabled reviewer fails or returns no parseable verdict, post nothing and leave the request unmarked so a later poll retries it.
9. If the reviewers disagree across the gate, run one read-only reconciliation pass and use its adjudicated verdict.
10. Otherwise aggregate the verdicts, save the Markdown, and submit the resulting decision through the authenticated GitHub CLI.
11. Mark the request completed only after GitHub accepts it, then remove the worktree.

If submission fails, the request is not marked complete and will be retried during a later poll.

## Local data

Review Bot writes to:

```text
~/Library/Application Support/ReviewBot/
├── config.json
├── history.json
├── reviewed.json
├── logs/
├── reviews/
└── worktrees/
```

- `config.json` contains app settings and repository paths.
- `history.json` backs the activity-history interface and is capped at 2,000 entries.
- `reviewed.json` contains deduplication keys.
- `logs/` contains daily operational logs.
- `reviews/` contains the aggregated Markdown submitted to GitHub.
- `worktrees/` is temporary and normally empty between reviews.

Use **History → Show data folder** to open this location.

## Privacy and safety

- Source code inspected by Claude or Codex is handled according to the account and provider configuration of those CLIs.
- Review Bot does not start a shell for repository values, PR titles, prompts, or paths; commands are passed as argument arrays.
- Claude is restricted to read/search tools. Codex runs with its read-only sandbox.
- Review work never modifies the developer's current branch or working tree.
- No review is marked complete until GitHub accepts the submitted result.

## Tests

```bash
make test
```

The suite contains unit tests for remote parsing, settings migration, prompt composition, verdict parsing, decision precedence, gate-disagreement detection, and repository inspection. Mocked feature tests exercise the complete polling and review workflow, including worktree preparation, trusted `REVIEW.md` injection, Claude approval, Codex change requests, reviewer-disagreement reconciliation, deduplication, failed-post history, and retry behavior without accessing GitHub or an AI provider.

## Roadmap

Planned improvements, not yet implemented, roughly in priority order:

- **Verification pass on every gating review.** A second read-only pass currently reconciles the verdict only when the two reviewers disagree. Extend it to run whenever a review would request changes — including single-reviewer setups — so one reviewer's mistaken blocker is caught before it is posted.
- **Path-scoped `REVIEW.md` rules.** Let rules attach to file globs (for example `Sources/Billing/**`) so a rule applies only when the pull request changes a matching file, instead of every rule applying to every review. Flat `REVIEW.md` files keep working as global rules.
- **Incremental review of new commits.** When a pull request receives a new commit, review only what changed since the previous review rather than re-reviewing the whole diff, to avoid repeating findings on unchanged code.
- **Deterministic linters as grounding.** Optionally run the repository's own read-only linters on the changed files and provide their output to the reviewers as evidence, without building the project.
- **Per-repository learnings.** When an author explains that a finding was wrong, remember that locally and apply it to later reviews of the same repository.
- **Severity labels on findings.** Tag each finding by severity in the posted review so it is easy to triage at a glance.
