import AppKit

/// Five small translucent pools, clipped inside the actual glass. The paths use
/// different frequencies on each axis so the light drifts without a shared loop
/// or a frame-to-frame random jump. No backdrop sampling or blur buffer is needed.
@MainActor final class DictationLiquidBackdrop: NSView {
    private struct Orb {
        var x, y, phase, speed, radius: CGFloat
        var tint: SIMD3<Double>
    }
    private static let orbs: [Orb] = [
        .init(x: 0.16, y: 0.53, phase: 1.1, speed: 1.06, radius: 58, tint: .init(0.19, 0.86, 0.76)),
        .init(x: 0.36, y: 0.34, phase: 3.3, speed: 0.81, radius: 67, tint: .init(0.22, 0.52, 1.00)),
        .init(x: 0.56, y: 0.74, phase: 4.8, speed: 0.67, radius: 72, tint: .init(0.62, 0.39, 1.00)),
        .init(x: 0.79, y: 0.37, phase: 2.4, speed: 1.23, radius: 62, tint: .init(0.98, 0.43, 0.72)),
        .init(x: 0.92, y: 0.71, phase: 5.7, speed: 0.93, radius: 49, tint: .init(1.00, 0.70, 0.37))
    ]
    private static let gradients = orbs.map { orb in
        let colour = orb.tint
        return CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [
            CGColor(srgbRed: colour.x, green: colour.y, blue: colour.z, alpha: 1),
            CGColor(srgbRed: colour.x, green: colour.y, blue: colour.z, alpha: 0.72),
            CGColor(srgbRed: colour.x, green: colour.y, blue: colour.z, alpha: 0.24),
            CGColor(srgbRed: colour.x, green: colour.y, blue: colour.z, alpha: 0)
        ] as CFArray, locations: [0, 0.27, 0.67, 1])!
    }
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
        Self.draw(in: bounds, elapsed: elapsed, dark: dark, context: context)
    }

    static func draw(in bounds: CGRect, elapsed: TimeInterval, dark: Bool, context: CGContext) {
        guard bounds.width > 0, bounds.height > 0 else { return }
        let radius = min(bounds.width, bounds.height) / 2
        let t = CGFloat(elapsed)
        context.saveGState(); defer { context.restoreGState() }
        context.addPath(CGPath(roundedRect: bounds, cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.clip()
        for (orb, gradient) in zip(orbs, gradients) {
            let phase = t * orb.speed + orb.phase
            let x = orb.x + 0.16 * sin(phase) + 0.072 * sin(t * 0.48 - orb.phase)
            let y = orb.y + 0.24 * cos(t * 1.31 * orb.speed - orb.phase) + 0.08 * sin(0.77 * phase)
            let radius = min(orb.radius, bounds.width * 0.56) * (0.94 + 0.06 * sin(0.61 * phase))
            context.saveGState()
            context.setAlpha((dark ? 0.46 : 0.35) * (0.88 + 0.12 * cos(0.69 * phase)))
            context.translateBy(x: bounds.minX + bounds.width * x, y: bounds.minY + bounds.height * y)
            context.scaleBy(x: radius, y: radius * 0.72)
            context.drawRadialGradient(gradient, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: 1, options: [])
            context.restoreGState()
        }
    }
}
