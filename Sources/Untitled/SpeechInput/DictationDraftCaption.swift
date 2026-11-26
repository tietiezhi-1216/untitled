import AppKit
import QuartzCore
import SwiftUI

/// Bounded projection for display only. Absolute byte positions distinguish identical
/// repeating tails when the 96-character window slides. Never used for final delivery.
struct DictationCaptionSlice: Equatable {
    let line: String, startByte: Int, positions: [Int]
    var summary: String { startByte > 0 ? "…" + line : line }

    init(_ text: String) {
        var tail: [Character] = [], units = 0, bytes = 0, clipped = false
        for c in text.reversed() {
            let n = c.utf16.count
            if tail.count == 96 || n > 640 - units { clipped = true; break }
            tail.append(c); units += n; bytes += c.utf8.count
        }
        startByte = clipped ? text.utf8.count - bytes : 0
        var pos = startByte, pendingSpace: Int?, result = "", offsets: [Int] = []
        for c in tail.reversed() {
            if c.isWhitespace {
                if pendingSpace == nil && !result.isEmpty { pendingSpace = pos }
            } else {
                if let space = pendingSpace { result.append(" "); offsets.append(space); pendingSpace = nil }
                result.append(c); offsets.append(pos)
            }
            pos += c.utf8.count
        }
        line = result; positions = offsets
    }

    func removedPrefix(from old: Self) -> Int {
        guard startByte > old.startByte, let first = positions.first else { return 0 }
        let n = old.positions.prefix { $0 < first }.count
        // If the service revised the middle as well, use the ordinary grapheme diff instead.
        return n > 0 && line.hasPrefix(old.line.dropFirst(n)) ? n : 0
    }
}

/// Presentation state for the HUD's short visible tail, never the source for delivery or history.
/// Match whole Characters, including when ASR edits the middle or the preview scrolls left.
struct DictationDraftReveal {
    static let duration = 0.48, stagger = 0.085, minimumStep = 0.045
    struct Cell { let character: Character; var start: TimeInterval? }
    private(set) var cells: [Cell] = []
    var deadline: TimeInterval? { cells.compactMap(\.start).max().map { $0 + Self.duration } }

    struct Edit {
        let next: [Character], oldIndex: [Int?]
    }
    func edit(to preview: String, discarding prefix: Int = 0) -> Edit {
        let next = Array(preview), source = cells.indices.dropFirst(prefix)
        let diff = next.difference(from: source.map { cells[$0].character })
        var removed = IndexSet(), added = IndexSet()
        for change in diff {
            switch change {
            case .remove(let i, _, _): removed.insert(i)
            case .insert(let i, _, _): added.insert(i)
            }
        }
        var retained = source.enumerated().compactMap { removed.contains($0.offset) ? nil : $0.element }.makeIterator()
        return Edit(next: next, oldIndex: next.indices.map { added.contains($0) ? nil : retained.next() })
    }
    mutating func replace(with preview: String, at now: TimeInterval, reduceMotion: Bool, firstVisibleUTF16: Int = 0) {
        apply(edit(to: preview), at: now, reduceMotion: reduceMotion, firstVisibleUTF16: firstVisibleUTF16)
    }
    mutating func apply(_ edit: Edit, at now: TimeInterval, reduceMotion: Bool, firstVisibleUTF16: Int) {
        if reduceMotion { cells = edit.next.map { Cell(character: $0, start: nil) }; return }
        var nextCells: [Cell] = [], waiting: [Int] = [], offset = 0
        var latestBegun: TimeInterval?
        for (i, character) in edit.next.enumerated() {
            let previous = edit.oldIndex[i]
            var start = previous.flatMap { cells[$0].start }
            offset += character.utf16.count
            if offset <= firstVisibleUTF16 || character.isWhitespace {
                start = nil // Offscreen prefix and spaces do not consume reveal slots.
            } else if previous == nil || (start.map { $0 > now } ?? false) {
                waiting.append(i) // Only characters that have not appeared may be re-timed.
            } else if let t = start {
                if now >= t + Self.duration { start = nil }
                else { latestBegun = max(latestBegun ?? t, t) }
            }
            nextCells.append(.init(character: character, start: start))
        }
        // Real slots, not a capped delay shared by the tail of a packet. A rapid append
        // joins the unfinished sequence; a superseded draft never becomes an animation queue.
        let step = max(Self.minimumStep, min(Self.stagger, 1.1 / Double(max(1, waiting.count - 1))))
        var slot = max(now, latestBegun.map { $0 + step } ?? now)
        for index in waiting {
            nextCells[index].start = slot; slot += step
        }
        cells = nextCells
    }
    static func opacity(start: TimeInterval?, at now: TimeInterval) -> CGFloat {
        guard let start else { return 1 }
        let t = min(1, max(0, (now - start) / duration))
        return t * t * (3 - 2 * t)
    }
}

struct DictationDraftCaption: NSViewRepresentable {
    let slice: DictationCaptionSlice
    let reduceMotion: Bool, layoutWidth: CGFloat
    func makeNSView(context: Context) -> DictationCaptionView { DictationCaptionView(frame: .zero) }
    func updateNSView(_ view: DictationCaptionView, context: Context) { view.display(slice, reduceMotion: reduceMotion, layoutWidth: layoutWidth) }
    static func dismantleNSView(_ view: DictationCaptionView, coordinator: ()) { view.stop() }
}

/// A finite translation between two presentations of the *current* hypothesis, not a
/// repeating marquee. New input samples the in-flight position; no animations are enqueued.
private struct CaptionTravel {
    var from: CGFloat = 0, to: CGFloat = 0
    var begin: TimeInterval = 0, end: TimeInterval = 0
    func x(at t: TimeInterval) -> CGFloat {
        guard t < end, end > begin else { return to }
        let u = max(0, (t - begin) / (end - begin))
        return to + (from - to) * (1 - u) * (1 - u)
    }
}

/// Shape the bounded tail once in a single unwrapped TextKit line. Reveal and translation
/// share a short-lived clock; neither advances recognition, the outer window or final delivery.
@MainActor final class DictationCaptionView: NSView {
    private let storage = NSTextStorage(), manager = NSLayoutManager()
    private let container = NSTextContainer(size: NSSize(width: 65_536, height: 256))
    private let paragraph = NSMutableParagraphStyle()
    private static let leftFade = CGGradient(colorSpace: CGColorSpaceCreateDeviceGray(),
                                             colorComponents: [0, 0, 0, 1], locations: [0, 1], count: 2)!
    private var reveal = DictationDraftReveal(), starts: [TimeInterval?] = []
    private var slice = DictationCaptionSlice(""), travel = CaptionTravel()
    private var anchors: [CGFloat] = [], used = CGRect.zero
    private var deadline: TimeInterval = 0
    private var reduceMotion = false, lastWidth: CGFloat = -1
    private var frameTask: Task<Void, Never>?
    private let now: () -> TimeInterval
    var isAnimating: Bool { frameTask != nil }
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override convenience init(frame: NSRect) { self.init(frame: frame, now: CACurrentMediaTime) }
    init(frame: NSRect, now: @escaping () -> TimeInterval) {
        self.now = now; super.init(frame: frame)
        container.lineFragmentPadding = 0; container.maximumNumberOfLines = 1
        manager.addTextContainer(container); storage.addLayoutManager(manager)
        paragraph.alignment = .left; paragraph.lineBreakMode = .byClipping
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { nil }
    isolated deinit { stop() }

    private func shape(_ line: String) {
        storage.setAttributedString(NSAttributedString(string: line, attributes: [
            .font: NSFont.systemFont(ofSize: 15.5, weight: .medium), .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph, .ligature: 0
        ]))
        manager.ensureLayout(for: container); used = manager.usedRect(for: container)
        var utf16 = 0
        anchors = line.map { c in
            defer { utf16 += c.utf16.count }
            return manager.location(forGlyphAt: manager.glyphIndexForCharacter(at: utf16)).x
        }
    }

    func display(_ next: DictationCaptionSlice, reduceMotion: Bool, layoutWidth: CGFloat? = nil) {
        let width = max(1, layoutWidth ?? bounds.width), t = now()
        guard next != slice || reduceMotion != self.reduceMotion || width != lastWidth else { return }
        let edit = reveal.edit(to: next.line, discarding: next.removedPrefix(from: slice))
        let oldX = travel.x(at: t), oldAnchors = anchors
        if next.line != slice.line { shape(next.line) }
        let room = width - ceil(used.width)
        let target = (room >= 0 ? room / 2 : room) - used.minX
        // An oversized first packet also glides; limit catch-up to one viewport.
        // Discard obsolete offscreen content instead of replaying arbitrarily long hypotheses.
        var from = !reduceMotion && room < 0 && oldAnchors.isEmpty ? min(-used.minX, target + width) : target
        if !reduceMotion {
            // Pin a retained visible glyph to its *screen* x, including when the prefix
            // was evicted or revised. Matching just the total width fails on fixed-length tails.
            for i in edit.next.indices.reversed() {
                guard let j = edit.oldIndex[i], oldAnchors.indices.contains(j),
                      (reveal.cells[j].start ?? t) <= t else { continue }
                let screenX = oldX + oldAnchors[j]
                if screenX >= -1 && screenX < lastWidth {
                    from = min(target + width, max(target - width, screenX - anchors[i])); break
                }
            }
        }
        // Only schedule glyphs in the union of the starting and ending viewports.
        // A first large packet opens on its readable tail, not a screenful of invisible backlog.
        var first = 0
        let left = -max(from,target)
        if left > 0 && manager.numberOfGlyphs > 0 {
            let glyph = manager.glyphIndex(for: NSPoint(x: left, y: used.midY), in: container)
            first = manager.characterIndexForGlyph(at: min(glyph,manager.numberOfGlyphs - 1))
        }
        reveal.apply(edit, at: t, reduceMotion: reduceMotion, firstVisibleUTF16: first)
        starts = reveal.cells.flatMap { Array(repeating: $0.start, count: $0.character.utf16.count) }
        let fadeEnd = reveal.deadline ?? t
        var begin = t
        if from > target+1, travel.end <= t, manager.numberOfGlyphs > 0 {
            // Let a large batch fill the current line before scrolling towards letters
            // which are still transparent. A scroll already in flight is never held up.
            let g = manager.glyphIndex(for: NSPoint(x: width-from+0.5, y: used.midY), in: container)
            let offset = manager.characterIndexForGlyph(at: min(g, manager.numberOfGlyphs-1))
            if starts.indices.contains(offset), let incoming = starts[offset] { begin = max(t, incoming - 0.09) }
        }
        let duration = abs(from-target) < 0.25 ? 0 : min(1.05, max(0.22, fadeEnd - DictationDraftReveal.duration - begin + 0.20))
        travel = .init(from: from, to: target, begin: begin, end: begin + duration)
        deadline = max(travel.end, fadeEnd)
        slice = next; lastWidth = width; self.reduceMotion = reduceMotion
        needsDisplay = true; updateClock()
    }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); updateClock() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
    func stop() { frameTask?.cancel(); frameTask = nil }
    private func updateClock() {
        guard window != nil, !reduceMotion, deadline > now() else { stop(); return }
        guard frameTask == nil else { return }
        frameTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(20)) } catch { return }
                guard let self, !Task.isCancelled else { return }
                self.needsDisplay = true
                if self.window == nil || self.deadline <= self.now() { self.frameTask = nil; return }
            }
        }
    }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard !slice.line.isEmpty, let cg = NSGraphicsContext.current?.cgContext else { return }
        let t = now()
        let origin = NSPoint(x: travel.x(at: t), y: ((bounds.height - used.height) / 2).rounded() - used.minY)
        let visible = bounds.offsetBy(dx: -origin.x, dy: -origin.y).insetBy(dx: -2, dy: -2)
        let glyphs = manager.glyphRange(forBoundingRect: visible, in: container), end = NSMaxRange(glyphs)
        cg.saveGState(); defer { cg.restoreGState() }; cg.clip(to: bounds)
        // Soften only outgoing ink, not the glass or the new glyph at the right edge.
        let fade = min(9, max(0, -origin.x - used.minX))
        if fade > 0.5 { cg.beginTransparencyLayer(in: bounds, auxiliaryInfo: nil) }
        func alpha(_ glyph: Int) -> CGFloat {
            let offset = manager.characterIndexForGlyph(at: glyph)
            return DictationDraftReveal.opacity(start: starts.indices.contains(offset) ? starts[offset] : nil, at: t)
        }
        var start = glyphs.location
        while start < end {
            let opacity = alpha(start)
            var next = start + 1
            while next < end, alpha(next) == opacity { next += 1 }
            if opacity > 0 {
                cg.setAlpha(opacity)
                manager.drawGlyphs(forGlyphRange: NSRange(location: start, length: next - start), at: origin)
            }
            start = next
        }
        if fade > 0.5 {
            cg.saveGState(); cg.setAlpha(1); cg.setBlendMode(.destinationIn)
            cg.drawLinearGradient(Self.leftFade, start: .zero, end: CGPoint(x: fade,y: 0), options: .drawsAfterEndLocation)
            cg.restoreGState(); cg.endTransparencyLayer()
        }
    }
}
