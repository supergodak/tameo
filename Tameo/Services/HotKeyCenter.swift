import Foundation
import KeyboardShortcuts

/// グローバルホットキーの登録口。アプリ起動時に**一度だけ**生成して登録する
/// （SwiftUI の view body 内では登録しないこと＝ハンドラが多重登録される）。
@MainActor
final class HotKeyCenter {
    private static let didSeedKey = "didSeedShowHistoryShortcut"

    /// - Parameter onShowHistory: ホットキー押下時に呼ぶアクション（履歴パレットの開閉）。
    init(onShowHistory: @escaping @MainActor () -> Void) {
        // 既定 ⌘⇧V を初回のみ seed（ユーザーが後で空に再割当しても維持されるよう initial: は使わない）。
        if !UserDefaults.standard.bool(forKey: Self.didSeedKey) {
            KeyboardShortcuts.setShortcut(.init(.v, modifiers: [.command, .shift]), for: .showHistory)
            UserDefaults.standard.set(true, forKey: Self.didSeedKey)
        }
        // onKeyUp ではなく onKeyDown（押した瞬間に開く）。
        KeyboardShortcuts.onKeyDown(for: .showHistory) {
            onShowHistory()
        }
    }
}
