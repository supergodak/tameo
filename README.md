# Tameo

A modern, native clipboard manager for macOS — menu-bar resident, privacy-first, and built from scratch for Apple Silicon.

**Tameo（ためお）** は macOS 用のクリップボードマネージャです。語源は「溜める」。コピーした履歴を端末内に溜めて、必要なときに前面アプリへ直接ペーストします。

> Status: **Phase 0 — early development.** Project scaffolding only; not yet usable.

---

## Why Tameo?

[Clipy](https://github.com/Clipy/Clipy) is an excellent clipboard manager, but it ships as an Intel-only binary that runs through Rosetta 2 — which Apple is winding down. Tameo is a clean-room successor: **inspired by Clipy's behavior and feature set, but written from zero with no code reuse**, on a modern stack.

## Features (planned)

- Text clipboard history, resident in the menu bar (no Dock icon)
- Global hotkey to open history and paste the selected item into the frontmost app
- Privacy-aware clipboard monitoring (checks *what kind* of data is on the pasteboard without reading its contents until you pick an item)
- Excludes password-manager / concealed (`org.nspasteboard.ConcealedType`) entries
- Later: images, RTF, file paths, color codes, snippets, search, per-app exclusions

## Requirements

- macOS 14 (Sonoma) or later — required by SwiftData
- Apple Silicon or Intel Mac

## Tech stack

- **UI**: SwiftUI `MenuBarExtra`
- **Persistence**: SwiftData
- **Key layout handling**: [Sauce](https://github.com/Clipy/Sauce) (MIT) — handles per-layout key codes (QWERTY / Dvorak / JIS …)
- **Auto-update**: [Sparkle](https://github.com/sparkle-project/Sparkle) (planned, Phase 3)

## Building

This repository keeps the Xcode project as a declarative [XcodeGen](https://github.com/yonaskolb/XcodeGen) spec (`project.yml`) rather than a checked-in `.xcodeproj`.

```sh
brew install xcodegen   # once
xcodegen generate       # produces Tameo.xcodeproj
open Tameo.xcodeproj
```

Requires a full Xcode install (Command Line Tools alone are not enough). Set your signing team via `DEVELOPMENT_TEAM` in `project.yml`.

## Privacy

Tameo keeps all clipboard data **on your device only**. Nothing is sent off the machine. A full privacy policy will accompany the first public release.

## License

[MIT](LICENSE) © 2026 ATI Inc. (ATI株式会社)

Third-party components retain their own licenses — see [THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md).

Tameo is inspired by [Clipy](https://github.com/Clipy/Clipy) (MIT). No Clipy source code is used.
