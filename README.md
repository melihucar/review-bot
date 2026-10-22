# Review Bot

Review Bot is a native macOS menu-bar app that watches local GitHub repositories for pull requests requesting a review from the signed-in `gh` user. It reviews each new request in an isolated Git worktree with Claude, Codex, opencode, Gemini, or any combination, then submits an approval, change request, or neutral review to GitHub.

GitHub access always goes through your authenticated `gh` CLI — the app never handles GitHub credentials. AI access defaults to the same model: each reviewer CLI uses its own existing login. If you would rather bill a specific API key, Claude and Codex accept one; keys are stored in the macOS Keychain and never written to `config.json`.

## Features

- Add and independently enable multiple local Git repositories.
- Poll every 5, 15, or 30 minutes, or every hour.
- Pause and resume automatic monitoring from the menu bar or settings.
- See explicit Pending and Running review queues in the menu-bar popover.
- Run an immediate manual check even while monitoring is paused.
- Independently enable Claude, Codex, opencode, and Gemini and configure each model and effort level.
- Choose per reviewer whether to use its signed-in CLI or an API key held in the macOS Keychain (Claude and Codex; opencode authenticates through its own configuration).
- Track tokens and cost per review for the reviewers billed per token, and optionally publish that in the review.
- Append a small developer-specific instruction prompt to every review.
- Enforce repository-specific rules from `REVIEW.md`.
- Run enabled reviewers independently in a read-only worktree.
- Post the strictest reviewer decision through the GitHub CLI, pinned to the commit that was reviewed.
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
  - `opencode` (opt-in reviewer; defaults to the free `opencode/deepseek-v4-flash-free` model at max effort)
  - `gemini` (opt-in reviewer; defaults to `gemini-3-pro-preview`. Its CLI has no effort setting, so that card has no effort control)
- At least one reviewer CLI:
  - `claude` — authenticated, or an Anthropic API key.
  - `codex` — authenticated, or an OpenAI API key.
  - `opencode` — authenticated through its own configuration. Opt-in; defaults to the free `opencode/deepseek-v4-flash-free` model at max effort.
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
4. Enable Claude, Codex, opencode, or Gemini and set their model and effort values. opencode and Gemini are off by default.
5. Choose a polling interval.
6. Optionally add global custom review instructions.
7. Select **Run now** to verify the setup.
5. For each reviewer, choose **Signed-in CLI** or **API key**; in key mode, paste the key and select **Save**. opencode uses its own configuration and has no key field.
6. Choose a polling interval.
7. Optionally add global custom review instructions.
8. Select **Run now** to verify the setup.

CLI availability is shown on the Reviewers tab. Review Bot asks your login shell for its `PATH` at startup — so CLIs installed through a version manager (nvm, mise, volta, fnm, asdf) are found even when the app is launched from Finder or at login — and also searches common Homebrew, local-user, and npm binary directories in addition to the process `PATH`.

## Reviewers and credentials

Each reviewer independently chooses where its credentials come from:

| Mode | Behavior |
| --- | --- |
| **Signed-in CLI** (default for `claude` and `codex`, and the only mode for `opencode`) | Review Bot passes no credentials; the CLI uses its own login. Any `ANTHROPIC_API_KEY`/`OPENAI_API_KEY` inherited from your shell is explicitly unset, so the CLI cannot silently bill a different account. opencode is handed `OPENCODE_CONFIG_DIR`/`OPENCODE_CONFIG_CONTENT` rather than a key, so it offers no credential picker at all. |
| **API key** | The key you saved is passed to that reviewer only, as `ANTHROPIC_API_KEY` or `OPENAI_API_KEY`. |

Keys are stored in your login Keychain under "Review Bot reviewer API keys" and are never written to `config.json`, the activity history, the daily logs, or a posted review. A reviewer set to API-key mode with no saved key fails with a message saying so, rather than quietly running under some other account. That failure is terminal — it will fail the same way however often it is called — so the reviewer is not run again inside that review; only a settings change fixes it.

Because the app is ad-hoc signed by default, macOS asks for your login password to read a saved key after a rebuild, and "Always Allow" does not stick — it authorizes the one build in front of it. Each Keychain item records the identity of the app that saved it, and with no signing identity that record is a hash of the binary, so every rebuild looks like a different application. Only a Developer ID fixes it (`CODE_SIGN_IDENTITY="Developer ID Application: …" make app`), because the item can then record your team identity, which rebuilds keep. A self-signed certificate is not enough — it was tested; the item still falls back to recording the binary hash.

For development, a reviewer already set to **API key** can take its key from Review Bot's own environment instead of the Keychain: `ANTHROPIC_API_KEY` and `OPENAI_API_KEY` are read when set, taking precedence over a saved key — useful for `make run` or a one-off script without saving anything, and it skips the Keychain prompt entirely. It changes nothing about the default **Signed-in CLI** mode, which still unsets those variables, so exporting a key without also switching that reviewer to API key leaves it on its own login. This only helps when the app is started from a shell: launched from Finder or at login it inherits launchd's environment, so the packaged app reads the Keychain.

### Token usage and cost

Reviews are metered for the reviewers you pay per token. Every provider call a reviewer makes is counted — including the extra attempt when a reviewer is re-run inside the same review, and the reconciliation pass, which is a full extra call charged to whichever reviewer adjudicated — and the total is written to the activity history, so you can see what a particular pull request cost and total spend from `history.json`. **Reviewers → Usage and cost** controls whether the same figures are appended to the posted GitHub review; tracking happens either way.

| Reviewer | Tokens | Cost |
| --- | --- | --- |
| Claude | Reported by the CLI | Reported by the CLI — no prices to configure |
| Codex | Not reported | Not available |
| opencode | Not reported | Not available |

Claude's figures come from `claude --output-format json`, which Review Bot now passes on every run. Output that is not that envelope is read as the review itself, so a CLI that accepts the flag and prints plain text still reviews normally — but the flag is not optional and there is no fallback re-run, so a `claude` too old to accept it fails outright with the CLI's own error.

A reviewer using its signed-in CLI is left out entirely: that cost is a flat subscription, so attributing dollars to one review would be misleading. That excludes opencode in every configuration, since it has no API-key mode. A cost that cannot be determined is shown as unknown rather than as `$0.00`.

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

Each verdict maps to a GitHub action under the configured decision policy (`BLOCKING` is always Request changes; `SHOULD_FIX`, `NITS_ONLY`, and `CLEAN` are each configurable on the dashboard). Review Bot takes the strictest configured action among the reviewers that returned a verdict:

| Results | GitHub action |
| --- | --- |
| Every enabled reviewer returns a verdict (a full panel) | The strictest configured action among them |
| Some enabled reviewer fails or returns no parseable verdict, but at least one returns a verdict (a partial panel) | The strictest configured action among the reviewers that finished — except an approval is downgraded to a neutral comment, since a partial panel never approves. Request changes and comments still post as decided. |
| No enabled reviewer returns a parseable verdict (an empty panel) | Nothing is posted; the request is retried on a later poll, within the failure budget |

A partial panel's posted review names the missing reviewer and why it is missing (failed, timed out, or returned no verdict), so a change request or comment reached without the whole panel is never mistaken for a unanimous one.

An approval can also be withheld by a deterministic injection check: if a reviewer's verdict matches a `VERDICT:` line planted in the pull request's thread or diff, or a permissive reviewer's own prose describes a merge blocker, the approval posts as a neutral comment instead and the review says why.

When two reviewers disagree across the gate — one wants changes while the other approves — Review Bot runs one more read-only reconciliation pass that re-checks each blocking finding against the actual diff and its scope, then uses that adjudicated verdict instead of blindly taking the strictest. This keeps one reviewer's mistaken blocker from stopping a correct pull request. The pass is run by a reviewer that actually returned a verdict on this pull request, so a reviewer that is down — out of quota, signed out — is not asked to adjudicate a disagreement it could not take part in. The reconciliation and its verdict are shown in the posted review.

Every finding is also held to a scope gate: a defect may only block or request changes when it lives on a line the pull request adds or changes. Pre-existing issues, code outside the diff, and behavior owned by third-party dependencies are surfaced as notes, never as merge blockers.

Generated reviews clearly identify each reviewer and preserve their findings in collapsible sections.

## Runtime flow

1. Search once per owner of the enabled repositories for open PRs with `review-requested:@me`, keeping the ones in watched repositories; a rate-limited search holds every search for a few minutes.
2. Read the head commit and latest matching `review_requested` event.
3. Skip the request if that exact commit and request event was completed previously.
4. Fetch the PR ref, the base branch, and — for a same-repository PR — its head branch, then create a detached worktree under Review Bot's private data directory; abort instead of reviewing a stale commit if the head branch moved since step 2. The reviewers' prompt states these branch facts (base, head, reviewed commit, and the head branch's freshly fetched tip) explicitly, since the worktree's other refs can be arbitrarily stale.
5. Save the unified diff and existing PR discussion inside the worktree.
6. Load trusted `REVIEW.md` rules from the base commit.
7. Run enabled reviewers with read-only tools and a 15-minute timeout.
8. If no enabled reviewer returns a parseable verdict, post nothing and leave the request unmarked so a later poll retries it.
9. If the reviewers disagree across the gate, run one read-only reconciliation pass and use its adjudicated verdict.
10. If that decision is an approval but some enabled reviewer failed, timed out, or returned no verdict, downgrade it to a neutral comment naming who is missing — a partial panel never approves.
11. If it is still an approval, run the injection check, which can downgrade it to a neutral comment.
12. Aggregate the verdicts and save the Markdown, then re-read the pull request's head; if it moved since discovery, post nothing so the next poll reviews the new commit instead.
13. Submit the decision through GitHub's pull request reviews API (`gh api`), pinned to the reviewed commit. Mark the request completed only after GitHub accepts it, then remove the worktree.

If submission fails, the request is not marked complete and will be retried during a later poll.

## Local data

Review Bot writes to:

```text
~/Library/Application Support/ReviewBot/
├── config.json
├── history.json
├── reviewed.json
├── opencode/
├── gemini/
├── logs/
├── reviews/
└── worktrees/
```

- `config.json` contains app settings and repository paths. It records which credential source each reviewer uses, never the key itself.
- `history.json` backs the activity-history interface and is capped at 2,000 entries.
- `reviewed.json` contains deduplication keys.
- `logs/` contains daily operational logs.
- `reviews/` contains the aggregated Markdown submitted to GitHub.
- `worktrees/` is temporary and normally empty between reviews.
- `opencode/` holds the read-only agent definition the opencode reviewer runs under.
- `gemini/` holds the read-only policy file the Gemini reviewer runs under.

Use **History → Show data folder** to open this location.

## Privacy and safety

- Source code inspected by Claude, Codex, opencode, or Gemini is handled according to the account and provider configuration of those CLIs.
- API keys are held in the macOS Keychain, passed only to the reviewer they belong to, and never written to configuration, history, logs, or a posted review.
- Review Bot does not start a shell for repository values, PR titles, prompts, or paths; commands are passed as argument arrays.
- Claude runs with only the `Read`, `Grep`, and `Glob` tools and cannot read outside the review worktree unless the developer's own user settings (or an organization's managed settings) explicitly allow it. It ignores the pull request's own Claude settings and MCP configuration, and runs no hooks or MCP servers from user, project, or local settings. Verified against Claude Code 2.1.212; a current `claude` CLI is required. Codex runs with its read-only sandbox. opencode runs under a read-only agent whose permissions deny everything except Read, Grep, and Glob; the pull request's own `opencode.json`/`.opencode` files cannot override that, and plugins are disabled. Gemini runs under a policy loaded at its user tier that denies shell, file writes, and web access, and denies the plan-mode transitions that would otherwise let a headless run drop into YOLO. Extensions are disabled and no MCP server is reachable. The pull request's own `.gemini` directory and `.env` are replaced with Review Bot's before any reviewer starts: a trusted workspace's `.gemini/settings.json` would otherwise run hooks and spawn MCP servers, neither of which a policy covers.
- Review work never modifies the developer's current branch or working tree.
- No review is marked complete until GitHub accepts the submitted result.

## Tests

```bash
make test
```

The suite contains unit tests for remote parsing, settings migration, prompt composition, verdict parsing, decision precedence, gate-disagreement detection, repository inspection, credential resolution, environment composition, and token-usage arithmetic and formatting. Mocked feature tests exercise the complete polling and review workflow, including worktree preparation, trusted `REVIEW.md` injection, Claude approval, Codex change requests, API-key injection and session-mode key removal, usage reporting from Claude's JSON envelope and the plain-text fallback, reviewer-disagreement reconciliation, deduplication, failed-post history, and retry behavior without accessing GitHub or an AI provider.

## Roadmap

Planned improvements, not yet implemented, roughly in priority order:

- **Verification pass on every gating review.** A second read-only pass currently reconciles the verdict only when the two reviewers disagree. Extend it to run whenever a review would request changes — including single-reviewer setups — so one reviewer's mistaken blocker is caught before it is posted.
- **Path-scoped `REVIEW.md` rules.** Let rules attach to file globs (for example `Sources/Billing/**`) so a rule applies only when the pull request changes a matching file, instead of every rule applying to every review. Flat `REVIEW.md` files keep working as global rules.
- **Incremental review of new commits.** When a pull request receives a new commit, review only what changed since the previous review rather than re-reviewing the whole diff, to avoid repeating findings on unchanged code.
- **Deterministic linters as grounding.** Optionally run the repository's own read-only linters on the changed files and provide their output to the reviewers as evidence, without building the project.
- **Per-repository learnings.** When an author explains that a finding was wrong, remember that locally and apply it to later reviews of the same repository.
- **Severity labels on findings.** Tag each finding by severity in the posted review so it is easy to triage at a glance.
