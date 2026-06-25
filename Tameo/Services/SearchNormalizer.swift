import Foundation

/// 履歴検索の正規化器。
///
/// 保存時に項目の「検索インデックス文字列」を一度だけ作ってキャッシュし、検索時はクエリを
/// **同じ規則**で正規化して部分一致する。毎キーストロークごとの再計算を避けるための前処理
/// （= 2回以上参照する値は事前計算する、というプロジェクト方針に沿う）。
///
/// 正規化規則（順序が意味を持つ）:
/// 1. NFKC 互換正規化 … 全角ＡＢＣ１２３→ABC123、半角ｶﾅ→カナ を統一
/// 2. カタカナ→ひらがな畳み込み … カナ/かな の表記ゆれを吸収
/// 3. 小文字化 … ASCII / ラテンの大小無視
/// 4. 連続空白の圧縮＋トリム … 改行連結パスなども1行の検索対象にする
enum SearchNormalizer {

    /// 入力長の上限（巨大なRTF/PDF本文で索引が膨らむのを防ぐ。検索は先頭で十分）。
    static let maxSourceLength = 8192

    /// クエリ・本文を検索用に正規化する。
    static func normalize(_ s: String) -> String {
        // 1. NFKC（全角半角・互換の統一）
        let nfkc = s.precomposedStringWithCompatibilityMapping
        // 2. カタカナ→ひらがな（reverse: true が katakana→hiragana）。失敗時は前段にフォールバック
        let kana = nfkc.applyingTransform(.hiraganaToKatakana, reverse: true) ?? nfkc
        // 3. 小文字化
        let lower = kana.lowercased()
        // 4. 連続空白を1つに畳んでトリム
        return lower.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// 保存項目の検索インデックス文字列。
    /// 本文に加えて色hex・ファイルパスも対象に含め、`#2D7DD2` や `/Users/...` でも引けるようにする。
    static func indexString(content: String, colorHex: String = "", fileURLStrings: String = "") -> String {
        var parts = [content]
        if !colorHex.isEmpty { parts.append(colorHex) }
        if !fileURLStrings.isEmpty { parts.append(fileURLStrings) }
        let joined = parts.joined(separator: " ")
        let capped = joined.count > maxSourceLength ? String(joined.prefix(maxSourceLength)) : joined
        return normalize(capped)
    }
}
