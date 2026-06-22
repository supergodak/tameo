import AppKit

/// 一覧行のサムネ NSImage を永続ID単位でメモ化する軽量キャッシュ。
/// SwiftUI が行 body を再評価（↑↓・ページ送りの度）するたびに PNG Data を
/// 再デコードするのを避ける。NSImage は非 Sendable だが本クラスは MainActor 隔離。
@MainActor
final class ThumbnailCache {
    private let cache = NSCache<NSString, NSImage>()

    init(countLimit: Int = 200) {
        cache.countLimit = countLimit
    }

    /// key（永続ID等）でキャッシュ参照。無ければ Data からデコードして格納。
    func image(forKey key: String, data: Data) -> NSImage? {
        if let cached = cache.object(forKey: key as NSString) { return cached }
        guard let img = NSImage(data: data) else { return nil }
        cache.setObject(img, forKey: key as NSString)
        return img
    }
}
