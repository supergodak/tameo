import Foundation
import Observation
import ServiceManagement

/// 履歴の並び順。
enum HistorySortOrder: String, CaseIterable {
    case lastUsed    // 最終使用日時
    case createdAt   // 作成日時
}

/// アプリのスカラ設定の単一の真実源。スニペット本体は SwiftData（`SnippetStore`）が持ち、ここには載せない。
///
/// 方針: `@Observable` で UI へ反映しつつ、各プロパティの `didSet` で `UserDefaults` へ手書き永続化する
/// （`@AppStorage` を `@Observable` のプロパティへ直付けすると反映／ビルドの不整合が起きるため避ける）。
/// ホットキーは `KeyboardShortcuts` が独自に `UserDefaults` 永続化するため、ここでは二重管理しない。
/// 各値は消費側（`HistoryStore` / `PasteService` / `HistoryPanelController`）へ本ストアを注入して参照する。
@MainActor
@Observable
final class SettingsStore {
    private let defaults: UserDefaults

    /// 記憶する履歴数（既定 200）。`HistoryStore.prune` とパレットのスナップショット件数の真実源。
    var maxHistory: Int {
        didSet { defaults.set(maxHistory, forKey: Keys.maxHistory) }
    }

    /// 履歴の並び順（既定: 最終使用日時）。`HistoryPanelController.fetchTopItems` のソートに反映。
    var sortOrder: HistorySortOrder {
        didSet { defaults.set(sortOrder.rawValue, forKey: Keys.sortOrder) }
    }

    /// 選択後に ⌘V を自動入力する（既定 true）。false なら書き込みのみで、貼り付けはユーザーが手動で行う。
    var inputPasteCommand: Bool {
        didSet { defaults.set(inputPasteCommand, forKey: Keys.inputPasteCommand) }
    }

    // MARK: - 保存する種別（既定すべて true ＝従来等価）。ClipboardMonitor が取り込み前に参照する。
    var storeText: Bool { didSet { defaults.set(storeText, forKey: Keys.storeText) } }
    var storeRichText: Bool { didSet { defaults.set(storeRichText, forKey: Keys.storeRichText) } }
    var storePDF: Bool { didSet { defaults.set(storePDF, forKey: Keys.storePDF) } }
    var storeImage: Bool { didSet { defaults.set(storeImage, forKey: Keys.storeImage) } }
    var storeFilename: Bool { didSet { defaults.set(storeFilename, forKey: Keys.storeFilename) } }
    var storeURL: Bool { didSet { defaults.set(storeURL, forKey: Keys.storeURL) } }
    var storeColor: Bool { didSet { defaults.set(storeColor, forKey: Keys.storeColor) } }

    /// コピーした画像をオンデバイス OCR して検索・テキスト貼付を可能にする（既定 true）。完全ローカル。
    var ocrEnabled: Bool { didSet { defaults.set(ocrEnabled, forKey: Keys.ocrEnabled) } }

    // MARK: - 貼付変換（パレットの ⌃番号 / ⌃⏎ で適用）。適用順は URLクリーン → 全角→半角 → 空白整理。
    /// 全角英数・記号を半角へ（既定 true）。かな・漢字には触れない。
    var transformHalfWidth: Bool { didSet { defaults.set(transformHalfWidth, forKey: Keys.transformHalfWidth) } }
    /// URL のトラッキングパラメータ（utm_* / fbclid 等）を除去（既定 true）。テキスト全体が単一URLのときだけ働く。
    var transformCleanURL: Bool { didSet { defaults.set(transformCleanURL, forKey: Keys.transformCleanURL) } }
    /// 前後トリム＋改行を空白に＋連続空白の圧縮（既定 false）。PDFコピペの改行混入対策。
    var transformTidyWhitespace: Bool { didSet { defaults.set(transformTidyWhitespace, forKey: Keys.transformTidyWhitespace) } }

    /// 除外アプリの bundle id 群。これらが前面のときコピーした内容は履歴に残さない（既定: 空）。
    var excludedBundleIDs: [String] {
        didSet { defaults.set(excludedBundleIDs, forKey: Keys.excludedBundleIDs) }
    }

    /// ログイン時に起動（`SMAppService` 連動。UserDefaults ではなくシステムの登録状態が真実源）。
    var launchAtLogin: Bool {
        didSet {
            guard !isSyncingLaunchAtLogin else { return }
            applyLaunchAtLogin(launchAtLogin)
        }
    }
    /// 再同期時の自己代入が didSet を再帰させないためのガード。
    private var isSyncingLaunchAtLogin = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // 未設定なら既定値。init 内の代入は didSet を発火しない（不要な書き戻し／副作用を避ける）。
        self.maxHistory = (defaults.object(forKey: Keys.maxHistory) as? Int) ?? 200
        self.sortOrder = HistorySortOrder(rawValue: defaults.string(forKey: Keys.sortOrder) ?? "") ?? .lastUsed
        self.inputPasteCommand = (defaults.object(forKey: Keys.inputPasteCommand) as? Bool) ?? true
        self.storeText = (defaults.object(forKey: Keys.storeText) as? Bool) ?? true
        self.storeRichText = (defaults.object(forKey: Keys.storeRichText) as? Bool) ?? true
        self.storePDF = (defaults.object(forKey: Keys.storePDF) as? Bool) ?? true
        self.storeImage = (defaults.object(forKey: Keys.storeImage) as? Bool) ?? true
        self.storeFilename = (defaults.object(forKey: Keys.storeFilename) as? Bool) ?? true
        self.storeURL = (defaults.object(forKey: Keys.storeURL) as? Bool) ?? true
        self.storeColor = (defaults.object(forKey: Keys.storeColor) as? Bool) ?? true
        self.ocrEnabled = (defaults.object(forKey: Keys.ocrEnabled) as? Bool) ?? true
        self.transformHalfWidth = (defaults.object(forKey: Keys.transformHalfWidth) as? Bool) ?? true
        self.transformCleanURL = (defaults.object(forKey: Keys.transformCleanURL) as? Bool) ?? true
        self.transformTidyWhitespace = (defaults.object(forKey: Keys.transformTidyWhitespace) as? Bool) ?? false
        self.excludedBundleIDs = defaults.stringArray(forKey: Keys.excludedBundleIDs) ?? []
        // ログイン項目は OS の登録状態を初期値に（.requiresApproval も実質有効として扱う。UserDefaults とは独立）。
        self.launchAtLogin = Self.isEffectivelyEnabled(SMAppService.mainApp.status)
    }

    /// 指定種別を履歴に保存するか（`ClipboardMonitor` の取り込みゲート）。既定はすべて true。
    func isStoreEnabled(_ kind: ClipKind) -> Bool {
        switch kind {
        case .text: return storeText
        case .rtf, .rtfd: return storeRichText
        case .pdf: return storePDF
        case .png, .tiff: return storeImage
        case .filename: return storeFilename
        case .url: return storeURL
        case .color: return storeColor
        }
    }

    /// ログイン項目の登録/解除を OS へ反映し、実状態へ再同期する。
    /// 失敗してもクラッシュさせずログのみ。失敗時はトグルを OS の実状態へ戻し「表示の嘘」を防ぐ。
    private func applyLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("Tameo: launch-at-login toggle failed: %@", String(describing: error))
        }
        // OS の実状態へ寄せる（失敗時の乖離・承認待ちを反映。自己代入は再帰ガードで保護）。
        let synced = Self.isEffectivelyEnabled(SMAppService.mainApp.status)
        if launchAtLogin != synced {
            isSyncingLaunchAtLogin = true
            launchAtLogin = synced
            isSyncingLaunchAtLogin = false
        }
    }

    /// `.enabled` と `.requiresApproval`（システム設定で承認すれば有効）を「実質有効」とみなす。
    private static func isEffectivelyEnabled(_ status: SMAppService.Status) -> Bool {
        status == .enabled || status == .requiresApproval
    }

    private enum Keys {
        static let maxHistory = "tameo.maxHistory"
        static let sortOrder = "tameo.sortOrder"
        static let inputPasteCommand = "tameo.inputPasteCommand"
        static let storeText = "tameo.store.text"
        static let storeRichText = "tameo.store.richText"
        static let storePDF = "tameo.store.pdf"
        static let storeImage = "tameo.store.image"
        static let storeFilename = "tameo.store.filename"
        static let storeURL = "tameo.store.url"
        static let storeColor = "tameo.store.color"
        static let ocrEnabled = "tameo.ocrEnabled"
        static let transformHalfWidth = "tameo.transform.halfWidth"
        static let transformCleanURL = "tameo.transform.cleanURL"
        static let transformTidyWhitespace = "tameo.transform.tidyWhitespace"
        static let excludedBundleIDs = "tameo.excludedBundleIDs"
    }
}
