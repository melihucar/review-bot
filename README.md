# Review Bot

Review Bot is a native macOS menu-bar app that watches local GitHub repositories for pull requests requesting a review from the signed-in `gh` user. It reviews each new request in an isolated Git worktree with Claude, Codex, opencode, DeepSeek, or any combination, then submits an approval, change request, or neutral review to GitHub.

GitHub access always goes through your authenticated `gh` CLI — the app never handles GitHub credentials. AI access defaults to the same model: each reviewer CLI uses its own existing login. If you would rather bill a specific API key, Claude and Codex accept one and DeepSeek requires one; keys are stored in the macOS Keychain and never written to `config.json`.

## Features

- Add and independently enable multiple local Git repositories.
- Poll every 5, 15, or 30 minutes, or every hour.
- Pause and resume automatic monitoring from the menu bar or settings.
- See explicit Pending and Running review queues in the menu-bar popover.
- Run an immediate manual check even while monitoring is paused.
- Independently enable Claude, Codex, opencode, and DeepSeek and configure each model and effort level.
- Choose per reviewer whether to use its signed-in CLI or an API key held in the macOS Keychain (Claude and Codex; DeepSeek is key-only, and opencode authenticates through its own configuration).
- Track tokens and cost per review for the reviewers billed per token — including DeepSeek, priced from editable per-million rates — and optionally publish that in the review.
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
- At least one reviewer:
  - `claude` — authenticated, or an Anthropic API key.
  - `codex` — authenticated, or an OpenAI API key.
  - `opencode` — authenticated through its own configuration. Opt-in; defaults to the free `opencode/deepseek-v4-flash-free` model at max effort.
  - DeepSeek — a DeepSeek API key. No CLI to install; it is called over HTTPS.
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
4. Enable the reviewers you want and set their model and effort values. opencode and DeepSeek are off by default.
5. For each reviewer, choose **Signed-in CLI** or **API key**. DeepSeek is key-only; paste its key and select **Save**. opencode uses its own configuration and has no key field.
6. Choose a polling interval.
7. Optionally add global custom review instructions.
8. Select **Run now** to verify the setup.

CLI availability is shown on the Reviewers tab. Review Bot asks your login shell for its `PATH` at startup — so CLIs installed through a version manager (nvm, mise, volta, fnm, asdf) are found even when the app is launched from Finder or at login — and also searches common Homebrew, local-user, and npm binary directories in addition to the process `PATH`.

## Reviewers and credentials

Claude, Codex, and opencode are agents: Review Bot hands each one the prompt and the worktree, and the CLI explores the code itself under its own read-only sandbox.

DeepSeek has no CLI, so it is called directly over its chat-completions API and Review Bot runs the agent loop on its behalf. The model is offered three read-only tools — `read_file`, `search`, and `list_files` — every call is resolved against the review worktree and refused if it points anywhere else, and the results are fed back until the model produces its review. The diff and PR discussion are also included in the first message, so a model that will not accept tools (DeepSeek's reasoning models reject them) still produces a complete single-shot review. Nothing in this path writes, executes, or reaches anywhere except DeepSeek's API.

Each reviewer independently chooses where its credentials come from:

| Mode | Behavior |
| --- | --- |
| **Signed-in CLI** (default for `claude` and `codex`, and the only mode for `opencode`) | Review Bot passes no credentials; the CLI uses its own login. Any `ANTHROPIC_API_KEY`/`OPENAI_API_KEY` inherited from your shell is explicitly unset, so the CLI cannot silently bill a different account. opencode is handed `OPENCODE_CONFIG_DIR`/`OPENCODE_CONFIG_CONTENT` rather than a key, so it offers no credential picker at all. |
| **API key** (required for DeepSeek) | The key you saved is passed to that reviewer only — as `ANTHROPIC_API_KEY` or `OPENAI_API_KEY` for a CLI reviewer, or as the bearer token for DeepSeek. |

Keys are stored in your login Keychain under "Review Bot reviewer API keys" and are never written to `config.json`, the activity history, the daily logs, or a posted review. A reviewer set to API-key mode with no saved key fails with a message saying so, rather than quietly running under some other account. That failure is terminal — it will fail the same way however often it is called — so the reviewer is not run again inside that review; only a settings change fixes it.

Because the app is ad-hoc signed by default, macOS asks for your login password to read a saved key after a rebuild, and "Always Allow" does not stick — it authorizes the one build in front of it. Each Keychain item records the identity of the app that saved it, and with no signing identity that record is a hash of the binary, so every rebuild looks like a different application. Only a Developer ID fixes it (`CODE_SIGN_IDENTITY="Developer ID Application: …" make app`), because the item can then record your team identity, which rebuilds keep. A self-signed certificate is not enough — it was tested; the item still falls back to recording the binary hash.

For development, a reviewer already set to **API key** can take its key from Review Bot's own environment instead of the Keychain: `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, and `DEEPSEEK_API_KEY` are read when set, taking precedence over a saved key — useful for `make run` or a one-off script without saving anything, and it skips the Keychain prompt entirely. It changes nothing about the default **Signed-in CLI** mode, which still unsets those variables, so exporting a key without also switching that reviewer to API key leaves it on its own login; DeepSeek has no such mode, so its variable is read whenever it is enabled. This only helps when the app is started from a shell: launched from Finder or at login it inherits launchd's environment, so the packaged app reads the Keychain.

### Token usage and cost

Reviews are metered for the reviewers you pay per token. Every provider call a reviewer makes is counted — each round of DeepSeek's agent loop, the extra attempt when a reviewer is re-run inside the same review, and the reconciliation pass, which is a full extra call charged to whichever reviewer adjudicated — and the total is written to the activity history, so you can see what a particular pull request cost and total spend from `history.json`. **Reviewers → Usage and cost** controls whether the same figures are appended to the posted GitHub review; tracking happens either way.

| Reviewer | Tokens | Cost |
| --- | --- | --- |
| Claude | Reported by the CLI | Reported by the CLI — no prices to configure |
| DeepSeek | Reported by the API | Computed from prices you set on its card |
| Codex | Not reported | Not available |
| opencode | Not reported | Not available |

Claude's figures come from `claude --output-format json`, which Review Bot now passes on every run. Output that is not that envelope is read as the review itself, so a CLI that accepts the flag and prints plain text still reviews normally — but the flag is not optional and there is no fallback re-run, so a `claude` too old to accept it fails outright with the CLI's own error. DeepSeek's come from each response's `usage` object, which reports tokens and no price.

**DeepSeek prices.** Because its API sends no price, DeepSeek's cost is its token counts multiplied by rates you keep on its reviewer card — input, cached input, and output, in USD per million tokens. They are settings rather than built-in constants because published prices drift, and a stale number would report the wrong spend without ever saying so; check them against DeepSeek's current pricing, and use **Reset** to restore the shipped defaults. A cached input token is charged at its own rate, matching how the provider bills and reports it. Set all three to zero to report tokens and no cost at all. Rates are written with a dot or a comma — a comma-decimal locale would otherwise read a pasted `0.27` as `27` — and a negative rate is refused. A `config.json` written before prices existed is given the defaults when it loads. Because these numbers come from your settings rather than from the provider, the posted usage table says so.

A reviewer using its signed-in CLI is left out entirely: that cost is a flat subscription, so attributing dollars to one review would be misleading. That excludes opencode in every configuration, since it has no API-key mode. A cost that cannot be determined is shown as unknown rather than as `$0.00`, which would understate real spend — including a DeepSeek review whose responses carried no token counts, since a rate multiplied by unknown tokens is unknown and not zero.

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

When reviewers disagree across the gate — at least one wants changes while another approves — Review Bot runs one more read-only reconciliation pass that re-checks each blocking finding against the actual diff and its scope, then uses that adjudicated verdict instead of blindly taking the strictest. The adjudicator is the first enabled reviewer in the order Claude, Codex, opencode; DeepSeek is never asked to adjudicate, because it is the one reviewer that always bills a key and the last word should not cost an extra metered pass. This keeps one reviewer's mistaken blocker from stopping a correct pull request. The reconciliation and its verdict are shown in the posted review.

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
├── opencode/
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

Use **History → Show data folder** to open this location.

## Privacy and safety

- Source code inspected by Claude, Codex, or opencode is handled according to the account and provider configuration of those CLIs. Code sent to DeepSeek — the diff, the PR discussion, and any file its tools read — leaves your machine over HTTPS to DeepSeek's API, so enable it only where that is acceptable.
- API keys are held in the macOS Keychain, passed only to the reviewer they belong to, and never written to configuration, history, logs, or a posted review.
- Review Bot does not start a shell for repository values, PR titles, prompts, or paths; commands are passed as argument arrays.
- Claude is restricted to read/search tools. Codex runs with its read-only sandbox. opencode runs under a read-only agent whose permissions deny everything except Read, Grep, and Glob; the pull request's own `opencode.json`/`.opencode` files cannot override that, and plugins are disabled. DeepSeek's tools are implemented in-process, only read, and refuse any path that resolves outside the review worktree.
- Review work never modifies the developer's current branch or working tree.
- No review is marked complete until GitHub accepts the submitted result.

## Tests

```bash
make test
```

The suite contains unit tests for remote parsing, settings migration, prompt composition, verdict parsing, decision precedence, gate-disagreement detection, repository inspection, credential resolution, environment composition, token-usage arithmetic and formatting, worktree-tool containment, and the DeepSeek agent loop. Mocked feature tests exercise the complete polling and review workflow, including worktree preparation, trusted `REVIEW.md` injection, Claude approval, Codex change requests, DeepSeek reviews over a stubbed API, API-key injection and session-mode key removal, usage reporting from Claude's JSON envelope and the plain-text fallback, reviewer-disagreement reconciliation, deduplication, failed-post history, and retry behavior without accessing GitHub or an AI provider.

## Roadmap

Planned improvements, not yet implemented, roughly in priority order:

- **Verification pass on every gating review.** A second read-only pass currently reconciles the verdict only when the two reviewers disagree. Extend it to run whenever a review would request changes — including single-reviewer setups — so one reviewer's mistaken blocker is caught before it is posted.
- **Path-scoped `REVIEW.md` rules.** Let rules attach to file globs (for example `Sources/Billing/**`) so a rule applies only when the pull request changes a matching file, instead of every rule applying to every review. Flat `REVIEW.md` files keep working as global rules.
- **Incremental review of new commits.** When a pull request receives a new commit, review only what changed since the previous review rather than re-reviewing the whole diff, to avoid repeating findings on unchanged code.
- **Deterministic linters as grounding.** Optionally run the repository's own read-only linters on the changed files and provide their output to the reviewers as evidence, without building the project.
- **Per-repository learnings.** When an author explains that a finding was wrong, remember that locally and apply it to later reviews of the same repository.
- **Severity labels on findings.** Tag each finding by severity in the posted review so it is easy to triage at a glance.
