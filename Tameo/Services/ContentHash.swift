import CryptoKit
import Foundation

/// 重複排除キー用の SHA-256 16進（小文字）文字列。
/// text/url/filename/color は content の UTF-8、binary は payloadData（無ければ thumbnailPNG）に対して取る。
enum ContentHash {
    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
