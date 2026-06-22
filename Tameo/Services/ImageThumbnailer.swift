import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 画像 Data を「一覧用の小さな PNG」に縮小する純粋ユーティリティ（Data 入 / Data 出）。
/// ImageIO で縮小サイズのみデコードするため、巨大画像でも原寸を RAM へ展開しない。
/// CGImageSource/CGImage はローカルに閉じ込め外へ出さない（Sendable-clean。detached からも安全）。
enum ImageThumbnailer {
    /// 最長辺 maxPixel に縮小した PNG データ。失敗時 nil。
    static func thumbnailPNG(from data: Data, maxPixel: Int) -> Data? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,   // EXIF 回転を反映
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        let out = NSMutableData()
        let pngType = UTType.png.identifier as CFString
        guard let dest = CGImageDestinationCreateWithData(out as CFMutableData, pngType, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, cg, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }

    /// 原寸のピクセル幅・高さ（フルデコードせずプロパティのみ読む）。失敗時 nil。
    static func pixelSize(of data: Data) -> (Int, Int)? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return nil }
        let w = (props[kCGImagePropertyPixelWidth] as? Int) ?? 0
        let h = (props[kCGImagePropertyPixelHeight] as? Int) ?? 0
        guard w > 0, h > 0 else { return nil }
        return (w, h)
    }
}
