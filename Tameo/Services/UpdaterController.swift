import Foundation
import Sparkle

/// Sparkle 自動更新の窓口。標準UI（`SPUStandardUpdaterController`）を保持する。
/// - 起動時に updater を開始＝バックグラウンドの定期チェックがスケジュールされる
///   （初回はユーザーに「自動更新を有効にするか」を尋ねる Sparkle 標準の挙動）。
/// - メニューの「Check for Updates…」から手動チェックも可能。
/// 更新フィード(SUFeedURL)・公開鍵(SUPublicEDKey)は Info.plist（project.yml）で設定。
@MainActor
final class UpdaterController {
    private let controller: SPUStandardUpdaterController

    init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    /// 手動チェック（メニュー項目から）。チェック中の多重呼び出しは Sparkle 側で無視される。
    func checkForUpdates() {
        controller.updater.checkForUpdates()
    }
}
