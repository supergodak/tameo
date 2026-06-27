import Foundation
import Vision
import AppKit

/// 画像のオンデバイス文字認識（Vision）。
///
/// コピーした画像（スクショ等）や、コピーされた画像ファイルのパスから日本語/英語のテキストを取り出し、
/// 検索インデックスへ畳み込む／「テキストとして貼る」に使う。完全ローカル（外部送信なし）。
/// `DispatchQueue.global` 上で実行しメインスレッドを塞がない。
enum OCRService {

    static let defaultLanguages = ["ja-JP", "en-US"]

    /// 画像データから認識テキストを返す（無認識は nil）。
    static func recognizeText(in data: Data, languages: [String] = defaultLanguages) async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                guard let image = NSImage(data: data),
                      let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
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
            DispatchQueue.global(qos: .utility).async {
                guard let image = NSImage(contentsOf: url),
                      let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: recognize(cgImage, languages: languages))
            }
        }
    }

    /// Vision で同期的に認識（バックグラウンドキュー上から呼ぶ）。
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
