import AppKit
import UntitledPluginSDK
import CryptoKit
import ImageIO
import SwiftUI

package struct PluginPresentation: Codable, Equatable, Sendable, Identifiable {
    package let id: String
    package let repository: URL
    package let version: String
    package let name: String
    package let summary: String
    package let icon: PluginIcon?
    package var readmeURL: URL? = nil
    package var storefront: PluginStorefront? = nil
    package var category: String { storefront?.category ?? "效率工具" }
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
package struct PluginPresentationIndex: Sendable {
    package let plugins: [PluginPresentation]

    package static let bundled: Self = {
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

    package func appearance(id: String, repository: URL, version: String) -> PluginPresentation? {
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
