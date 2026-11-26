import AppKit
import Combine
import QuartzCore
import SwiftUI

/// One measured envelope drives both the delayed stems and their shared refraction.
struct DictationWaveMotion {
    static let compactWidth: CGFloat = 70, expandedWidth: CGFloat = 238, slotHeight: CGFloat = 30
    private static let diameter: CGFloat = 4, pitch: CGFloat = 7.6
    private static let outerPair = 15, travel = 0.18, staleAfter = 0.28
    struct Bar: Equatable {
        let frame: CGRect
        let position, alpha: CGFloat
    }
    struct Frame: Equatable {
        let bars: [Bar]
        let level, phase: Double // Unit envelope and a wrapping 0…1 phase.
    }
    private struct Segment {
        let time, initial, target: Double
        func level(at t: Double) -> Double {
            let delta = (initial - target) * exp(-max(0, t - time) / (target > initial ? 0.055 : 0.14))
            return abs(delta) < 0.003 ? target : target + delta
        }
    }
    private var segments: [Segment] = []
    private var lastReading: TimeInterval?
    private(set) var reduceMotion = false
    var retainedSegments: Int { segments.count }

    @discardableResult mutating func set(_ reading: DictationMeterReading, at now: TimeInterval, reduceMotion: Bool) -> Bool {
        let modeChanged = reduceMotion != self.reduceMotion
        self.reduceMotion = reduceMotion
        if reduceMotion {
            segments.removeAll(keepingCapacity: true); lastReading = nil
            return modeChanged
        }
        // Preserve the actual falloff if an input resumes after missing callbacks.
        if let tail = staleRelease(at: now) { append(tail) }
        lastReading = now
        let rms = Double(reading.rms)
        let unit = rms.isFinite && rms > 0 ? min(1, max(0, (20 * log10(rms) + 55) / 55)) : 0
        // Lift ordinary speech but retain headroom up to full scale; don't pin loud syllables together.
        let target = unit * (1.4 - 0.4 * unit)
        let previous = segments.last?.target ?? 0
        guard abs(target - previous) >= 0.018 || (target == 0 && previous != 0) else { return modeChanged }
        append(.init(time: now, initial: level(at: now, tail: nil), target: target))
        return true
    }
    private mutating func append(_ segment: Segment) {
        while segments.count >= 2 && segments[1].time <= segment.time - Self.travel { segments.removeFirst() }
        if segments.count >= 24 { segments.removeFirst() }
        segments.append(segment)
    }
    private func staleRelease(at now: TimeInterval) -> Segment? {
        guard let lastReading, let last = segments.last, last.target > 0 else { return nil }
        let expiry = lastReading + Self.staleAfter
        guard now >= expiry else { return nil }
        return .init(time: expiry, initial: last.level(at: expiry), target: 0)
    }
    private func level(at time: TimeInterval, tail: Segment?) -> Double {
        if let tail, time >= tail.time { return tail.level(at: time) }
        for s in segments.reversed() where s.time <= time { return s.level(at: time) }
        return segments.first?.initial ?? 0
    }
    func isMoving(at time: TimeInterval) -> Bool {
        guard !reduceMotion, let last = segments.last else { return false }
        let edge = time - Self.travel
        return edge < last.time || level(at: edge, tail: staleRelease(at: time)) > 0
    }

    func frame(in bounds: CGRect, at time: TimeInterval) -> Frame {
        let width = min(bounds.width, Self.expandedWidth), size = Self.diameter
        guard width >= size && bounds.height >= size else { return Frame(bars: [], level: 0, phase: 0) }
        let room = (width - size) / 2
        let pairs = min(Self.outerPair, Int(room / Self.pitch))
        let radius = max(Self.pitch, min(CGFloat(Self.outerPair) * Self.pitch, room))
        let heightRange = min(bounds.height, Self.slotHeight - 1) - size
        let tail = staleRelease(at: time)
        let phase = time.truncatingRemainder(dividingBy: 4.8) / 4.8
        let angle = 2 * .pi * phase
        var peak = 0.0
        // The fixed x centres read as one wave. Two coherent travelling crests
        // overlap inside the audio envelope, rather than shaking each stem at random.
        let bars: [Bar] = (-pairs...pairs).compactMap { i in
            let x = CGFloat(i) * Self.pitch, position = x / radius, d = abs(position)
            let rim = i == 0 ? 1 : min(1, max(0, (room - abs(x)) / 2.4))
            guard rim > 0 else { return nil }
            let sample = level(at: time - Self.travel * Double(abs(i)) / Double(Self.outerPair), tail: tail)
            peak = max(peak, sample)
            let energy = sample * (1 - 0.86 * d * d)
            let primary = (1 + sin(8 * position - 5 * angle)) / 2
            let secondary = (1 + sin(17 * position + 7 * angle)) / 2
            let height = size + heightRange * energy * (0.57 + 0.31 * primary + 0.12 * secondary)
            let clearance = min(2.2, (bounds.height - height) / 2)
            let drift = clearance * energy * sin(6 * position - 4 * angle)
            return Bar(frame: CGRect(x: bounds.midX + x - size / 2, y: bounds.midY + drift - height / 2,
                                     width: size, height: height), position: position,
                       alpha: (0.81 + 0.10 * (1 - d)) * rim)
        }
        return Frame(bars: bars, level: peak, phase: peak > 0 ? phase : 0)
    }
}

struct DictationWave: NSViewRepresentable {
    let readings: CurrentValueSubject<DictationMeterReading, Never>, reduceMotion: Bool
    @Environment(\.accessibilityReduceTransparency) private var solid
    func makeNSView(context: Context) -> DictationWaveView { DictationWaveView(frame: .zero) }
    func updateNSView(_ view: DictationWaveView, context: Context) { view.bind(readings, reduceMotion: reduceMotion, solid: solid) }
    static func dismantleNSView(_ view: DictationWaveView, coordinator: ()) { view.disconnect() }
}

@MainActor final class DictationWaveView: NSView {
    private var motion = DictationWaveMotion(), clock: Task<Void, Never>?
    private weak var source: CurrentValueSubject<DictationMeterReading, Never>?
    private var subscription: AnyCancellable?
    private var solid = false
    private let now: () -> TimeInterval
    var isAnimating: Bool { clock != nil }

    init(frame: NSRect, now: @escaping () -> TimeInterval = CACurrentMediaTime) {
        self.now = now
        super.init(frame: frame)
    }
    required init?(coder: NSCoder) { nil }
    func bind(_ source: CurrentValueSubject<DictationMeterReading, Never>, reduceMotion: Bool, solid: Bool = false) {
        if self.source !== source { subscription?.cancel(); subscription = nil; self.source = source }
        if self.solid != solid { self.solid = solid; needsDisplay = true }
        if motion.reduceMotion != reduceMotion { set(source.value, reduceMotion: reduceMotion) }
        observeWhileVisible()
    }
    private func observeWhileVisible() {
        guard window != nil, let source, !motion.reduceMotion else { subscription?.cancel(); subscription = nil; return }
        guard subscription == nil else { return }
        // Only this native view observes display readings on the main actor.
        subscription = source.sink { [weak self] in self?.set($0, reduceMotion: false) }
    }
    func set(_ reading: DictationMeterReading, reduceMotion: Bool) {
        let now = now()
        guard motion.set(reading, at: now, reduceMotion: reduceMotion) else { return }
        if reduceMotion { needsDisplay = true }
        updateClock(now)
    }
    private func updateClock(_ now: TimeInterval) {
        guard window != nil, motion.isMoving(at: now) else {
            if clock != nil { stopClock(); needsDisplay = true }; return
        }
        guard clock == nil else { return }
        clock = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(17)) } catch { return }
                guard let self, !Task.isCancelled else { return }
                self.needsDisplay = true
                if self.window == nil || !self.motion.isMoving(at: self.now()) { self.clock = nil; return }
            }
        }
    }
    private func stopClock() { clock?.cancel(); clock = nil }
    func disconnect() { stopClock(); subscription?.cancel(); subscription = nil; source = nil }
    isolated deinit { disconnect() }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); observeWhileVisible(); updateClock(now()) }
    override func setFrameSize(_ newSize: NSSize) {
        let resized = frame.size != newSize
        super.setFrameSize(newSize)
        if resized { needsDisplay = true } // Silent expansion has no audio clock to redraw the new pairs.
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        DictationWaveInk.draw(motion.frame(in: bounds, at: now()), bounds: bounds, dark: dark, solid: solid, in: context)
    }
}

@MainActor private enum DictationWaveInk {
    private typealias RGB = SIMD3<Double>
    private static let light: [RGB] = [.init(0.02, 0.38, 0.44), .init(0.11, 0.34, 0.73), .init(0.29, 0.25, 0.76),
                                       .init(0.50, 0.17, 0.68), .init(0.66, 0.13, 0.42), .init(0.19, 0.37, 0.67)]
    private static let dark: [RGB] = [.init(0.29, 0.96, 0.87), .init(0.40, 0.76, 1), .init(0.60, 0.62, 1),
                                      .init(0.79, 0.54, 1), .init(1, 0.50, 0.81), .init(0.55, 0.81, 1)]
    private static let ice = RGB(0.90, 0.96, 1), shade = RGB(0.14, 0.17, 0.44)
    private static let glassSheen = gradient([
        (shade, 0.14), (shade, 0.04), (ice, 0.02), (ice, 0.34), (ice, 0.24)
    ], at: [0, 0.33, 0.52, 0.86, 1])
    private static let cyanMist = mist(.init(0.26, 0.77, 1), .init(0.28, 0.53, 1))
    private static let lilacMist = mist(.init(0.90, 0.44, 1), .init(0.59, 0.48, 1))

    static func draw(_ wave: DictationWaveMotion.Frame, bounds: CGRect, dark isDark: Bool, solid: Bool, in context: CGContext) {
        guard !wave.bars.isEmpty else { return }
        let stops = isDark ? dark : light
        let angle = wave.phase * 2 * .pi
        let flow = min(1, 2.45 * wave.level)
        if flow > 0 && !solid {
            // The two travelling pools are transparent even at their peak. The native
            // glass and what it transmits are still visible between the stems.
            let alpha = flow * (isDark ? 0.26 : 0.17)
            mist(cyanMist, alpha: alpha, x: -0.16 + 0.17 * sin(2 * angle), y: 1.2 * cos(3 * angle), bounds: bounds, in: context)
            mist(lilacMist, alpha: 0.71 * alpha, x: 0.16 + 0.19 * cos(2 * angle), y: 1.5 * sin(3 * angle), bounds: bounds, in: context)
        }
        let silhouettes = !solid && flow > 0 ? CGMutablePath() : nil
        for bar in wave.bars {
            let u = Double((bar.position + 1) / 2)
            var tint = color(at: 0.13 + 0.46 * u, stops: stops)
            if flow > 0 {
                let moving = color(at: 0.86 * u - 2 * wave.phase + 0.11 * sin(3 * angle + 5 * u), stops: stops)
                tint += (moving - tint) * flow
            }
            let radius = bar.frame.width / 2
            let path = CGPath(roundedRect: bar.frame, cornerWidth: radius, cornerHeight: radius, transform: nil)
            // Keep the coloured core translucent in the clear areas but readable on bright glass.
            context.setFillColor(srgb(tint, alpha: solid ? min(1, bar.alpha * 1.12) : bar.alpha * (1 - 0.08 * flow)))
            context.addPath(path); context.fillPath()
            if bar.alpha >= 0.72 { silhouettes?.addPath(path) }
        }
        // One diagonal reflection over the raised glass, not a separate gradient or effect view per stem.
        guard let silhouettes, !silhouettes.isEmpty else { return }
        context.saveGState()
        context.addPath(silhouettes); context.clip()
        context.setAlpha(flow * (isDark ? 1 : 0.7))
        context.drawLinearGradient(glassSheen,
                                   start: CGPoint(x: bounds.midX, y: bounds.minY + 2.3 * sin(angle)),
                                   end: CGPoint(x: bounds.midX + 0.75 * cos(2 * angle), y: bounds.maxY - 3.0 + 2.3 * sin(angle)),
                                   options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        context.restoreGState()
    }

    private static func color(at position: Double, stops: [RGB]) -> RGB {
        let index = (position - floor(position)) * Double(stops.count)
        let i = min(Int(index), stops.count - 1), next = (i + 1) % stops.count
        return stops[i] + (stops[next] - stops[i]) * (index - Double(i))
    }
    private static func srgb(_ tint: RGB, alpha: CGFloat) -> CGColor {
        CGColor(srgbRed: tint.x, green: tint.y, blue: tint.z, alpha: alpha)
    }
    private static func gradient(_ stops: [(RGB, CGFloat)], at positions: [CGFloat]) -> CGGradient {
        CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                   colors: stops.map { srgb($0.0, alpha: $0.1) } as CFArray, locations: positions)!
    }
    private static func mist(_ core: RGB, _ fringe: RGB) -> CGGradient {
        gradient([(core, 1), (core, 0.66), (fringe, 0.16), (fringe, 0)], at: [0, 0.38, 0.72, 1])
    }
    private static func mist(_ gradient: CGGradient, alpha: CGFloat, x: CGFloat, y: CGFloat, bounds: CGRect, in context: CGContext) {
        context.saveGState()
        context.setAlpha(alpha)
        context.translateBy(x: bounds.midX + x * bounds.width, y: bounds.midY + y)
        // Fade to clear before the edges of the slot, including the narrow capsule.
        context.scaleBy(x: bounds.width * min(0.43, 0.5 - abs(x)), y: bounds.height * 0.44)
        context.drawRadialGradient(gradient, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: 1, options: [])
        context.restoreGState()
    }
}
