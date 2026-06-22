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
    /// 履歴の最大保持数（既定）。超過分は古い順に削除。
    var maxHistory: Int = 200

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    /// 監視側が検出したテキストを履歴へ取り込む。
    func ingest(text: String, sourceBundleID: String?, isConcealed: Bool) {
        guard !isConcealed else { return }
        guard !text.isEmpty else { return }

        // 直近（最新）と同一内容なら、重複を作らず最終使用日時だけ更新。
        if let newest = newestItem(), newest.content == text {
            newest.lastUsedAt = .now
            save()
            return
        }

        let item = ClipboardItem(content: text, sourceBundleID: sourceBundleID)
        modelContext.insert(item)
        prune()
        save()
    }

    /// 既存項目を「今使った」ことにして先頭へ（M2のペースト後移動でも使用）。
    func markUsed(_ item: ClipboardItem) {
        item.lastUsedAt = .now
        save()
    }

    /// 全履歴を消去（メニューの「履歴をクリア」用）。
    /// 書き込み（insert/delete/save）は本クラスに一本化する設計のため、View直叩きではなくここを呼ぶ。
    func clearAll() {
        do {
            try modelContext.delete(model: ClipboardItem.self)
            try modelContext.save()
        } catch {
            NSLog("Tameo: clear all failed: %@", String(describing: error))
        }
    }

    // MARK: - Private

    private func newestItem() -> ClipboardItem? {
        var d = FetchDescriptor<ClipboardItem>(sortBy: [SortDescriptor(\.lastUsedAt, order: .reverse)])
        d.fetchLimit = 1
        return try? modelContext.fetch(d).first
    }

    private func prune() {
        let d = FetchDescriptor<ClipboardItem>(sortBy: [SortDescriptor(\.lastUsedAt, order: .reverse)])
        guard let items = try? modelContext.fetch(d), items.count > maxHistory else { return }
        for item in items[maxHistory...] {
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
