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
