import AppKit

/// 色とヘックス文字列の相互変換。捕捉（NSColor→#hex）と貼戻し・表示（#hex→NSColor）で共有。
extension NSColor {
    /// "#RRGGBB" / "#RRGGBBAA" / "RRGGBB" をパース。失敗時 nil。
    convenience init?(hexString: String) {
        var s = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6 || s.count == 8, let v = UInt64(s, radix: 16) else { return nil }
        let r, g, b, a: CGFloat
        if s.count == 8 {
            r = CGFloat((v >> 24) & 0xff) / 255
            g = CGFloat((v >> 16) & 0xff) / 255
            b = CGFloat((v >> 8) & 0xff) / 255
            a = CGFloat(v & 0xff) / 255
        } else {
            r = CGFloat((v >> 16) & 0xff) / 255
            g = CGFloat((v >> 8) & 0xff) / 255
            b = CGFloat(v & 0xff) / 255
            a = 1
        }
        self.init(srgbRed: r, green: g, blue: b, alpha: a)
    }

    /// sRGB の "#RRGGBB"（アルファは捨てる。表示・検索用の安定表現）。
    var tameoHexString: String {
        let c = usingColorSpace(.sRGB) ?? self
        let r = Int(round(c.redComponent * 255))
        let g = Int(round(c.greenComponent * 255))
        let b = Int(round(c.blueComponent * 255))
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}
