#if DEBUG
import AppKit
import SwiftData

/// スクリーンショット撮影用の隠しデモモード（DEBUG ビルド専用）。
///
/// `--demo-shot=<history|search|ocr|snippets>` を付けて起動すると、
/// - ストアと設定を使い捨て領域へ隔離（実データ・実設定に触れない。TameoApp 側で処理）、
/// - 監視・ホットキー・自動更新・一度きり移行をすべて止め、
/// - 無害なデモ履歴／スニペットを投入し、指定の画面でパレットを開く。
///
/// 実データは別ストアなので写り込まない。撮影後は呼び出し側スクリプトがデモストアを捨てるだけ。
enum DemoSeed {

    enum Shot: String { case history, search, ocr, snippets }

    /// 起動引数から撮影対象を取り出す（無ければ nil＝通常起動）。
    static var requestedShot: Shot? {
        for arg in CommandLine.arguments {
            if arg.hasPrefix("--demo-shot=") {
                return Shot(rawValue: String(arg.dropFirst("--demo-shot=".count)))
            }
        }
        return nil
    }

    /// デモ用の履歴・スニペットを投入する。順序が「新しい順」で映えるよう、古いものから入れる。
    @MainActor
    static func populate(store: HistoryStore, snippets: SnippetStore) {
        // 履歴（capturedAt を少しずつ進めて自然な並びに）。無害で用途が伝わる内容を選ぶ。
        let base = Date(timeIntervalSinceReferenceDate: 800_000_000)   // 固定値（再現性・Date.now非依存）
        var t = base
        func tick() -> Date { t = t.addingTimeInterval(37); return t }

        // 画像（OCR デモ）: 請求書風の画像を1枚。実 OCR（Vision）が画像内の日本語を認識するので、
        // 「画像の中の文字まで検索できる」を本物で見せられる（固定テキストは付けない）。
        if let png = renderInvoiceImage() {
            let thumb = ImageThumbnailer.thumbnailPNG(from: png, maxPixel: 256) ?? png
            store.ingest(CapturedPayload(
                kind: .png, content: "Image · 1000×640 · PNG", payloadUTI: ClipKind.png.preferredUTI,
                canonicalBytes: png, payloadData: png, thumbnailPNG: thumb,
                pixelWidth: 1000, pixelHeight: 640,
                sourceBundleID: "com.apple.screencaptureui", capturedAt: tick()))
        }

        // 色（チップ表示のデモ）は専用 factory で。
        store.ingest(CapturedPayload.color(code: "#2D7DD2", hex: "#2D7DD2", source: nil, capturedAt: tick()))

        let texts: [(String, Date)] = [
            ("https://github.com/supergodak/tameo", tick()),
            ("func makeContainer(at storeURL: URL) throws -> ModelContainer {\n    let config = ModelConfiguration(url: storeURL)\n}", tick()),
            ("ATI株式会社 2026年度 上半期 実績報告", tick()),
            ("領収書は経理へ 7/31 までに提出してください", tick()),
            ("2026年上半期 売上サマリー：前年比 +18.4%（国内 +12%／海外 +31%）", tick()),
            ("The quick brown fox jumps over the lazy dog", tick()),
            ("〒150-0002 東京都渋谷区渋谷2-1-1", tick()),
            ("お世話になっております。ATI株式会社の竹屋です。", tick()),
        ]
        for (s, when) in texts { store.ingest(CapturedPayload.text(s, source: nil, capturedAt: when)) }

        // スニペット（無害な定型文）。撮影で映える2フォルダ。
        let greetings = snippets.addFolder(title: "あいさつ")
        _ = snippets.addSnippet(to: greetings, title: "お礼", content: "先日はお時間をいただき、誠にありがとうございました。")
        _ = snippets.addSnippet(to: greetings, title: "打ち合わせ日程", content: "下記日程でご都合いかがでしょうか。\n・7/28(火) 14:00-\n・7/30(木) 10:00-")
        _ = snippets.addSnippet(to: greetings, title: "署名", content: "ATI株式会社\n竹屋\ncontact@ati-mirai.co.jp")
        let dev = snippets.addFolder(title: "開発")
        _ = snippets.addSnippet(to: dev, title: "MITヘッダ", content: "// SPDX-License-Identifier: MIT\n// Copyright (c) 2026 ATI Inc.")
        _ = snippets.addSnippet(to: dev, title: "PR文面", content: "## 概要\n\n## 変更点\n\n## テスト\n")
    }

    /// 請求書風のデモ画像（OCR 行に見せる用）。実 OCR は走らせず、見た目だけ。
    static func renderInvoiceImage() -> Data? {
        let size = NSSize(width: 1000, height: 640)
        let img = NSImage(size: size)
        img.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        let title = "御見積書" as NSString
        title.draw(at: NSPoint(x: 40, y: 560),
                   withAttributes: [.font: NSFont.boldSystemFont(ofSize: 34), .foregroundColor: NSColor.black])
        let rows = ["品名                     数量    金額",
                    "サーバ構築                 2    ¥170,000",
                    "保守サポート（年間）        12    ¥360,000",
                    "クリップボード管理ツール開発   1    ¥450,000",
                    "                    合計    ¥980,000"]
        for (i, line) in rows.enumerated() {
            (line as NSString).draw(at: NSPoint(x: 40, y: CGFloat(460 - i * 60)),
                                    withAttributes: [.font: NSFont.systemFont(ofSize: 24),
                                                     .foregroundColor: NSColor.black])
        }
        img.unlockFocus()
        guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}
#endif
