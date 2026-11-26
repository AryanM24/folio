# Contributing to Folio

Thanks for helping. Folio is a small, focused codebase, and the aim is to keep it a pleasure to read. This page covers everything you need to send a good pull request.

## Set up

You need macOS 15 or later and a Swift 6.2 toolchain: Xcode 26, or just the Command Line Tools (`xcode-select --install`).

```sh
git clone https://github.com/AryanM24/folio
cd folio
make run      # builds build/Folio.app (debug) and opens it
make test     # runs every test suite
```

Prefer Xcode? Open `Package.swift`, pick the `Folio` scheme and run. Document types and Quick Actions come from `Resources/Info.plist`, which only takes effect in the bundled app, so use `make run` when you work on those.

## Find your way around

Read [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) first. It explains the module layout and the one rule that keeps saving reliable: every change goes through the undo manager. [docs/DESIGN.md](docs/DESIGN.md) covers the visual language. Each editor has its own page in [docs/editors/](docs/editors).

| I want to… | Look in |
| --- | --- |
| Fix something in one editor | `Sources/Folio<Editor>/` and its tests |
| Add a file tool or Quick Action | `<Editor>Tools.swift` in the owning module, then an `NSServices` entry in `Resources/Info.plist` |
| Change colors, buttons or other shared UI | `Sources/FolioKit/Design/` |
| Change menus, the Welcome window or Settings | `Sources/Folio/` |

## Making a change

- **Keep pull requests small and focused.** One fix or feature per PR.
- **Test logic, check UI.** Pure code (parsers, formula engine, geometry, codecs) gets Swift Testing tests. For UI, run `scripts/snapshot.sh <file>` and `SCHEME=dark scripts/snapshot.sh <file>`, and attach the screenshots to the PR.
- **Never lose data.** Any new edit operation must register undo, which is what triggers autosave. Tools must never overwrite their inputs.
- **Stay fast.** Don't add work to app launch or document open. If you touch either, run `make launch-time`; launch and quit must stay under one second.
- **Write for the next reader.** Every type and every non-obvious function gets a `///` comment explaining why it exists, not just what it does. Use `Log.make("<Module>")` instead of `print`. Explain errors in plain language through `Alert` or `FolioError`.
- **Formatting.** `swift format --in-place --recursive Sources Tests` uses the repo's `.swift-format`. CI runs the lint.
- **Dependencies.** Ask in an issue first. Folio has one (ZIPFoundation, for spreadsheet files) and wants to keep it that way.

## Commit messages

Write a short imperative subject ("Add page numbers tool"), a blank line, then a body explaining why. Reference issues with `Fixes #123`.

## Code of conduct

By taking part you agree to the [code of conduct](CODE_OF_CONDUCT.md).
