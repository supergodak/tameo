import Foundation
import CryptoKit
import Security

/// 履歴の保存時暗号化（常時オン・設定なし）の鍵と暗号操作。
///
/// - 鍵: 256bit のマスター鍵を Keychain（Generic Password）に保持。初回起動で生成する。
///   そこから HKDF で「暗号化用」「重複排除索引用」の2鍵を導出する（用途分離）。
/// - 暗号: AES-GCM（combined 形式）。フィールド単位で暗号化する。
/// - 重複排除キー: 素の SHA-256 だと短い内容（URL・定型文）は辞書攻撃で逆引きできるため、
///   鍵付き HMAC-SHA256（blind index）にする。DB 単体を持ち出されても内容の照合はできない。
/// - 失敗方針: Keychain が使えない異常時は**プロセス限りの一時鍵**に落とす。
///   その場合、保存した履歴は再起動後に読めなくなるが、「平文で書く」方向には倒さない。
/// - テスト: XCTest 下では Keychain に触れず一時鍵を使う（開発機の実 Keychain を汚さない）。
enum HistoryVault {

    private static let service = "jp.co.ati-mirai.tameo.vault"
    private static let account = "history-key-v1"

    /// マスター鍵（プロセス中は不変）。`static let` なので初期化はスレッド安全。
    private static let masterKey: SymmetricKey = loadOrCreateMasterKey()

    /// フィールド暗号化用の導出鍵。
    private static let encryptionKey: SymmetricKey = HKDF<SHA256>.deriveKey(
        inputKeyMaterial: masterKey, info: Data("tameo.history.enc.v1".utf8), outputByteCount: 32)

    /// 重複排除 blind index 用の導出鍵。
    private static let indexKey: SymmetricKey = HKDF<SHA256>.deriveKey(
        inputKeyMaterial: masterKey, info: Data("tameo.history.idx.v1".utf8), outputByteCount: 32)

    // MARK: - 暗号化 / 復号

    static func seal(_ data: Data) -> Data? {
        try? AES.GCM.seal(data, using: encryptionKey).combined
    }

    static func open(_ data: Data) -> Data? {
        guard let box = try? AES.GCM.SealedBox(combined: data) else { return nil }
        return try? AES.GCM.open(box, using: encryptionKey)
    }

    static func sealString(_ string: String) -> Data? {
        seal(Data(string.utf8))
    }

    static func openString(_ data: Data) -> String? {
        open(data).flatMap { String(data: $0, encoding: .utf8) }
    }

    // MARK: - 重複排除キー（blind index）

    /// 内容バイト列の鍵付きハッシュ（小文字hex）。同一内容⇔同一値だが、鍵なしには照合できない。
    static func blindIndexHex(_ data: Data) -> String {
        Data(HMAC<SHA256>.authenticationCode(for: data, using: indexKey))
            .map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - 鍵の取得/生成

    private static func loadOrCreateMasterKey() -> SymmetricKey {
        // テスト実行中は Keychain に触れない（実環境の鍵を読まない・書かない）。
        if NSClassFromString("XCTestCase") != nil {
            return SymmetricKey(size: .bits256)
        }
        #if DEBUG
        // スクショ撮影のデモモードも一時鍵で動かす。Debug 署名は Developer ID 署名版が作った
        // Keychain 項目にアクセスできず、認証ダイアログが出てパレットの撮影を妨げるため。
        if CommandLine.arguments.contains(where: { $0.hasPrefix("--demo-shot=") }) {
            return SymmetricKey(size: .bits256)
        }
        #endif
        if let existing = readKeyFromKeychain() { return existing }

        let newKey = SymmetricKey(size: .bits256)
        let keyData = newKey.withUnsafeBytes { Data($0) }
        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: keyData,
            // ログイン起動の常駐アプリなので、初回アンロック後は常に読める必要がある。
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let status = SecItemAdd(add as CFDictionary, nil)
        if status == errSecSuccess { return newKey }
        // 競合（別インスタンスが同時に生成）なら読み直しで勝った方に合流する。
        if status == errSecDuplicateItem, let existing = readKeyFromKeychain() { return existing }
        NSLog("Tameo: 履歴暗号鍵を Keychain に保存できません (%d)。一時鍵で継続します（この間の履歴は再起動後に読めません）", status)
        return newKey
    }

    private static func readKeyFromKeychain() -> SymmetricKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data, data.count == 32 else { return nil }
        return SymmetricKey(data: data)
    }
}
