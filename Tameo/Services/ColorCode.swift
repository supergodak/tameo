import Foundation

/// テキスト文字列が「色コード」かどうかを判定し、表示・貼戻し用の #RRGGBB(AA) に正規化する。
/// 取り込み時に内容が色コードなら、テキストを `.color` へ昇格させるために使う（背景の型監視は変えない）。
/// 判定は **文字列全体が** 色コードのときだけ成立する（文章中に紛れた色は拾わない）。
enum ColorCode {
    /// 全体が色コードなら正規化した "#RRGGBB" / "#RRGGBBAA"（大文字）を返す。違えば nil。
    /// 受理する形式:
    ///   - 16進: #RGB / #RGBA / #RRGGBB / #RRGGBBAA
    ///     （先頭 # は必須。# なしの素の16進は "decade"/"cafe" 等の英単語誤判定を避けるため受理しない）
    ///   - 関数: rgb(r,g,b) / rgba(r,g,b,a)（r,g,b = 0–255、a = 0–1 の小数 または 0–255 の整数）
    static func normalizedHex(from raw: String) -> String? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if let hex = hexForm(s) { return hex }
        if let hex = rgbForm(s) { return hex }
        return nil
    }

    /// #RGB / #RGBA / #RRGGBB / #RRGGBBAA。先頭 # 必須。短縮形は 2 桁へ倍化する。
    private static func hexForm(_ s: String) -> String? {
        guard s.hasPrefix("#") else { return nil }
        let body = s.dropFirst()
        guard !body.isEmpty, body.allSatisfy(\.isHexDigit) else { return nil }
        switch body.count {
        case 3, 4:
            // #RGB → #RRGGBB, #RGBA → #RRGGBBAA
            let expanded = body.map { "\($0)\($0)" }.joined()
            return "#" + expanded.uppercased()
        case 6, 8:
            return "#" + body.uppercased()
        default:
            return nil
        }
    }

    /// rgb(r,g,b) / rgba(r,g,b,a)。空白は無視。r,g,b = 0–255、a = 0–1 の小数 または 0–255 の整数。
    private static func rgbForm(_ s: String) -> String? {
        let lower = s.lowercased().replacingOccurrences(of: " ", with: "")
        let hasAlpha: Bool
        let inner: Substring
        if lower.hasPrefix("rgba(") && lower.hasSuffix(")") {
            hasAlpha = true
            inner = lower.dropFirst(5).dropLast()
        } else if lower.hasPrefix("rgb(") && lower.hasSuffix(")") {
            hasAlpha = false
            inner = lower.dropFirst(4).dropLast()
        } else {
            return nil
        }
        let parts = inner.split(separator: ",", omittingEmptySubsequences: false)
        guard parts.count == (hasAlpha ? 4 : 3) else { return nil }

        func channel(_ t: Substring) -> Int? {
            guard let v = Int(t), (0...255).contains(v) else { return nil }
            return v
        }
        guard let r = channel(parts[0]), let g = channel(parts[1]), let b = channel(parts[2]) else { return nil }

        var a = 255
        if hasAlpha {
            guard let av = Double(parts[3]) else { return nil }
            if av >= 0, av <= 1 {
                a = Int((av * 255).rounded())          // CSS 流の 0–1 小数
            } else if av > 1, av <= 255 {
                a = Int(av.rounded())                  // 0–255 の整数表記も許容
            } else {
                return nil
            }
        }
        return a >= 255
            ? String(format: "#%02X%02X%02X", r, g, b)
            : String(format: "#%02X%02X%02X%02X", r, g, b, a)
    }
}
