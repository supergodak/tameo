import Foundation
import SQLite3

/// SwiftData ストアの保存場所。
///
/// **背景（2026-07-08 のデータ消失事故）**: `ModelContainer(for:)` を設定なしで使うと、
/// 非サンドボックスアプリの保存先は `~/Library/Application Support/default.store` になる。
/// このパスは他の非サンドボックスアプリや一部の Apple エージェント（icloudmailagent 等）と**共用**で、
/// 別モデルのアプリが同じストアを開くと Core Data の軽量マイグレーションが
/// 「モデルに存在しないエンティティ」を**削除**するため、互いのデータを消し合う。
/// 実際に icloudmailagent が default.store を乗っ取り、Tameo の履歴・スニペットが全消失した。
///
/// 対策: 専用パス `~/Library/Application Support/Tameo/Tameo.store` を明示指定し、
/// 初回起動時に旧共用ストアから一度だけデータを移行する。
enum StoreLocation {

    /// 専用ストアURL（ディレクトリはここで作成する）。
    static func dedicatedStoreURL() throws -> URL {
        let dir = URL.applicationSupportDirectory.appending(path: "Tameo", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appending(path: "Tameo.store")
    }

    /// 旧「共用 default.store」からの一度きり移行。
    /// 新ストアが未作成 かつ 旧ストアに本アプリのテーブル（ZCLIPBOARDITEM）が残っている場合のみ、
    /// ストア一式（-wal / -shm 含む）を新パスへ**コピー**する。
    /// 旧ファイルは他プロセスが使用中の可能性があるため削除・変更しない。
    static func migrateLegacyDefaultStoreIfNeeded(to storeURL: URL) {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: storeURL.path) else { return }   // 新ストアが既にある＝移行済み
        let legacy = URL.applicationSupportDirectory.appending(path: "default.store")
        guard fm.fileExists(atPath: legacy.path),
              storeContainsClipboardItems(at: legacy) else { return }
        for suffix in ["", "-wal", "-shm"] {
            let src = URL(fileURLWithPath: legacy.path + suffix)
            let dst = URL(fileURLWithPath: storeURL.path + suffix)
            if fm.fileExists(atPath: src.path) {
                try? fm.copyItem(at: src, to: dst)
            }
        }
        NSLog("Tameo: legacy default.store からデータを移行しました -> %@", storeURL.path)
    }

    /// SQLite を読み取り専用で開き、Tameo のテーブル（ZCLIPBOARDITEM）が存在するか確認する。
    /// （他アプリのスキーマに乗っ取られた default.store を誤って移行しないためのガード）
    static func storeContainsClipboardItems(at url: URL) -> Bool {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return false
        }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        let sql = "SELECT name FROM sqlite_master WHERE type='table' AND name='ZCLIPBOARDITEM'"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW
    }
}
