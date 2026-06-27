import Foundation
import Vision
import AppKit

/// 画像のオンデバイス文字認識（Vision）。
///
/// コピーした画像（スクショ等）から日本語/英語のテキストを取り出し、検索インデックスへ畳み込む／
/// 「テキストとして貼る」に使う。完全ローカル（外部送信なし）。`DispatchQueue.global` 上で実行し
/// メインスレッドを塞がない。
enum OCRService {

    /// 画像データから認識テキストを返す（無認識は nil）。`recognitionLanguages` は日英を既定。
    static func recognizeText(in data: Data, languages: [String] = ["ja-JP", "en-US"]) async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                guard let image = NSImage(data: data),
                      let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                    continuation.resume(returning: nil)
                    return
                }
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.recognitionLanguages = languages
                request.usesLanguageCorrection = true

                let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
                try? handler.perform([request])

                let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
                let text = lines.joined(separator: "\n")
                continuation.resume(returning: text.isEmpty ? nil : text)
            }
        }
    }
}
