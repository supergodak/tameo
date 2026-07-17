import Foundation
import Vision
import AppKit
import ImageIO

/// 画像のオンデバイス文字認識（Vision）。
///
/// コピーした画像（スクショ等）や、コピーされた画像ファイルのパスから日本語/英語のテキストを取り出し、
/// 検索インデックスへ畳み込む／「テキストとして貼る」に使う。完全ローカル（外部送信なし）。
/// 専用の直列キュー上で実行しメインスレッドを塞がない。
enum OCRService {

    static let defaultLanguages = ["ja-JP", "en-US"]

    /// OCR へ渡す画像の最長辺の上限（ピクセル）。
    ///
    /// 原寸デコードは危険。画像は「ファイルは小さいが展開すると巨大」になり得るため、
    /// バイト数の上限（`ClipboardMonitor.maxOriginalBytes` = 8MB）では防げない。
    /// 例: 30000×30000 の PNG は圧縮後わずか数百KB で 8MB 上限を素通りするが、
    /// 原寸デコードすると 30000×30000×4 ≒ 3.6GB を一度に確保してしまう。
    /// 皮肉なことに 8MB を「超えた」画像は原本が破棄されサムネ(128px)へ退避するため安全で、
    /// 上限を通過する小さなファイルだけが刺さる。したがって効くのは**ピクセル数の上限**だけ。
    ///
    /// 4096 は Vision の認識精度を保ちつつ、最悪でも 4096×4096×4 ≒ 67MB に収まる値。
    static let maxPixelSize = 4096

    /// OCR を直列化する専用キュー。
    /// Vision の認識は 1 件あたり数十MB規模を使うため、`DispatchQueue.global` へ無制限に投げると
    /// 連続コピーの件数だけ並列デコードが走りメモリを食い潰す（`HistoryStore.ocrInFlight` は
    /// 同一項目の二重実行を防ぐだけで、同時実行数の上限ではない）。直列化して常時 1 件分に抑える。
    private static let queue = DispatchQueue(label: "jp.co.ati-mirai.tameo.ocr", qos: .utility)

    /// 画像データから認識テキストを返す（無認識は nil）。
    static func recognizeText(in data: Data, languages: [String] = defaultLanguages) async -> String? {
        await withCheckedContinuation { continuation in
            queue.async {
                guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                      let cgImage = downsampled(from: source) else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: recognize(cgImage, languages: languages))
            }
        }
    }

    /// 画像ファイル（コピーされたパス先）から認識テキストを返す。
    static func recognizeText(inFileAt url: URL, languages: [String] = defaultLanguages) async -> String? {
        await withCheckedContinuation { continuation in
            queue.async {
                // URL 版はファイル全体をメモリへ載せずに済む（ImageIO が必要な分だけ読む）。
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let cgImage = downsampled(from: source) else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: recognize(cgImage, languages: languages))
            }
        }
    }

    /// 最長辺を `maxPixelSize` に収めた CGImage を返す。
    /// ImageIO のサブサンプリング・デコードを使うため、原寸ビットマップは一度も生成されない
    /// （`ImageThumbnailer` と同じ安全な経路）。元画像が上限より小さければ原寸のまま返る（拡大はしない）。
    private static func downsampled(from source: CGImageSource) -> CGImage? {
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, opts as CFDictionary)
    }

    /// Vision で同期的に認識（`queue` 上から呼ぶ）。
    private static func recognize(_ cgImage: CGImage, languages: [String]) -> String? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = languages
        request.usesLanguageCorrection = true

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try? handler.perform([request])

        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        let text = lines.joined(separator: "\n")
        return text.isEmpty ? nil : text
    }
}
