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

    /// 個別削除（パレットの ⌘⌫）。PRIVACY.md が「個別削除できる」と書いている根拠。
    func test_delete_removesOnlyThatItem() {
        let (store, context, _) = makeStore()
        for t in ["A", "B", "C"] {
            store.ingest(text: t, sourceBundleID: nil, isConcealed: false)
        }
        let target = items(context).first { $0.content == "B" }!
        store.delete(target)
        XCTAssertEqual(items(context).map(\.content), ["C", "A"], "B だけが消え、他は残る")
    }

    /// 遅れて着地した取り込みが、後からコピーした項目より上に並ばないこと。
    ///
    /// 画像は `Task.detached` でサムネ生成してから着地するため、挿入時刻で並べると
    /// 「画像A→直後にテキストB」の順でコピーしても A が B より新しくなる（監査 #7）。
    /// 並び順の基準を `capturedAt`（検知時刻）にしたので、着地順に関わらず順序が保たれる。
    func test_lateArrivingPayload_sortsByCaptureTimeNotInsertTime() {
        let (store, context, _) = makeStore()
        let tA = Date.now                      // 画像Aをコピーした瞬間
        let tB = tA.addingTimeInterval(0.1)    // その直後にテキストBをコピー

        // B（後にコピー）が先に着地し、A（先にコピー・detached で遅延）が後から着地する。
        store.ingest(CapturedPayload.text("B", source: nil, capturedAt: tB))
        store.ingest(CapturedPayload.text("A", source: nil, capturedAt: tA))

        XCTAssertEqual(items(context).map(\.content), ["B", "A"],
                       "着地順ではなくコピー順で並ぶ（後からコピーした B が上）")
        // 捨てずに両方残すこと（世代番号で古い方を落とすと、これがデータ損失に化ける）。
        XCTAssertEqual(items(context).count, 2, "遅れて着地した項目も失われない")
    }

    /// 遅れて着地した重複が、既存行の使用時刻を過去へ引き戻さないこと（bump は単調）。
    func test_lateArrivingDuplicate_doesNotMoveExistingItemBackward() {
        let (store, context, _) = makeStore()
        let old = Date.now.addingTimeInterval(-60)
        store.ingest(CapturedPayload.text("A", source: nil, capturedAt: .now))
        store.ingest(CapturedPayload.text("B", source: nil, capturedAt: .now.addingTimeInterval(1)))
        // 1分前に捕捉された A が今ごろ着地しても、A は B より下がらない。
        store.ingest(CapturedPayload.text("A", source: nil, capturedAt: old))
        XCTAssertEqual(items(context).count, 2, "重複行は増えない")
        let a = items(context).first { $0.content == "A" }!
        XCTAssertGreaterThan(a.lastUsedAt, old, "古い捕捉時刻で過去へ引き戻されない")
    }

    // MARK: - 検索（監査 #8）

    /// パレットの表示件数（100）より深い位置にある項目も検索で見つかること。
    ///
    /// 以前は「最新 100 件を取得 → その配列をインメモリで絞る」実装だったため、
    /// 保持上限 200 のうち 101 件目以降は検索に一切現れなかった。
    func test_searchHistory_findsItemsBeyondPaletteWindow() {
        let (store, _, _) = makeStore(maxHistory: 200)
        // 最初に目的の針を入れ、そのあと 150 件積んで深く沈める。
        store.ingest(text: "needle-deep", sourceBundleID: nil, isConcealed: false)
        for i in 0..<150 {
            store.ingest(text: "filler-\(i)", sourceBundleID: nil, isConcealed: false)
        }
        // パレットが一度に持つのは 100 件。針はその窓の外（151番目）にいる。
        let found = store.searchHistory(query: "needle-deep", kinds: [], sortOrder: .lastUsed, limit: 100)
        XCTAssertEqual(found.count, 1, "表示窓(100件)の外にある項目も検索で見つかる")
        XCTAssertEqual(found.first?.content, "needle-deep")
    }

    /// 種別フィルタが DB 側の述語として実際に動くこと（`#Predicate` の配列 contains は
    /// SwiftData が実行時に弾くことがあるため、必ず実ストアで確かめる）。
    func test_searchHistory_filtersByKind() {
        let (store, _, _) = makeStore()
        store.ingest(CapturedPayload.text("plain text", source: nil))
        store.ingest(CapturedPayload.color(code: "#2D7DD2", hex: "#2D7DD2", source: nil))

        let onlyColor = store.searchHistory(query: "", kinds: [.color], sortOrder: .lastUsed, limit: 100)
        XCTAssertEqual(onlyColor.map(\.content), ["#2D7DD2"], "色だけに絞れる")

        let onlyText = store.searchHistory(query: "", kinds: [.text], sortOrder: .lastUsed, limit: 100)
        XCTAssertEqual(onlyText.map(\.content), ["plain text"], "テキストだけに絞れる")

        let both = store.searchHistory(query: "", kinds: [.text, .color], sortOrder: .lastUsed, limit: 100)
        XCTAssertEqual(both.count, 2, "複数種別を渡せる")
    }

    /// クエリ＋種別フィルタの併用（`#Predicate` の複合条件が SwiftData で通ること）。
    func test_searchHistory_combinesQueryAndKind() {
        let (store, _, _) = makeStore()
        store.ingest(CapturedPayload.text("alpha", source: nil))
        store.ingest(CapturedPayload.text("beta", source: nil))
        store.ingest(CapturedPayload.color(code: "#alpha0", hex: "#AA0000", source: nil))

        let hits = store.searchHistory(query: "alpha", kinds: [.text], sortOrder: .lastUsed, limit: 100)
        XCTAssertEqual(hits.map(\.content), ["alpha"], "クエリと種別の両方が効く")
    }

    /// 検索が索引と同じ正規化を通ること（全角/かな/大小の揺れを吸収）。
    func test_searchHistory_normalizesQuery() {
        let (store, _, _) = makeStore()
        store.ingest(text: "ドコモ Ａｐｐｌｅ", sourceBundleID: nil, isConcealed: false)
        XCTAssertEqual(store.searchHistory(query: "どこも", kinds: [], sortOrder: .lastUsed, limit: 100).count, 1,
                       "カタカナ↔ひらがなが一致する")
        XCTAssertEqual(store.searchHistory(query: "apple", kinds: [], sortOrder: .lastUsed, limit: 100).count, 1,
                       "全角→半角・大小が一致する")
    }

    /// 空クエリ・空フィルタは全件（上限まで）を新しい順で返すこと。
    func test_searchHistory_emptyQueryReturnsAllWithinLimit() {
        let (store, _, _) = makeStore()
        for t in ["A", "B", "C"] {
            store.ingest(text: t, sourceBundleID: nil, isConcealed: false)
        }
        let all = store.searchHistory(query: "", kinds: [], sortOrder: .lastUsed, limit: 100)
        XCTAssertEqual(all.map(\.content), ["C", "B", "A"], "新しい順で全件返る")
        let capped = store.searchHistory(query: "", kinds: [], sortOrder: .lastUsed, limit: 2)
        XCTAssertEqual(capped.count, 2, "limit が効く")
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
