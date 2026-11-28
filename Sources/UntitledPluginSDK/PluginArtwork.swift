import Foundation
import ImageIO
import SwiftUI

/// Artwork travels inside the declaration, so ZIPs keep their three-file format.
package struct PluginIcon: Codable, Equatable, Sendable {
    package var symbol: String
    package var tint: String
    package var png: Data? = nil

    package func validate() throws {
        guard !symbol.isEmpty, symbol.count <= 80,
              symbol.range(of: #"^[a-zA-Z0-9.]+$"#, options: .regularExpression) != nil,
              tint.range(of: #"^#[0-9A-Fa-f]{6}$"#, options: .regularExpression) != nil else {
            throw PluginError.invalid("插件图标需要有效的 SF Symbol 和 #RRGGBB 颜色。")
        }
        if let png {
            guard png.count <= 64 * 1024, png.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]),
                  let source = CGImageSourceCreateWithData(png as CFData, nil), CGImageSourceGetCount(source) == 1,
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int,
                  (32...256).contains(width), width == height,
                  CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary) != nil else {
                throw PluginError.invalid("插件图片必须是 32–256 像素的正方形静态 PNG，且不超过 64 KiB。")
            }
        }
    }

    package var color: Color {
        let rgb = UInt32(tint.dropFirst(), radix: 16) ?? 0x5875E7
        return Color(red: Double((rgb >> 16) & 255) / 255, green: Double((rgb >> 8) & 255) / 255,
                     blue: Double(rgb & 255) / 255)
    }

    package init(symbol: String, tint: String, png: Data? = nil) {
        self.symbol = symbol
        self.tint = tint
        self.png = png
    }
}

/// Bounded, self-contained store artwork. No remote images or executable content.
package struct PluginStorefront: Codable, Equatable, Sendable {
    package let category: String
    package let categorySymbol: String
    package let headline: String
    package let caption: String
    package var jpeg: Data? = nil

    package func validate() throws {
        guard !category.isEmpty, category.count <= 24, !headline.isEmpty, headline.count <= 60,
              caption.count <= 120, categorySymbol.count <= 80,
              categorySymbol.range(of: #"^[a-zA-Z0-9.]+$"#, options: .regularExpression) != nil else {
            throw PluginError.invalid("插件商店展示信息无效。")
        }
        if let jpeg {
            guard jpeg.count <= 96 * 1024, jpeg.starts(with: [255, 216, 255]),
                  let source = CGImageSourceCreateWithData(jpeg as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
                  CGImageSourceGetCount(source) == 1,
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int,
                  (400...1200).contains(width), (256...800).contains(height), width > height,
                  width * height <= 960_000 else {
                throw PluginError.invalid("商店宣传图需为不超过 96 KiB、1200 × 800 像素的静态横向 JPEG。")
            }
        }
    }

    package init(category: String, categorySymbol: String, headline: String, caption: String, jpeg: Data? = nil) {
        self.category = category
        self.categorySymbol = categorySymbol
        self.headline = headline
        self.caption = caption
        self.jpeg = jpeg
    }
}
