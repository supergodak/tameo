import Foundation

/// 貼付変換（パレットの ⌃番号 / ⌃⏎）。設定で有効な変換を固定順で適用する。
///
/// 適用順は URLクリーン → 全角→半角 → 空白整理。URL判定を先にやるのは、
/// 半角化や空白整理が先に走ると「テキスト全体が単一URLか」の判定が変わりうるため。
/// すべて純関数で、履歴のデータは変更しない（貼る瞬間のコピーにだけ適用）。
enum PasteTransformer {

    /// 設定で有効な変換を順に適用する。
    @MainActor
    static func apply(_ text: String, settings: SettingsStore) -> String {
        var out = text
        if settings.transformCleanURL { out = cleanURL(out) }
        if settings.transformHalfWidth { out = toHalfWidth(out) }
        if settings.transformTidyWhitespace { out = tidyWhitespace(out) }
        return out
    }

    // MARK: - URLクリーン

    /// 既知のトラッキングパラメータ（完全一致）。宣伝・計測専用で、削っても遷移先が変わらないものだけ。
    private static let trackingParams: Set<String> = [
        "fbclid", "gclid", "dclid", "gbraid", "wbraid", "msclkid", "yclid", "twclid",
        "mc_cid", "mc_eid", "igshid", "igsh", "_hsenc", "_hsmi", "mkt_tok",
        "vero_id", "oly_anon_id", "oly_enc_id", "cvid", "srsltid",
    ]

    /// テキスト全体（前後空白を除く）が単一の http/https URL のときだけ、トラッキング
    /// パラメータ（utm_* と既知リスト）を除去して返す。それ以外は原文のまま。
    /// 機能に関わりうる未知のパラメータは残す（削りすぎてリンクを壊さない）。
    static func cleanURL(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains(where: { $0.isWhitespace }),
              var comps = URLComponents(string: trimmed),
              let scheme = comps.scheme?.lowercased(), scheme == "http" || scheme == "https",
              comps.host?.isEmpty == false,
              let items = comps.queryItems, !items.isEmpty else { return text }

        let kept = items.filter { item in
            let name = item.name.lowercased()
            return !name.hasPrefix("utm_") && !trackingParams.contains(name)
        }
        guard kept.count != items.count else { return text }   // 変化なしなら原文（?の再構成もしない）
        comps.queryItems = kept.isEmpty ? nil : kept
        return comps.url?.absoluteString ?? text
    }

    // MARK: - 全角→半角

    /// 全角英数・記号（U+FF01〜U+FF5E）と全角空白（U+3000）を半角へ。
    /// NFKC は使わない：NFKC は半角カナ→全角カナ等も巻き込み「英数だけ半角に」の意図を超えるため、
    /// 対象範囲を明示した単純写像にする。かな・漢字・半角カナには触れない。
    static func toHalfWidth(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.map { scalar in
            switch scalar.value {
            case 0xFF01...0xFF5E: return Unicode.Scalar(scalar.value - 0xFEE0)!
            case 0x3000: return " "
            default: return scalar
            }
        }))
    }

    // MARK: - 空白整理

    /// 前後トリム＋改行を空白に＋連続空白の圧縮。PDFからのコピペで行が細切れになる問題の定番解。
    static func tidyWhitespace(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}
