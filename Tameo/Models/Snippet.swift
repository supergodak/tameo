import Foundation
import SwiftData

/// スニペット（定型文）のフォルダ。`SnippetFolder 1—* Snippet`。
/// 追加フィールドは**すべて既定値付き**＝既存ストアの SwiftData lightweight migration を壊さない
/// （`ClipboardItem` と同方針）。新規エンティティの追加のみで既存履歴は無傷。
@Model
final class SnippetFolder {
    /// フォルダ名。
    var title: String = ""
    /// フォルダの並び順（密連番。小さいほど上）。
    var order: Int = 0
    /// フォルダごと無効化（Clipy の有効フラグ相当）。無効なら呼び出し一覧に出さない。
    var enabled: Bool = true
    /// 作成日時。
    var createdAt: Date = Date.now
    /// 配下のスニペット。フォルダ削除で cascade 削除（externalStorage を持たないので sidecar 孤児問題は無い）。
    @Relationship(deleteRule: .cascade, inverse: \Snippet.folder)
    var snippets: [Snippet] = []

    init(title: String = "", order: Int = 0, enabled: Bool = true, createdAt: Date = .now) {
        self.title = title
        self.order = order
        self.enabled = enabled
        self.createdAt = createdAt
    }

    /// order 昇順のスニペット。SwiftData の to-many は順序非保証ゆえ、表示・パレット生成では必ずこれを使う。
    var orderedSnippets: [Snippet] {
        snippets.sorted { $0.order < $1.order }
    }

    /// 呼び出し一覧に出す有効スニペット（order 昇順）。
    var enabledSnippets: [Snippet] {
        orderedSnippets.filter { $0.enabled }
    }
}

/// 定型文1件。本文はプレーンテキスト（Clipy §5 準拠）。
@Model
final class Snippet {
    /// 一覧表示用タイトル。
    var title: String = ""
    /// 貼り付け本文（プレーンテキスト）。
    var content: String = ""
    /// フォルダ内の並び順（密連番）。
    var order: Int = 0
    /// 個別の有効フラグ。無効なら呼び出し一覧に出さない。
    var enabled: Bool = true
    /// 作成日時。
    var createdAt: Date = Date.now
    /// 所属フォルダ（to-one 逆関係）。
    var folder: SnippetFolder?

    init(title: String = "", content: String = "", order: Int = 0, enabled: Bool = true, createdAt: Date = .now) {
        self.title = title
        self.content = content
        self.order = order
        self.enabled = enabled
        self.createdAt = createdAt
    }
}
