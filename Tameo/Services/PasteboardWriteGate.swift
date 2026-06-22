import Foundation

/// 自己コピー抑止ゲート。
///
/// Tameo（`PasteService`）がペーストボードへ書いた直後の `changeCount` を記録し、
/// `ClipboardMonitor` がその 1 回ぶんの変化を「自分が起こした変化」として ingest をスキップするための共有状態。
///
/// これにより貼り戻し由来の重複行を **全種別で** 防ぐ。書き戻しバイトが AppKit により
/// 正規化されて原本とバイト不一致になっても影響を受けない（再取り込みハッシュ一致に依存しない）。
@MainActor
final class PasteboardWriteGate {
    /// 直近に Tameo 自身が書き込んだ際の `NSPasteboard.general.changeCount`。
    private(set) var lastSelfWriteChangeCount: Int?

    /// ペーストボード書き込み直後に呼ぶ（引数は書き込み後の changeCount）。
    func noteSelfWrite(changeCount: Int) {
        lastSelfWriteChangeCount = changeCount
    }

    /// 監視側の判定: この変化は Tameo 自身が起こしたものか。
    func isSelfWrite(changeCount: Int) -> Bool {
        changeCount == lastSelfWriteChangeCount
    }
}
