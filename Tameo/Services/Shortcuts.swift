import KeyboardShortcuts

/// グローバルホットキーの名前空間。
/// 名前(rawValue)にドットを含めないこと（実行時アサーション）。
/// 既定キーは `initial:` で固定せず、初回起動時に一度だけ seed する（ユーザーが空に再割当しても維持されるように）。
extension KeyboardShortcuts.Name {
    /// 履歴パレットを開く（既定 ⌘⇧V、M6 の設定で再割当可）。
    static let showHistory = Self("showHistory")
    /// スニペット一覧を直接開く（既定 ⌘⇧B、Clipy 互換。設定で再割当可）。
    static let showSnippets = Self("showSnippets")
}
