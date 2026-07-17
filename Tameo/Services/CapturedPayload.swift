import Foundation

/// 監視（@MainActor）→ 永続化／detached サムネ生成 へアクター境界を越える唯一の値型。
/// NSImage / CGImage は **絶対に含めない**（値型のみ＝Sendable-clean）。
struct CapturedPayload: Sendable {
    let kind: ClipKind
    /// 表示＋検索＋貼付ラベルの正準文字列
    /// （text=本文 / filename=改行連結パス / url=URL / color=#hex / image=「Image · WxH · PNG」）。
    let content: String
    let payloadUTI: String
    /// 重複排除ハッシュの入力バイト（text系=content の UTF-8 / binary=payloadData、無ければ thumbnailPNG）。
    let canonicalBytes: Data
    /// 原本バイナリ（画像/rtf/rtfd/pdf）。filename/url/color/text は nil。
    let payloadData: Data?
    /// 一覧表示用の小さな PNG（画像縮小 or filename のファイルアイコン）。
    let thumbnailPNG: Data?
    let pixelWidth: Int
    let pixelHeight: Int
    /// filename の改行連結絶対パス（非ファイルは空）。
    let fileURLStrings: String
    let colorHex: String
    let payloadTruncated: Bool
    let sourceBundleID: String?
    let isConcealed: Bool
    let byteSize: Int
    /// クリップボードの変化を**検知した**時刻（＝コピー時刻の最良近似）。
    ///
    /// 画像は `Task.detached` でサムネ生成してから着地するため、挿入時刻（`.now`）で並べると
    /// 「画像A→直後にテキストB」の順にコピーしたのに A が B より新しい行になる。
    /// 並び順の基準を「挿入した時刻」ではなく「コピーを検知した時刻」に移すことで、
    /// 非同期経路が遅れても順序が壊れない（かつ遅れた項目を捨てずに済む）。
    let capturedAt: Date

    init(
        kind: ClipKind,
        content: String,
        payloadUTI: String,
        canonicalBytes: Data,
        payloadData: Data? = nil,
        thumbnailPNG: Data? = nil,
        pixelWidth: Int = 0,
        pixelHeight: Int = 0,
        fileURLStrings: String = "",
        colorHex: String = "",
        payloadTruncated: Bool = false,
        sourceBundleID: String? = nil,
        isConcealed: Bool = false,
        byteSize: Int? = nil,
        capturedAt: Date = .now
    ) {
        self.kind = kind
        self.content = content
        self.payloadUTI = payloadUTI
        self.canonicalBytes = canonicalBytes
        self.payloadData = payloadData
        self.thumbnailPNG = thumbnailPNG
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.fileURLStrings = fileURLStrings
        self.colorHex = colorHex
        self.payloadTruncated = payloadTruncated
        self.sourceBundleID = sourceBundleID
        self.isConcealed = isConcealed
        self.byteSize = byteSize ?? (payloadData?.count ?? content.utf8.count)
        self.capturedAt = capturedAt
    }

    /// テキスト項目（既存テキスト経路）。
    static func text(_ s: String, source: String?, capturedAt: Date = .now) -> CapturedPayload {
        CapturedPayload(
            kind: .text,
            content: s,
            payloadUTI: ClipKind.text.preferredUTI,
            canonicalBytes: Data(s.utf8),
            sourceBundleID: source,
            byteSize: s.utf8.count,
            capturedAt: capturedAt
        )
    }

    /// 色コード文字列（テキスト由来＝NSColor 型でなく `#hex`/`rgb()` をコピーした場合）。
    /// content は元の文字列（貼付・検索はこれ）、colorHex は正規化した #hex（チップ表示・色対応貼付用）。
    static func color(code: String, hex: String, source: String?, capturedAt: Date = .now) -> CapturedPayload {
        CapturedPayload(
            kind: .color,
            content: code,
            payloadUTI: ClipKind.color.preferredUTI,
            canonicalBytes: Data(code.utf8),
            colorHex: hex,
            sourceBundleID: source,
            byteSize: code.utf8.count,
            capturedAt: capturedAt
        )
    }

    /// detached でサムネを得た後にコピーを返す（PR-B 画像用。PR-A は未使用だが契約として用意）。
    func withThumbnail(_ thumb: Data?) -> CapturedPayload {
        CapturedPayload(
            kind: kind,
            content: content,
            payloadUTI: payloadUTI,
            canonicalBytes: canonicalBytes,
            payloadData: payloadData,
            thumbnailPNG: thumb ?? thumbnailPNG,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            fileURLStrings: fileURLStrings,
            colorHex: colorHex,
            payloadTruncated: payloadTruncated,
            sourceBundleID: sourceBundleID,
            isConcealed: isConcealed,
            byteSize: byteSize,
            capturedAt: capturedAt
        )
    }
}
