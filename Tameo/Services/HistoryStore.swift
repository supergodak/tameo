import Foundation
import SwiftData
import Observation

/// 履歴の保存・取り出し口。M1の唯一の書き込み主体。すべて MainActor 上で動く。
/// - 内容の実読み出し（`item.string(forType:)`）は `ClipboardMonitor` の1箇所に隔離してある。
///   ここはそこから渡されたテキストを受け取って永続化するだけ（プライバシー上クリーン）。
@MainActor
@Observable
final class HistoryStore {
    private let modelContext: ModelContext
    /// 履歴の最大保持数の真実源（設定で可変）。超過分は古い順に削除。
    private let settings: SettingsStore

    init(modelContext: ModelContext, settings: SettingsStore) {
        self.modelContext = modelContext
        self.settings = settings
    }

    /// 監視側が組み立てた捕捉ペイロードを履歴へ取り込む（全種別共通の入口）。
    /// 重複判定は `contentHash` で行う（テキストの文字列一致を全種別へ一般化したもの）。
    func ingest(_ payload: CapturedPayload) {
        guard !payload.isConcealed else { return }
        guard payload.byteSize > 0 else { return }

        let hash = ContentHash.sha256Hex(payload.canonicalBytes)

        if let newest = newestItem() {
            // レガシ行（M3 前）は contentHash が空。比較前に一度だけ補完する
            // （アップグレード後の初回再コピーで重複が出るのを全移行なしで防ぐ）。
            if newest.contentHash.isEmpty {
                newest.contentHash = ContentHash.sha256Hex(canonicalBytes(of: newest))
            }
            // 種別が一致し、かつ内容ハッシュも一致するときだけ重複とみなす。
            // 同じパス文字列でも「テキスト行」と「実ファイルの filename 行」は別物として扱い、
            // ハッシュ衝突で filename 捕捉（アイコン/ファイル参照）を取りこぼさない。
            if newest.kindRaw == payload.kind.rawValue, newest.contentHash == hash {
                newest.lastUsedAt = .now
                save()
                return
            }
        }

        let item = ClipboardItem(payload: payload, contentHash: hash)
        modelContext.insert(item)
        prune()
        save()
        scheduleOCRIfNeeded(item)
    }

    /// 既存テキスト経路は薄いラッパとして温存（呼び出し側はバイト等価）。
    func ingest(text: String, sourceBundleID: String?, isConcealed: Bool) {
        guard !isConcealed, !text.isEmpty else { return }
        ingest(CapturedPayload.text(text, source: sourceBundleID))
    }

    /// 既存行の重複排除キー入力バイト（backfill 用）。binary は payloadData、無ければ thumbnailPNG、最後に content。
    private func canonicalBytes(of item: ClipboardItem) -> Data {
        if item.kind.hasBinaryPayload {
            return item.payloadData ?? item.thumbnailPNG ?? Data(item.content.utf8)
        }
        return Data(item.content.utf8)
    }

    /// 既存項目を「今使った」ことにして先頭へ（M2のペースト後移動でも使用）。
    func markUsed(_ item: ClipboardItem) {
        item.lastUsedAt = .now
        save()
    }

    // MARK: - OCR（画像のオンデバイス文字認識）

    /// OCR 実行中の項目（同一項目の二重実行を防ぐ）。
    private var ocrInFlight: Set<PersistentIdentifier> = []

    /// 画像（ピクセル）／画像ファイルを指す filename に対してバックグラウンドで OCR を起動する。
    /// 取り込みは止めず、完了後に `ocrText` と `searchIndex` を更新する。
    func scheduleOCRIfNeeded(_ item: ClipboardItem) {
        guard settings.ocrEnabled, !item.ocrProcessed else { return }
        let id = item.persistentModelID
        guard !ocrInFlight.contains(id) else { return }

        if item.kind.isImage {
            // 画像ピクセル（png/tiff）: 原本（無ければサムネ）をOCR。
            guard let data = item.payloadData ?? item.thumbnailPNG else { return }
            ocrInFlight.insert(id)
            Task { [weak self] in
                let text = await OCRService.recognizeText(in: data)
                self?.applyOCR(id: id, text: text ?? "")
            }
        } else if item.kind == .filename, let url = item.fileURLs.first(where: Self.isImageFile) {
            // コピーされたパスが画像ファイルを指す: そのファイルを読んでOCR（スクショのファイルコピー対応）。
            ocrInFlight.insert(id)
            Task { [weak self] in
                let text = await OCRService.recognizeText(inFileAt: url)
                self?.applyOCR(id: id, text: text ?? "")
            }
        }
    }

    /// 渡された一覧のうち未処理項目に遅延 OCR をかける（種別判定は scheduleOCRIfNeeded 内）。
    func recognizeMissing(in items: [ClipboardItem]) {
        guard settings.ocrEnabled else { return }
        for item in items where !item.ocrProcessed {
            scheduleOCRIfNeeded(item)
        }
    }

    /// OCR 対象とみなす画像ファイル拡張子。
    private static let imageFileExtensions: Set<String> = [
        "png", "jpg", "jpeg", "tiff", "tif", "gif", "bmp", "heic", "heif", "webp",
    ]
    private static func isImageFile(_ url: URL) -> Bool {
        imageFileExtensions.contains(url.pathExtension.lowercased())
    }

    /// OCR 結果を反映（detached からは ID だけ渡し、ここで引き直して書き込む＝アクター越え安全）。
    private func applyOCR(id: PersistentIdentifier, text: String) {
        ocrInFlight.remove(id)
        guard let item = modelContext.model(for: id) as? ClipboardItem else { return }
        item.ocrText = text
        item.ocrProcessed = true
        item.searchIndex = item.searchableSourceText
        save()
    }

    /// 項目のピン留め状態を切り替える。ピンは一覧最上段に固定し、prune から保護される。
    func setPinned(_ item: ClipboardItem, _ pinned: Bool) {
        item.isPinned = pinned
        save()
    }

    /// 全履歴を消去（メニューの「履歴をクリア」用）。
    /// 書き込み（insert/delete/save）は本クラスに一本化する設計のため、View直叩きではなくここを呼ぶ。
    func clearAll() {
        // batch delete（delete(model:)）は externalStorage の sidecar を消さず、画像原本ファイルが孤児化する。
        // オブジェクト単位で削除して per-object のクリーンアップ（sidecar 削除）を走らせる。
        do {
            let items = try modelContext.fetch(FetchDescriptor<ClipboardItem>())
            for item in items { modelContext.delete(item) }
            try modelContext.save()
        } catch {
            NSLog("Tameo: clear all failed: %@", String(describing: error))
        }
    }

    /// 既存（M5前）の全行に検索インデックスを一度だけ補完する。起動時に1回呼ぶ。
    /// 数百〜数千件規模なら同期パスで十分。`UserDefaults` のフラグで再実行を防ぐ。
    func backfillSearchIndexIfNeeded() {
        let key = "tameo.searchIndex.backfilled"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        let d = FetchDescriptor<ClipboardItem>(
            predicate: #Predicate { $0.searchIndex.isEmpty }
        )
        if let items = try? modelContext.fetch(d), !items.isEmpty {
            for item in items {
                item.searchIndex = item.searchableSourceText
            }
            save()
        }
        UserDefaults.standard.set(true, forKey: key)
    }

    /// 1項目の検索インデックスを必要なら補完する（一覧表示・検索の直前に使う遅延 backfill）。
    func ensureSearchIndex(_ item: ClipboardItem) {
        guard item.searchIndex.isEmpty else { return }
        item.searchIndex = item.searchableSourceText
        save()
    }

    // MARK: - Private

    private func newestItem() -> ClipboardItem? {
        var d = FetchDescriptor<ClipboardItem>(sortBy: [SortDescriptor(\.lastUsedAt, order: .reverse)])
        d.fetchLimit = 1
        return try? modelContext.fetch(d).first
    }

    private func prune() {
        let maxHistory = settings.maxHistory
        // まず件数だけを問い合わせ、上限以下なら全件フェッチを避ける（O(n) 全スキャン回避）。
        let total = (try? modelContext.fetchCount(FetchDescriptor<ClipboardItem>())) ?? 0
        guard total > maxHistory else { return }
        let d = FetchDescriptor<ClipboardItem>(sortBy: [SortDescriptor(\.lastUsedAt, order: .reverse)])
        guard let items = try? modelContext.fetch(d) else { return }
        // ピン留めは削除対象から除外し、上限は「ピン以外」に対して適用する。
        let unpinned = items.filter { !$0.isPinned }
        guard unpinned.count > maxHistory else { return }
        for item in unpinned[maxHistory...] {
            modelContext.delete(item)
        }
    }

    private func save() {
        do {
            try modelContext.save()
        } catch {
            // M1: 保存失敗は致命ではないのでログのみ（将来は通知/リトライ）。
            NSLog("Tameo: history save failed: %@", String(describing: error))
        }
    }
}
