import SwiftUI
import KeyboardShortcuts

/// ショートカット設定タブ。グローバルホットキーの録画UI（`KeyboardShortcuts.Recorder`）。
/// ホットキーの永続化は KeyboardShortcuts が独自に行う（SettingsStore では管理しない）。
struct ShortcutsSettingsTab: View {
    var body: some View {
        Form {
            Section {
                KeyboardShortcuts.Recorder("Show history", name: .showHistory)
                KeyboardShortcuts.Recorder("Show snippets", name: .showSnippets)
            } header: {
                Text("Global hotkeys")
            } footer: {
                Text("Click a shortcut and press a new key combination to rebind it, or clear it to disable. Defaults: ⌘⇧V opens history, ⌘⇧B opens snippets.")
            }
        }
        .formStyle(.grouped)
    }
}
