import AppKit

/// Five small translucent pools, clipped inside the actual glass. The paths use
/// different frequencies on each axis so the light drifts without a shared loop
/// or a frame-to-frame random jump. No backdrop sampling or blur buffer is needed.
@MainActor final class DictationLiquidBackdrop: NSView {
    private struct Orb {
        let x, y, phase, speed, radius: CGFloat
    }
    private static let orbs: [Orb] = [
        .init(x: 0.16, y: 0.53, phase: 1.1, speed: 1.06, radius: 58),
        .init(x: 0.36, y: 0.34, phase: 3.3, speed: 0.81, radius: 67),
        .init(x: 0.56, y: 0.74, phase: 4.8, speed: 0.67, radius: 72),
        .init(x: 0.79, y: 0.37, phase: 2.4, speed: 1.23, radius: 62),
        .init(x: 0.92, y: 0.71, phase: 5.7, speed: 0.93, radius: 49),
    ]
    private static let defaultGradients = makeGradients(DictationHUDStyle.defaults.poolColors)
    private static func makeGradients(_ colors: [SIMD3<Double>]) -> [CGGradient] {
        colors.map { color in
            CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                       colors: [1.0, 0.72, 0.24, 0].map { CGColor(srgbRed: color.x, green: color.y, blue: color.z, alpha: $0) } as CFArray,
                       locations: [0, 0.27, 0.67, 1])!
        }
    }

    private let style: DictationHUDStyle
    private let gradients: [CGGradient]

    init(style: DictationHUDStyle) {
        self.style = style
        gradients = style.poolColors == DictationHUDStyle.defaults.poolColors
            ? Self.defaultGradients : Self.makeGradients(style.poolColors)
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { nil }

    private(set) var elapsed: TimeInterval = 0
    func sample(at elapsed: TimeInterval) {
        guard elapsed - self.elapsed >= 0.028 else { return }
        self.elapsed = elapsed; needsDisplay = true
    }
    override func setFrameSize(_ newSize: NSSize) {
        let changed = frame.size != newSize
        super.setFrameSize(newSize)
        if changed { needsDisplay = true }
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        Self.draw(in: bounds, elapsed: elapsed, dark: dark, context: context, style: style, gradients: gradients)
    }

    static func draw(in bounds: CGRect, elapsed: TimeInterval, dark: Bool, context: CGContext) {
        draw(in: bounds, elapsed: elapsed, dark: dark, context: context, style: .defaults, gradients: defaultGradients)
    }
    private static func draw(in bounds: CGRect, elapsed: TimeInterval, dark: Bool, context: CGContext,
                             style: DictationHUDStyle, gradients: [CGGradient]) {
        guard bounds.width > 0, bounds.height > 0 else { return }
        let radius = min(bounds.width, bounds.height) / 2
        let t = CGFloat(elapsed * style.driftSpeed), drift = style.driftAmount
        context.saveGState(); defer { context.restoreGState() }
        context.addPath(CGPath(roundedRect: bounds, cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.clip()
        for (orb, gradient) in zip(orbs, gradients) {
            let phase = t * orb.speed + orb.phase
            let x = orb.x + drift * (0.16 * sin(phase) + 0.072 * sin(t * 0.48 - orb.phase))
            let y = orb.y + drift * (0.24 * cos(t * 1.31 * orb.speed - orb.phase) + 0.08 * sin(0.77 * phase))
            let radius = min(orb.radius, bounds.width * 0.56) * (0.94 + 0.06 * sin(0.61 * phase))
            context.saveGState()
            context.setAlpha(style.poolOpacity * (dark ? 0.46 : 0.35) * (0.88 + 0.12 * cos(0.69 * phase)))
            context.translateBy(x: bounds.minX + bounds.width * x, y: bounds.minY + bounds.height * y)
            context.scaleBy(x: radius, y: radius * 0.72)
            context.drawRadialGradient(gradient, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: 1, options: [])
            context.restoreGState()
        }
    }
}
