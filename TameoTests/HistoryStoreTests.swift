import XCTest
import SwiftData
@testable import Tameo

/// 層1: 履歴取り込み・全体重複排除（bump-to-top）・prune（上限/ピン保護）の検証。インメモリSwiftDataで完結。
@MainActor
final class HistoryStoreTests: XCTestCase {

    /// 生成したコンテナをテスト存続期間中つかんでおく（`ModelContext` はコンテナを強参照しないため、
    /// retain しないと関数脱出時にコンテナが解放され、以降の fetch が SwiftData 内でトラップする）。
    private var retainedContainers: [ModelContainer] = []

    override func tearDown() {
        retainedContainers.removeAll()
        super.tearDown()
    }

    /// インメモリのストア一式（DBはメモリのみ・設定は隔離 UserDefaults）。
    private func makeStore(maxHistory: Int = 200) -> (store: HistoryStore, context: ModelContext, settings: SettingsStore) {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try! ModelContainer(
            for: ClipboardItem.self, SnippetFolder.self, Snippet.self,
            configurations: config)
        retainedContainers.append(container)   // ← コンテナを生かし続ける
        let context = container.mainContext
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "tameo.test.\(UUID().uuidString)")!)
        settings.maxHistory = maxHistory
        let store = HistoryStore(modelContext: context, settings: settings)
        return (store, context, settings)
    }

    /// 新しい順の全件。
    private func items(_ context: ModelContext) -> [ClipboardItem] {
        let d = FetchDescriptor<ClipboardItem>(sortBy: [SortDescriptor(\.lastUsedAt, order: .reverse)])
        return (try? context.fetch(d)) ?? []
    }

    func test_ingest_addsItem() {
        let (store, context, _) = makeStore()
        store.ingest(text: "hello", sourceBundleID: nil, isConcealed: false)
        XCTAssertEqual(items(context).count, 1)
        XCTAssertEqual(items(context).first?.content, "hello")
    }

    func test_ingest_skipsConcealedAndEmpty() {
        let (store, context, _) = makeStore()
        store.ingest(text: "s3cr3t", sourceBundleID: nil, isConcealed: true)   // 機密は保存しない
        store.ingest(text: "", sourceBundleID: nil, isConcealed: false)         // 空は保存しない
        XCTAssertEqual(items(context).count, 0)
    }

    func test_ingest_dedupBumpsToTop() {
        let (store, context, _) = makeStore()
        store.ingest(text: "A", sourceBundleID: nil, isConcealed: false)
        store.ingest(text: "B", sourceBundleID: nil, isConcealed: false)
        store.ingest(text: "A", sourceBundleID: nil, isConcealed: false)   // A を再コピー
        let list = items(context)
        XCTAssertEqual(list.count, 2, "A→B→A は重複行を作らず 2 件のまま")
        XCTAssertEqual(list.first?.content, "A", "再コピーした A が最上段へ繰り上がる")
    }

    func test_prune_keepsMaxHistoryAndProtectsPinned() {
        let (store, context, _) = makeStore(maxHistory: 3)
        for t in ["1", "2", "3", "4", "5"] {
            store.ingest(text: t, sourceBundleID: nil, isConcealed: false)
        }
        XCTAssertEqual(items(context).count, 3, "上限3で古い2件が削除される")
        XCTAssertEqual(items(context).map(\.content), ["5", "4", "3"], "新しい3件が残る")

        // 残っている中の最古（"3"）をピンし、さらに超過させてもピンは生き残る。
        let oldest = items(context).last!
        store.setPinned(oldest, true)
        for t in ["6", "7", "8"] {
            store.ingest(text: t, sourceBundleID: nil, isConcealed: false)
        }
        let list = items(context)
        XCTAssertTrue(list.contains { $0.isPinned && $0.content == "3" }, "ピン項目は上限超でも残る")
        XCTAssertEqual(list.filter { !$0.isPinned }.count, 3, "非ピンは上限3を維持")
    }
}
