import Foundation
import UntitledPluginSDK

/// The data-only v1 contract for the speech module. It cannot select a new
/// renderer, change the panel's focus behavior, or override accessibility.
struct DictationHUDStyle: Equatable, Sendable {
    static let name = "doubao.hud"
    static let defaults = Self()
    static let captionHeight: CGFloat = 23

    private(set) var compactWidth: CGFloat = 88
    private(set) var compactHeight: CGFloat = 38
    private(set) var maximumWidth: CGFloat = 296
    private(set) var expandedHeight: CGFloat = 48
    private(set) var minimumCaptionWidth: CGFloat = 128
    private(set) var contentInset: CGFloat = 15
    private(set) var openingDuration: TimeInterval = 0.34
    private(set) var growthDuration: TimeInterval = 0.21
    private(set) var waveFadeEnd: CGFloat = 0.73
    private(set) var captionFadeStart: CGFloat = 0.26
    private(set) var driftSpeed: Double = 1
    private(set) var driftAmount: CGFloat = 1
    private(set) var poolOpacity: CGFloat = 1
    private(set) var poolColors: [SIMD3<Double>] = [
        .init(0.19, 0.86, 0.76), .init(0.22, 0.52, 1), .init(0.62, 0.39, 1),
        .init(0.98, 0.43, 0.72), .init(1, 0.70, 0.37),
    ]

    var compact: CGSize { .init(width: compactWidth, height: compactHeight) }
    var expanded: CGSize { .init(width: maximumWidth, height: expandedHeight) }
    func captionWidth(in width: CGFloat) -> CGFloat { max(1, width - 2 * contentInset) }

    private init() {}
    init(in manifest: PluginManifest) throws {
        guard let values = manifest.styles?[Self.name] else { self = Self.defaults; return }
        self = try Self(values)
    }
    init(_ values: [String: PluginStyleValue]) throws {
        var remaining = values
        guard remaining.removeValue(forKey: "version") == .number(1) else {
            throw PluginError.invalid("不支持此语音浮条样式版本。")
        }
        func read(_ key: String, _ fallback: Double, _ range: ClosedRange<Double>) throws -> Double {
            guard let value = remaining.removeValue(forKey: key) else { return fallback }
            guard case .number(let number) = value, range.contains(number) else {
                throw PluginError.invalid("语音浮条样式 \(key) 超出支持范围。")
            }
            return number
        }
        compactWidth = try read("compactWidth", compactWidth, 80...116)
        compactHeight = try read("compactHeight", compactHeight, 36...48)
        maximumWidth = try read("maximumWidth", maximumWidth, 200...360)
        expandedHeight = try read("expandedHeight", expandedHeight, 44...64)
        minimumCaptionWidth = try read("minimumCaptionWidth", minimumCaptionWidth, 120...168)
        contentInset = try read("contentInset", contentInset, 12...26)
        openingDuration = try read("openingMilliseconds", openingDuration * 1000, 180...520) / 1000
        growthDuration = try read("growthMilliseconds", growthDuration * 1000, 110...380) / 1000
        waveFadeEnd = try read("waveFadeEnd", waveFadeEnd, 0.50...0.82)
        captionFadeStart = try read("captionFadeStart", captionFadeStart, 0.18...0.36)
        driftSpeed = try read("driftSpeed", driftSpeed, 0.25...1.6)
        driftAmount = try read("driftAmount", driftAmount, 0.55...1.3)
        poolOpacity = try read("poolOpacity", poolOpacity, 0.65...1.12)
        if let palette = remaining.removeValue(forKey: "poolColors") {
            guard case .strings(let colors) = palette, colors.count == 5 else {
                throw PluginError.invalid("语音浮条需要五种 #RRGGBB 颜色。")
            }
            poolColors = try colors.map { written in
                guard written.utf8.count == 7, written.first == "#",
                      written.dropFirst().utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }),
                      let rgb = UInt32(written.dropFirst(), radix: 16) else {
                    throw PluginError.invalid("语音浮条需要五种 #RRGGBB 颜色。")
                }
                return SIMD3(Double((rgb >> 16) & 255), Double((rgb >> 8) & 255), Double(rgb & 255)) / 255
            }
        }
        guard remaining.isEmpty, expandedHeight >= compactHeight + 4,
              minimumCaptionWidth >= compactWidth + 8 else {
            throw PluginError.invalid("语音浮条样式包含未知字段或展开尺寸不足。")
        }
    }
}
