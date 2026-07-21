import Foundation
import SwiftData

/// クリップボード履歴の1項目。
/// 追加フィールドは**全てデフォルト値付き**（既存ストアの軽量移行を壊さないため）。
///
/// ## 保存時暗号化（常時オン）
/// 内容を持つフィールド（本文・検索索引・OCR・原本・サムネ・パス・色）は AES-GCM で暗号化した
/// `enc*` カラムに保存する。旧来の平文カラムは `@Attribute(originalName:)` で `stored*` に
/// リネームして温存し（列名は不変＝軽量移行安全）、既存名は**復号アクセサ（computed）**として
/// 提供する。呼び出し側のコードは無変更で済む。
/// - 旧平文カラムに値が残る行＝暗号化前のレガシ行。getter は enc → stored の順でフォールバック
///   するので、移行前でも読める。移行は `HistoryStore.encryptLegacyHistoryIfNeeded()` が一度だけ行う。
/// - `encContent == nil` を「未移行」の印として使う（移行済み・新規行は空文字でも必ず封をする）。
/// - 注意: computed になったフィールドは `#Predicate` で使えない。検索はメモリ内で行う
///   （`HistoryStore.searchHistory`）。DB 側で絞ってよいのは kindRaw / contentHash / 日時 / isPinned 等の
///   平文メタデータのみ。
@Model
final class ClipboardItem {
    // MARK: - 平文のまま持つメタデータ（内容そのものではない）
    /// 履歴に追加された日時（不変の作成時刻）。
    var createdAt: Date = Date.now
    /// 最終使用日時。一覧の並び順（新しい順）と「使ったら先頭へ」に使う可変キー。
    var lastUsedAt: Date = Date.now
    /// データ種別の生値（`ClipKind.rawValue`）。
    var kindRaw: String = ClipKind.text.rawValue
    /// コピー元アプリの bundle id。
    var sourceBundleID: String?
    /// 機密マーク付きデータか（保存前に弾くので原則 false）。
    var isConcealed: Bool = false
    /// 本文のバイト長（UTF-8、binary は原本サイズ）。簡易な容量把握用。
    var byteSize: Int = 0
    /// 貼り戻し時の主要 UTI。
    var payloadUTI: String = "public.utf8-plain-text"
    /// 重複排除キー（鍵付き HMAC-SHA256 の小文字hex＝blind index）。空＝レガシ行。
    /// 暗号化導入前は素の SHA-256 だったが、短い内容は辞書攻撃で逆引きできるため
    /// 移行時に HMAC へ再計算する。DB 側の等価フィルタに使うので平文カラムのまま。
    var contentHash: String = ""
    /// 画像のピクセル幅・高さ（非画像は 0）。
    var pixelWidth: Int = 0
    var pixelHeight: Int = 0
    /// サイズ上限超過で原本を破棄した画像か。
    var payloadTruncated: Bool = false
    /// ピン留め（お気に入り）。一覧で最上段に固定し、prune の削除対象から除外する。
    var isPinned: Bool = false
    /// OCR を試行済みか（未認識でも true）。再OCRの抑止に使う。
    var ocrProcessed: Bool = false

    // MARK: - 旧平文カラム（列名は据え置き・移行後は空になる）
    @Attribute(originalName: "content") var storedContent: String = ""
    @Attribute(originalName: "searchIndex") var storedSearchIndex: String = ""
    @Attribute(originalName: "ocrText") var storedOcrText: String = ""
    @Attribute(originalName: "fileURLStrings") var storedFileURLStrings: String = ""
    @Attribute(originalName: "colorHex") var storedColorHex: String = ""
    @Attribute(.externalStorage, originalName: "payloadData") var storedPayloadData: Data? = nil
    @Attribute(originalName: "thumbnailPNG") var storedThumbnailPNG: Data? = nil

    // MARK: - 暗号化カラム（AES-GCM combined。既定 nil ＝軽量移行で追加される）
    var encContent: Data? = nil
    var encSearchIndex: Data? = nil
    var encOcrText: Data? = nil
    var encFileURLStrings: Data? = nil
    var encColorHex: Data? = nil
    @Attribute(.externalStorage) var encPayloadData: Data? = nil
    var encThumbnailPNG: Data? = nil

    // MARK: - 復号キャッシュ（毎キーストロークの検索で全項目を再復号しないため）
    @Transient private var cachedContent: String? = nil
    @Transient private var cachedSearchIndex: String? = nil
    @Transient private var cachedOcrText: String? = nil

    // MARK: - 復号アクセサ（既存コードはこの名前のまま無変更で動く）

    /// 表示・ペースト対象の本文。
    var content: String {
        get {
            if let cachedContent { return cachedContent }
            let v = encContent.flatMap { HistoryVault.openString($0) } ?? storedContent
            cachedContent = v
            return v
        }
        set { cachedContent = newValue; setEncrypted(newValue, into: \.encContent, legacy: \.storedContent) }
    }

    /// 検索用の正規化済みインデックス文字列。空＝レガシ行（初回の検索時に backfill）。
    var searchIndex: String {
        get {
            if let cachedSearchIndex { return cachedSearchIndex }
            let v = encSearchIndex.flatMap { HistoryVault.openString($0) } ?? storedSearchIndex
            cachedSearchIndex = v
            return v
        }
        set { cachedSearchIndex = newValue; setEncrypted(newValue, into: \.encSearchIndex, legacy: \.storedSearchIndex) }
    }

    /// 画像のオンデバイス OCR で認識したテキスト（非画像・未認識は空）。
    var ocrText: String {
        get {
            if let cachedOcrText { return cachedOcrText }
            let v = encOcrText.flatMap { HistoryVault.openString($0) } ?? storedOcrText
            cachedOcrText = v
            return v
        }
        set { cachedOcrText = newValue; setEncrypted(newValue, into: \.encOcrText, legacy: \.storedOcrText) }
    }

    /// filename の改行連結絶対パス（非ファイルは空）。
    var fileURLStrings: String {
        get { encFileURLStrings.flatMap { HistoryVault.openString($0) } ?? storedFileURLStrings }
        set { setEncrypted(newValue, into: \.encFileURLStrings, legacy: \.storedFileURLStrings) }
    }

    /// 色の #RRGGBB(AA)（非色は空）。
    var colorHex: String {
        get { encColorHex.flatMap { HistoryVault.openString($0) } ?? storedColorHex }
        set { setEncrypted(newValue, into: \.encColorHex, legacy: \.storedColorHex) }
    }

    /// 原本バイナリ（画像/rtf/rtfd/pdf）。
    var payloadData: Data? {
        get { encPayloadData.flatMap { HistoryVault.open($0) } ?? storedPayloadData }
        set { setEncryptedData(newValue, into: \.encPayloadData, legacy: \.storedPayloadData) }
    }

    /// 一覧表示用の小さな PNG。復号コストは `ThumbnailCache` が吸収する。
    var thumbnailPNG: Data? {
        get { encThumbnailPNG.flatMap { HistoryVault.open($0) } ?? storedThumbnailPNG }
        set { setEncryptedData(newValue, into: \.encThumbnailPNG, legacy: \.storedThumbnailPNG) }
    }

    /// 暗号化して書く。封に失敗した場合だけ平文カラムへ退避する（データを失う方向には倒さない）。
    private func setEncrypted(_ value: String, into enc: ReferenceWritableKeyPath<ClipboardItem, Data?>,
                              legacy: ReferenceWritableKeyPath<ClipboardItem, String>) {
        if let sealed = HistoryVault.sealString(value) {
            self[keyPath: enc] = sealed
            self[keyPath: legacy] = ""
        } else {
            self[keyPath: enc] = nil
            self[keyPath: legacy] = value
        }
    }

    private func setEncryptedData(_ value: Data?, into enc: ReferenceWritableKeyPath<ClipboardItem, Data?>,
                                  legacy: ReferenceWritableKeyPath<ClipboardItem, Data?>) {
        guard let value else {
            self[keyPath: enc] = nil
            self[keyPath: legacy] = nil
            return
        }
        if let sealed = HistoryVault.seal(value) {
            self[keyPath: enc] = sealed
            self[keyPath: legacy] = nil
        } else {
            self[keyPath: enc] = nil
            self[keyPath: legacy] = value
        }
    }

    /// 暗号化移行が済んでいない行か（`encContent` の有無を印にする。新規・移行済みは空でも封をする）。
    var needsEncryptionMigration: Bool { encContent == nil }

    /// 復号キャッシュを捨てる。**enc*/stored* カラムをアクセサを通さず直接書いた場合は必ず呼ぶこと**
    /// （通常コードにその経路は存在しない。テストのレガシ行シミュレーションが唯一の利用者）。
    func invalidateDecryptedCaches() {
        cachedContent = nil
        cachedSearchIndex = nil
        cachedOcrText = nil
    }

    // MARK: - 派生アクセサ

    /// 種別の型付きアクセサ（未知値は .text にフォールバック）。
    var kind: ClipKind { ClipKind(rawValue: kindRaw) ?? .text }

    /// 検索インデックスの生成元テキスト（lazy backfill 用）。本文＋色hex＋ファイルパス＋画像OCRテキスト。
    var searchableSourceText: String {
        SearchNormalizer.indexString(content: content, colorHex: colorHex,
                                     fileURLStrings: fileURLStrings, ocrText: ocrText)
    }

    /// filename の file URL 配列（`fileURLStrings` は absoluteString 群＝改行分割安全）。
    var fileURLs: [URL] {
        fileURLStrings.split(separator: "\n").compactMap { URL(string: String($0)) }
    }

    init(
        content: String,
        createdAt: Date = .now,
        kind: ClipKind = .text,
        sourceBundleID: String? = nil,
        isConcealed: Bool = false
    ) {
        self.createdAt = createdAt
        self.lastUsedAt = createdAt
        self.kindRaw = kind.rawValue
        self.sourceBundleID = sourceBundleID
        self.isConcealed = isConcealed
        self.byteSize = content.utf8.count
        self.content = content
        self.searchIndex = SearchNormalizer.indexString(content: content)
    }

    /// 非テキスト種別を含む取り込み用。`CapturedPayload`（Sendable）から生成する designated init。
    init(payload: CapturedPayload, contentHash: String) {
        // 挿入時刻ではなく「コピーを検知した時刻」で並べる。画像は detached のサムネ生成を挟んで
        // 遅れて着地するため、.now だと直後にコピーしたテキストより新しい行になってしまう。
        self.createdAt = payload.capturedAt
        self.lastUsedAt = payload.capturedAt
        self.kindRaw = payload.kind.rawValue
        self.sourceBundleID = payload.sourceBundleID
        self.isConcealed = payload.isConcealed
        self.byteSize = payload.byteSize
        self.payloadUTI = payload.payloadUTI
        self.contentHash = contentHash
        self.pixelWidth = payload.pixelWidth
        self.pixelHeight = payload.pixelHeight
        self.payloadTruncated = payload.payloadTruncated
        self.content = payload.content
        self.payloadData = payload.payloadData
        self.thumbnailPNG = payload.thumbnailPNG
        self.fileURLStrings = payload.fileURLStrings
        self.colorHex = payload.colorHex
        self.searchIndex = SearchNormalizer.indexString(
            content: payload.content,
            colorHex: payload.colorHex,
            fileURLStrings: payload.fileURLStrings
        )
    }
}
