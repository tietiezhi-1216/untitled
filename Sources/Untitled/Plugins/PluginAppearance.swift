import AppKit
import CryptoKit
import ImageIO
import SwiftUI

/// Artwork travels inside the declaration, so ZIPs keep their three-file format.
struct PluginIcon: Codable, Equatable, Sendable {
    var symbol: String
    var tint: String
    var png: Data? = nil

    func validate() throws {
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

    var color: Color {
        let rgb = UInt32(tint.dropFirst(), radix: 16) ?? 0x5875E7
        return Color(red: Double((rgb >> 16) & 255) / 255, green: Double((rgb >> 8) & 255) / 255,
                     blue: Double(rgb & 255) / 255)
    }
}

struct PluginPresentation: Codable, Equatable, Sendable, Identifiable {
    let id: String
    let repository: URL
    let version: String
    let name: String
    let summary: String
    let icon: PluginIcon?
    var readmeURL: URL? = nil
    var storefront: PluginStorefront? = nil
    var category: String { storefront?.category ?? "效率工具" }
}

/// Bounded, self-contained store artwork. No remote images or executable content.
struct PluginStorefront: Codable, Equatable, Sendable {
    let category: String
    let categorySymbol: String
    let headline: String
    let caption: String
    var jpeg: Data? = nil

    func validate() throws {
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
}

private actor PluginArtworkDecoder {
    static let shared = PluginArtworkDecoder()
    func thumbnail(_ data: Data) -> CGImage? {
        guard !Task.isCancelled, data.count <= 96 * 1024,
              let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 832,
            kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary)
    }
}

@MainActor enum PluginArtworkCache {
    private static var entries: [(key: String, image: NSImage, cost: Int)] = []
    static var cachedByteCount: Int { entries.reduce(0, { $0 + $1.cost }) }
    static var cachedImageCount: Int { entries.count }
    static func image(_ data: Data) async -> NSImage? {
        guard !Task.isCancelled else { return nil }
        let key = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        if let entry = entries.first(where: { $0.key == key }) { return entry.image }
        guard let bitmap = await PluginArtworkDecoder.shared.thumbnail(data), !Task.isCancelled else { return nil }
        let image = NSImage(cgImage: bitmap, size: NSSize(width: bitmap.width, height: bitmap.height))
        entries.removeAll { $0.key == key }
        entries.append((key, image, bitmap.bytesPerRow * bitmap.height))
        while entries.count > 16 || entries.reduce(0, { $0 + $1.cost }) > 12 * 1024 * 1024 { entries.removeFirst() }
        return image
    }
}

struct PluginPromotionView: View {
    let presentation: PluginPresentation
    @ViewState private var image: NSImage?
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                if let image {
                    Image(nsImage: image).resizable().scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height).clipped()
                } else {
                    Color(red: 0.965, green: 0.965, blue: 0.98)
                    (presentation.icon?.color ?? .accentColor).opacity(0.12)
                    PluginIconView(icon: presentation.icon, size: 80)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing).padding(.trailing, 24)
                }
                VStack(alignment: .leading, spacing: 10) {
                    Text(presentation.storefront?.headline ?? presentation.name)
                        .font(.system(size: min(22, geometry.size.width * 0.060), weight: .bold))
                        .lineLimit(3).fixedSize(horizontal: false, vertical: true)
                    Text(presentation.storefront?.caption ?? presentation.summary)
                        .font(.system(size: 10, weight: .medium)).lineLimit(3)
                }
                .foregroundStyle(Color.black.opacity(0.82))
                .frame(width: geometry.size.width * 0.48, alignment: .leading)
                .padding(20)
            }
        }
        .aspectRatio(1.6, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .task(id: presentation.storefront?.jpeg) {
            image = nil
            if let data = presentation.storefront?.jpeg {
                let loaded = await PluginArtworkCache.image(data)
                guard !Task.isCancelled else { return }
                image = loaded
            }
        }
        .onDisappear { image = nil }
        .accessibilityLabel(presentation.storefront?.headline ?? presentation.name)
    }
}

/// Bundled display metadata also refreshes older installed plugin names and artwork.
/// Actions, versions, enabled state and user configuration always come from the installed package.
struct PluginPresentationIndex: Sendable {
    let plugins: [PluginPresentation]

    static let bundled: Self = {
        let url: URL?
        if let resource = Bundle.main.url(forResource: "BundledPlugins", withExtension: "json") { url = resource }
        else {
            #if SWIFT_PACKAGE
            url = Bundle.module.url(forResource: "BundledPlugins", withExtension: "json")
            #else
            url = nil
            #endif
        }
        guard let url, let data = try? Data(contentsOf: url), data.count <= 1024 * 1024,
              let plugins = try? JSONDecoder().decode([PluginPresentation].self, from: data),
              plugins.allSatisfy({ ($0.icon == nil || (try? $0.icon?.validate()) != nil) &&
                  ($0.storefront == nil || (try? $0.storefront?.validate()) != nil) }) else { return Self(plugins: []) }
        return Self(plugins: plugins)
    }()

    func appearance(id: String, repository: URL, version: String) -> PluginPresentation? {
        plugins.first { candidate in
            candidate.id == id && candidate.repository == repository &&
                Version(version).map { current in Version(candidate.version).map { current <= $0 } ?? false } == true
        }
    }
}

struct PluginIconView: View {
    var icon: PluginIcon?
    var fallbackSymbol = "puzzlepiece.extension"
    var size: CGFloat = 48
    @MainActor private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 64
        cache.totalCostLimit = 4 * 1024 * 1024
        return cache
    }()

    var body: some View {
        Group {
            if let image = decodedImage {
                Image(nsImage: image).resizable().interpolation(.high)
            } else {
                Image(systemName: icon?.symbol ?? fallbackSymbol)
                    .font(.system(size: size * 0.44, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: size, height: size)
                    .background((icon?.color ?? .accentColor).gradient)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
        .accessibilityHidden(true)
    }

    private var decodedImage: NSImage? {
        guard let data = icon?.png, data.count <= 64 * 1024 else { return nil }
        let key = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() as NSString
        if let cached = Self.cache.object(forKey: key) { return cached }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 128,
              ] as CFDictionary) else { return nil }
        let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        Self.cache.setObject(image, forKey: key, cost: cgImage.bytesPerRow * cgImage.height)
        return image
    }
}
