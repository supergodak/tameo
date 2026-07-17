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
    private let installDelegate: ImmediateInstallDelegate

    init() {
        let delegate = ImmediateInstallDelegate()
        installDelegate = delegate
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: delegate,
            userDriverDelegate: nil
        )
    }

    /// 手動チェック（メニュー項目から）。チェック中の多重呼び出しは Sparkle 側で無視される。
    func checkForUpdates() {
        controller.updater.checkForUpdates()
    }
}

/// 自動（サイレント）更新の適用を引き取り、その場でインストールして再起動させるデリゲート。
///
/// これが無いと、自動更新を有効にした利用者へ更新が永久に届かない。Sparkle の既定では、
/// 準備の済んだ自動更新は「アプリ終了時」に適用されるため：
///   `SPUInstallerDriver` は willInstallImmediately に **対象アプリが既に終了しているか**を渡し、
///   `SPUAutomaticUpdateDriver` は未終了かつ本デリゲート未実装なら abortUpdate して終了時まで保留する。
/// Tameo はメニューバー常駐で終了させる機会がほとんどないので、その「終了時」が来ない。
/// 実際 v0.1.9 公開後、自動モードの利用者は DMG を繰り返しダウンロードしながら 0.1.7 のままだった。
///
/// 再起動して失うものは無い（履歴・スニペットは SwiftData に保存済み、未保存状態を持たない）ため、
/// 引き取って即時適用する。体感はメニューバーアイコンが一瞬消えて戻るだけ。
private final class ImmediateInstallDelegate: NSObject, SPUUpdaterDelegate {
    func updater(_ updater: SPUUpdater,
                 willInstallUpdateOnQuit item: SUAppcastItem,
                 immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        NSLog("Tameo: 自動更新 %@ を即時インストールして再起動します", item.displayVersionString)
        immediateInstallHandler()
        return true   // YES = 適用を引き取る（返さないと Sparkle は終了時まで待つ）
    }
}
