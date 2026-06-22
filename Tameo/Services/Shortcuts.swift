import Foundation

// M2 で sindresorhus/KeyboardShortcuts を project.yml に追加し、以下の形で実装する。
// （M1では依存を入れないため、配線形をコメントで残すだけにしてビルドを通す。）
//
//   import KeyboardShortcuts
//
//   extension KeyboardShortcuts.Name {
//       static let showMain     = Self("showMain",     initial: .init(.v, modifiers: [.command, .shift]))   // ⌘⇧V
//       static let showHistory  = Self("showHistory",  initial: .init(.v, modifiers: [.command, .control])) // ⌘⌃V
//       static let showSnippet  = Self("showSnippet",  initial: .init(.b, modifiers: [.command, .shift]))    // ⌘⇧B
//       static let clearHistory = Self("clearHistory")
//   }
//
// 注: KeyboardShortcuts 3.x は引数名が `default:` ではなく `initial:`。固定バージョンは 3.0.1（3.0.0 は実機クラッシュ）。

/// M1のプレースホルダ。実体はM2で追加する。
enum Shortcuts {}
