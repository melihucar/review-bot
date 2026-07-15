# Contributing to Review Bot

Thanks for your interest in improving Review Bot — a native macOS menu-bar app
built with SwiftUI and the Swift Package Manager.

## Requirements

- macOS 14 or newer
- Xcode 16 or newer (or a compatible Swift 6 toolchain)
- The CLIs the app drives, if you want to test end to end: `gh`, `claude`, `codex`

## Build, run, and test

```bash
make build     # debug build
make run       # run the app from the command line
make app       # package dist/Review Bot.app
make test      # run the full test suite
```

Run a single test suite or case with a filter:

```bash
swift test --filter VerdictTests
```

## Project layout

- `Sources/ReviewBot/` — app entry point, model, review engine, storage, views
- `Tests/ReviewBotTests/` — unit and mocked feature tests
- `scripts/build-app.sh` — packages the `.app` bundle
- `CLAUDE.md` — architecture overview and how the pieces fit together

## Pull requests

- Keep each PR focused on one logical change.
- Add or update tests for behavior changes. Remote parsing, verdict parsing,
  decision precedence, settings migration, and the mocked review workflow are
  all covered — please keep `make test` green.
- Match the existing code style; no separate formatter is enforced.
- Explain the motivation ("why") in the PR description.

## Reporting issues

Open a GitHub issue with steps to reproduce, your macOS version, and relevant
lines from the logs (in the app: **History → Show data folder → `logs/`**).
Please redact anything private before pasting logs or screenshots.
