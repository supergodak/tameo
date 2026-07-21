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
    ///
    /// 新ストアが未作成 かつ 旧ストアに本アプリのテーブル（ZCLIPBOARDITEM）が残っている場合のみ実行する。
    /// 旧ファイルは他プロセスが使用中の可能性があるため削除・変更しない（読むだけ）。
    ///
    /// 手順は「吸い出す → 検証する → 原子的に設置する」の 3 段。途中で失敗しても新ストアは作られず、
    /// 旧ストアも無傷なので、次回起動でそのまま再試行される（＝失敗が「移行済み」として確定しない）。
    static func migrateLegacyDefaultStoreIfNeeded(to storeURL: URL) {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: storeURL.path) else { return }   // 新ストアが既にある＝移行済み
        let legacy = URL.applicationSupportDirectory.appending(path: "default.store")
        guard fm.fileExists(atPath: legacy.path) else { return }

        switch probeLegacyStore(at: legacy) {
        case .noClipboardItems:
            return                                   // 他アプリのストア。移行しない（正常な素通り）。
        case .unreadable(let reason):
            // 黙って諦めない。ユーザーには「履歴が空」に見えるだけなので、理由を必ず残す。
            NSLog("Tameo: 旧 default.store を読めないため移行を見送りました（旧データは無傷）: %@", reason)
            return
        case .hasClipboardItems:
            break
        }

        // 同一ディレクトリの一時パスへ吸い出す（最後の rename を同一ボリューム内＝原子的に保つため）。
        let staging = storeURL.deletingLastPathComponent()
            .appending(path: "Tameo.store.migrating-\(UUID().uuidString)")
        // 成功時は rename 済みで存在しない。失敗時の中途半端なファイルはここで確実に片付ける。
        defer { try? fm.removeItem(at: staging) }

        if let error = backupDatabase(from: legacy, to: staging) {
            NSLog("Tameo: 旧 default.store の吸い出しに失敗しました（旧データは無傷。次回起動で再試行）: %@", error)
            return
        }
        // 吸い出した結果が実際に開けて目的のテーブルを含むかを検証してから採用する
        // （壊れたものを「移行済み」として確定させない）。
        guard case .hasClipboardItems = probeLegacyStore(at: staging) else {
            NSLog("Tameo: 移行結果の検証に失敗しました（旧データは無傷。次回起動で再試行）")
            return
        }
        do {
            try fm.moveItem(at: staging, to: storeURL)   // 同一ボリューム内の rename ＝原子的
            NSLog("Tameo: legacy default.store からデータを移行しました -> %@", storeURL.path)
        } catch {
            NSLog("Tameo: 移行結果の設置に失敗しました（旧データは無傷。次回起動で再試行）: %@",
                  String(describing: error))
        }
    }

    /// 開けなくなったストア一式を退避する（削除はしない）。
    ///
    /// ストアが壊れて `ModelContainer` が開けないと、以前はそのまま `fatalError` で起動不能になり、
    /// ユーザーは自力でファイルを消すまで復旧できなかった。退避して作り直せば少なくとも起動はできる。
    /// 消さずに改名で残すのは、後から手で救出する余地を潰さないため。
    static func quarantineStore(at storeURL: URL) {
        let fm = FileManager.default
        let stamp = ISO8601DateFormatter().string(from: .now).replacingOccurrences(of: ":", with: "-")
        for suffix in ["", "-wal", "-shm"] {
            let src = URL(fileURLWithPath: storeURL.path + suffix)
            guard fm.fileExists(atPath: src.path) else { continue }
            let dst = URL(fileURLWithPath: storeURL.path + ".corrupt-\(stamp)" + suffix)
            do {
                try fm.moveItem(at: src, to: dst)
                NSLog("Tameo: 開けないストアを退避しました（手動救出用に残します）-> %@", dst.path)
            } catch {
                NSLog("Tameo: 開けないストアの退避に失敗しました: %@", String(describing: error))
            }
        }
    }

    /// 旧ストアの素性。「読めない」と「Tameo のストアではない」を区別する
    /// （前者は再試行すべき異常、後者は正常な素通り）。
    enum LegacyStoreProbe {
        case hasClipboardItems
        case noClipboardItems
        case unreadable(String)
    }

    /// SQLite を読み取り専用で開き、Tameo のテーブル（ZCLIPBOARDITEM）が存在するか確認する。
    /// （他アプリのスキーマに乗っ取られた default.store を誤って移行しないためのガード）
    static func probeLegacyStore(at url: URL) -> LegacyStoreProbe {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            let reason = db.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(db)
            return .unreadable(reason)
        }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        let sql = "SELECT name FROM sqlite_master WHERE type='table' AND name='ZCLIPBOARDITEM'"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return .unreadable(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? .hasClipboardItems : .noClipboardItems
    }

    /// SQLite Backup API で一貫したスナップショットを吸い出す。成功なら nil、失敗なら理由を返す。
    ///
    /// 単純なファイルコピー（本体・-wal・-shm を順に写す）は使えない。コピーの合間に他プロセスが
    /// 旧ストアへ書き込むと本体と WAL の世代が食い違い、壊れたストアが出来上がるため
    /// （そして旧ストアが他プロセスと共用なのは、この移行コードが存在する理由そのものである）。
    /// Backup API は書き込みと競合したら自動でやり直し、常に整合したページ集合を書き出す。
    /// 出力は WAL を取り込んだ単一ファイルなので、-wal / -shm を持ち出す必要もない。
    /// （履歴暗号化の移行前バックアップでも使うため internal。）
    static func backupDatabase(from source: URL, to destination: URL) -> String? {
        var src: OpaquePointer?
        guard sqlite3_open_v2(source.path, &src, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            let reason = src.map { String(cString: sqlite3_errmsg($0)) } ?? "open source failed"
            sqlite3_close(src)
            return reason
        }
        defer { sqlite3_close(src) }

        var dst: OpaquePointer?
        guard sqlite3_open_v2(destination.path, &dst,
                              SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            let reason = dst.map { String(cString: sqlite3_errmsg($0)) } ?? "open destination failed"
            sqlite3_close(dst)
            return reason
        }
        defer { sqlite3_close(dst) }

        guard let backup = sqlite3_backup_init(dst, "main", src, "main") else {
            return String(cString: sqlite3_errmsg(dst))
        }
        let step = sqlite3_backup_step(backup, -1)   // -1 = 全ページを一度に
        let finish = sqlite3_backup_finish(backup)
        guard step == SQLITE_DONE else { return "backup_step failed (code \(step))" }
        guard finish == SQLITE_OK else { return "backup_finish failed (code \(finish))" }
        return nil
    }

    /// WAL をチェックポイントで取り込み、VACUUM でデータベースを再構築する。成功なら nil、失敗なら理由。
    ///
    /// 暗号化移行の**仕上げに必須**。UPDATE は古い行イメージを空きページ・WAL に残すため、
    /// 行を暗号化しただけではファイルの生バイトに平文の残骸が残る（strings で実際に読めた）。
    /// VACUUM は生きているページだけでファイルを作り直すので、残骸ごと消える。
    /// アプリの CoreData 接続が生きたまま別接続で実行するため busy_timeout を置く。
    /// 混んでいて失敗したら呼び出し側が次回起動で再試行する。
    static func compactStore(at url: URL) -> String? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            let reason = db.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(db)
            return reason
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 5000)

        guard sqlite3_exec(db, "PRAGMA wal_checkpoint(TRUNCATE);", nil, nil, nil) == SQLITE_OK else {
            return "wal_checkpoint failed: \(String(cString: sqlite3_errmsg(db)))"
        }
        guard sqlite3_exec(db, "VACUUM;", nil, nil, nil) == SQLITE_OK else {
            return "vacuum failed: \(String(cString: sqlite3_errmsg(db)))"
        }
        return nil
    }
}
