# Contributing to Tameo

Thanks for your interest! Tameo is a native macOS clipboard manager (SwiftUI + SwiftData), MIT-licensed, © ATI Inc.

## Project layout

- `Tameo/` — app source (Models / Services / Views)
- `project.yml` — [XcodeGen](https://github.com/yonaskolb/XcodeGen) spec (the `.xcodeproj` is generated, not committed)
- `scripts/build-app.sh` — Release build → `/Applications/Tameo.app`
- `docs/` — design notes and the Clipy feature reference (clean-room spec; no Clipy code is used)

## Build & run

```sh
brew install xcodegen          # once
xcodegen generate              # regenerate Tameo.xcodeproj after adding/removing files
open Tameo.xcodeproj            # build & run in Xcode
# or, for a Release build installed to /Applications:
./scripts/build-app.sh
```

- Requires a full Xcode install (Command Line Tools alone are not enough), macOS 14+.
- Set your signing team in `project.yml` (`DEVELOPMENT_TEAM`).
- Grant **Accessibility** permission (System Settings ▸ Privacy & Security ▸ Accessibility) so paste works.
- **Always run `xcodegen generate` after adding/removing/renaming source files** — the project is generated from `project.yml`.

## Guidelines

- Match the surrounding code style. Keep the privacy model intact: background code must **only** inspect pasteboard *types*, never read contents (content reads happen only on user selection).
- Keep all data on-device — no network calls in core features, no analytics/telemetry.
- For UI, prefer native SwiftUI controls and follow Apple HIG.
- Add a short rationale in PR descriptions; reference any issue.

## Versioning

- `MARKETING_VERSION` in `project.yml` is the human version (bump for meaningful changes).
- The build number is the git commit count (set automatically by `scripts/build-app.sh`).

## License of contributions

By contributing, you agree your contributions are licensed under the project's [MIT License](LICENSE).
