import AppKit
import Combine
import Testing
@testable import Untitled

@Suite(.serialized) struct DictationHUDStyleTests {
    @Test func eachGraphemeHasItsOwnOnsetAcrossPacketsAndVisibleTextNeverRefades() throws {
        var reveal = DictationDraftReveal()
        let first = "下午三点见面一起出发好吗"
        reveal.replace(with: first, at: 10, reduceMotion: false)
        let starts = reveal.cells.compactMap(\.start)
        #expect(starts.count == first.count && Set(starts).count == starts.count)
        for (a,b) in zip(starts,starts.dropFirst()) { #expect(b-a >= DictationDraftReveal.minimumStep - 1e-8) }
        #expect(DictationDraftReveal.opacity(start: starts[6], at: starts[5]) == 0)
        #expect(DictationDraftReveal.opacity(start: starts[0], at: starts[0] + 0.19) < 0.55)
        #expect(DictationDraftReveal.opacity(start: starts[0], at: starts[0] + 0.35) > 0.75)
        reveal.replace(with: first + "🍎👨‍👩‍👧‍👦", at: 10.18, reduceMotion: false)
        #expect(reveal.cells.prefix(3).compactMap(\.start) == Array(starts.prefix(3)))
        let tail = reveal.cells.suffix(3).compactMap(\.start)
        #expect(tail.count == 3 && tail[2] > tail[1] && tail[1] > tail[0])
        // Replace a word after the neighbours are fully visible. They stay opaque.
        reveal.replace(with: "下午四点见面一起出发好吗🍎👨‍👩‍👧‍👦", at: 13, reduceMotion: false)
        #expect(reveal.cells[2].character == "四" && reveal.cells[2].start == 13)
        #expect(reveal.cells.enumerated().filter { $0.offset != 2 }.allSatisfy { $0.element.start == nil })
        reveal.replace(with: "下午四点见面", at: 13.2, reduceMotion: false)
        #expect(reveal.cells[2].start == 13 && reveal.cells[3].start == nil)
    }

    @Test func invisibleLinesSpacesAndObsoleteRevisionsNeverHoldUpTheVisibleTail() {
        let hidden = String(repeating: "😀", count: 55)
        var r = DictationDraftReveal()
        let text = hidden + "这是 👨‍👩‍👦 新的一段文字"
        r.replace(with: text, at: 20, reduceMotion: false, firstVisibleUTF16: hidden.utf16.count)
        #expect(r.cells.prefix(55).allSatisfy { $0.start == nil })
        #expect(r.cells[55].start == 20 && r.cells.filter { $0.character.isWhitespace }.allSatisfy { $0.start == nil })
        for i in 0..<160 {
            r.replace(with: "修订内容👨‍👩‍👦" + String(i), at: 20.01 + Double(i) * 0.002, reduceMotion: false)
        }
        #expect(r.cells.map(\.character) == Array("修订内容👨‍👩‍👦159") && (r.deadline ?? 0) < 21.5)
        r.replace(with: text, at: 20.4, reduceMotion: true)
        #expect(r.deadline == nil && r.cells.allSatisfy { $0.start == nil })
    }

    @Test func aSlidingPreviewOrRapidRevisionDoesNotFlashTheWholeBubble() throws {
        let earlier = (0..<122).compactMap { UnicodeScalar(0x4e00 + $0).map(Character.init) }
        var reveal = DictationDraftReveal()
        reveal.replace(with: DictationHUD.preview(for: String(earlier)), at: 20, reduceMotion: false)
        let next = DictationHUD.preview(for: String(earlier) + "🍎👨‍👩‍👧‍👦")
        reveal.replace(with: next, at: 26, reduceMotion: false)
        #expect(reveal.cells.count == 97 && reveal.cells.first?.character == "…")
        #expect(reveal.cells.dropLast(2).allSatisfy { $0.start == nil })
        #expect(reveal.cells.suffix(2).map(\.character) == Array("🍎👨‍👩‍👧‍👦"))
        #expect(reveal.cells.suffix(2).allSatisfy { ($0.start ?? 0) >= 26 })
        #expect((try #require(reveal.deadline)) < 26.61)
        reveal.replace(with: next + "。", at: 26.04, reduceMotion: true)
        #expect(reveal.deadline == nil)
        let pathological = "a" + String(repeating: "\u{301}", count: 2048)
        #expect(DictationHUD.preview(for: pathological + "正常") == "…正常")
    }

    @Test @MainActor func centresOnTheInvocationDisplayIncludingNegativeOrigins() {
        for display in [NSRect(x: -1440, y: -300, width: 1440, height: 900), NSRect(x: 1728, y: 150, width: 370, height: 640)] {
            let small = DictationHUD.frame(on: display, expanded: false), large = DictationHUD.frame(on: display, expanded: true)
            #expect(abs(small.midX - display.midX) <= 0.5 && abs(large.midX - display.midX) <= 0.5)
            #expect(small.minY == large.minY && display.contains(large) && large.width <= display.width - 32)
        }
    }

    @Test @MainActor func systemGlassAndOpaqueFallbackContainTheActualContent() {
        _ = NSApplication.shared
        let rect = NSRect(origin: .zero, size: DictationHUD.expanded), ink = NSView(frame: rect)
        let native = DictationHUDPlate.make(in: rect, content: ink, reduceTransparency: false)
        if #available(macOS 26, *) {
            #expect((native as? NSGlassEffectView)?.contentView === ink)
        } else { #expect((native as? NSVisualEffectView)?.blendingMode == .behindWindow) }
        ink.removeFromSuperview()
        let solid = DictationHUDPlate.make(in: rect, content: ink, reduceTransparency: true)
        #expect(ink.superview === solid && !(solid is NSVisualEffectView))
        if #available(macOS 26, *) { #expect(!(solid is NSGlassEffectView)) }
    }

    @Test(arguments: [DictationWaveMotion.compactWidth, DictationWaveMotion.expandedWidth])
    @MainActor func quietWaveRendersAReadableColourSweepInLightAndDarkGlass(width: CGFloat) throws {
        _ = NSApplication.shared
        let rect = NSRect(x: 0, y: 0, width: width, height: DictationWaveMotion.slotHeight)
        let window = NSWindow(contentRect: rect, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; defer { window.close() }
        let wave = DictationWaveView(frame: rect)
        window.contentView = wave
        let stems = DictationWaveMotion().frame(in: rect, at: 0).bars
        func luminance(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) -> CGFloat {
            func linear(_ v: CGFloat) -> CGFloat { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
            return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
        }
        func ink(_ appearance: NSAppearance.Name, over gray: CGFloat) throws -> CGFloat {
            window.appearance = NSAppearance(named: appearance); wave.needsDisplay = true
            let bitmap = try #require(wave.bitmapImageRepForCachingDisplay(in: wave.bounds))
            wave.cacheDisplay(in: wave.bounds, to: bitmap)
            let samples = try stems.map { stem in
                let x = Int(stem.frame.midX * CGFloat(bitmap.pixelsWide) / width)
                return try #require(bitmap.colorAt(x: x, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.sRGB))
            }
            let cyan = try #require(samples.first), pink = try #require(samples.last), blue = samples[samples.count / 2]
            #expect(cyan.greenComponent > cyan.redComponent + 0.2 && cyan.blueComponent > cyan.redComponent + 0.2)
            #expect(blue.blueComponent > max(blue.redComponent, blue.greenComponent) + 0.2)
            #expect(pink.redComponent > pink.greenComponent + 0.2 && pink.blueComponent > pink.greenComponent + 0.15)
            // Check the visible colour of the dots over a representative glass tone,
            // not just the palette's uncomposited RGB values.
            let background = luminance(gray, gray, gray)
            for sample in samples {
                func blend(_ v: CGFloat) -> CGFloat { gray + (v - gray) * sample.alphaComponent }
                let foreground = luminance(blend(sample.redComponent), blend(sample.greenComponent), blend(sample.blueComponent))
                #expect((max(background, foreground) + 0.05) / (min(background, foreground) + 0.05) >= 3)
            }
            return blue.blueComponent
        }
        let day = try ink(.aqua, over: 0.91), night = try ink(.darkAqua, over: 0.16)
        #expect(night > day + 0.15 && !wave.isAnimating)
    }

    @Test func expandedPausesKeepBothEndsOfTheRowVisibleWithoutAClock() throws {
        let bounds = CGRect(x: 0, y: 0, width: 238, height: DictationWaveMotion.slotHeight)
        var m = DictationWaveMotion()
        let rest = m.frame(in: bounds, at: 1), dots = rest.bars
        try #require(dots.count == 31)
        #expect(rest.level == 0 && dots.allSatisfy { $0.frame.width == $0.frame.height && $0.frame.midY == bounds.midY && $0.alpha >= 0.75 })
        #expect(dots[0].frame.minX < 5 && dots[30].frame.maxX > bounds.width - 5)
        #expect(zip(dots,dots.dropFirst()).allSatisfy { $0.frame.maxX + 3 < $1.frame.minX })
        for i in 0..<60 { m.set(.init(rms: 0.001), at: Double(i) * 0.04, reduceMotion: false) }
        #expect(!m.isMoving(at: 3) && m.frame(in: bounds, at: 3) == rest)
        m.set(.init(rms: 0.13), at: 4, reduceMotion: false)
        let onset = m.frame(in: bounds, at: 4.05)
        try #require(onset.bars.map(\.frame.midX) == dots.map(\.frame.midX))
        #expect(onset.level > 0.4 && onset.bars[15].frame.height > 8 && onset.bars[0] == dots[0] && onset.bars[30] == dots[30])
        m.set(.quiet, at: 4.19, reduceMotion: false)
        #expect(m.frame(in: bounds, at: 4.25).bars.count == 31 && m.isMoving(at: 4.25))
        #expect(m.frame(in: bounds, at: 6) == rest && !m.isMoving(at: 6))
        for i in 0..<400 { m.set(.init(rms: i.isMultiple(of: 2) ? 0.02 : 0.1), at: 12+Double(i)/1000, reduceMotion: false) }
        #expect(m.retainedSegments <= 24)
        m.set(.init(rms: .nan), at: 13, reduceMotion: true)
        #expect(m.frame(in: bounds, at: 13) == rest && !m.isMoving(at: 13))
    }

    @Test func steadyAudioStillMovesWithinTheSlotAndMissingSamplesFallBackToQuiet() throws {
        let bounds = CGRect(x: 10, y: 5, width: 238, height: DictationWaveMotion.slotHeight)
        var m = DictationWaveMotion()
        let reading = DictationMeterReading(rms: 1)
        var heights: [CGFloat] = []
        for i in 0...60 {
            let t = 3 + 0.04 * Double(i)
            m.set(reading, at: t, reduceMotion: false)
            let frame = m.frame(in: bounds, at: t)
            try #require(frame.bars.count == 31 && frame.bars.allSatisfy { bounds.contains($0.frame) })
            if i > 24 {
                #expect(m.isMoving(at: t) && frame.level > 0.99)
                heights.append(frame.bars[15].frame.height)
            }
        }
        let tallest = try #require(heights.max()), shortest = try #require(heights.min())
        #expect(tallest > 26 && tallest < bounds.height && tallest - shortest > 7)
        let fading = m.frame(in: bounds, at: 5.9)
        #expect(fading.level > 0 && fading.level < 0.95)
        m.set(reading, at: 5.9, reduceMotion: false)
        #expect(m.frame(in: bounds, at: 5.9) == fading) // Resume from the curve, no jump.
        #expect(!m.isMoving(at: 7.5) && m.frame(in: bounds, at: 7.5) == DictationWaveMotion().frame(in: bounds, at: 0))
    }

    @Test(arguments: [false, true]) @MainActor func fixedVolumeRendersMovingColourAndOnlyGlassTransmitsTheMist(solid: Bool) throws {
        _ = NSApplication.shared
        let rect = CGRect(x: 0, y: 0, width: DictationWaveMotion.expandedWidth, height: DictationWaveMotion.slotHeight)
        var now = 2.0
        let wave = DictationWaveView(frame: rect, now: { now })
        wave.appearance = NSAppearance(named: .darkAqua)
        let window = NSWindow(contentRect: rect, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; defer { window.close() }
        window.contentView = wave
        let reading = CurrentValueSubject<DictationMeterReading, Never>(.quiet)
        wave.bind(reading, reduceMotion: false, solid: solid)
        let stops = DictationWaveMotion().frame(in: rect, at: now).bars.map(\.frame.midX)
        func pixels() throws -> (colors: [NSColor], gapAlpha: CGFloat) {
            wave.needsDisplay = true
            let bitmap = try #require(wave.bitmapImageRepForCachingDisplay(in: rect))
            wave.cacheDisplay(in: rect, to: bitmap)
            func ink(_ x: CGFloat) throws -> NSColor {
                let column = Int(x * CGFloat(bitmap.pixelsWide) / rect.width)
                return try #require(bitmap.colorAt(x: column, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.sRGB))
            }
            return (try stops.map(ink), try ink((stops[15] + stops[16]) / 2).alphaComponent)
        }
        for i in 0...30 {
            now = 2 + Double(i) * 0.04
            reading.send(.init(rms: 0.085))
        }
        let early = try pixels(), shape = early.colors.map(\.alphaComponent)
        for i in 31...40 {
            now = 2 + Double(i) * 0.04
            reading.send(.init(rms: 0.085))
        }
        let late = try pixels()
        let recoloured = zip(early.colors, late.colors).filter { a, b in
            abs(a.redComponent - b.redComponent) + abs(a.greenComponent - b.greenComponent) > 0.2
        }
        #expect(wave.isAnimating && recoloured.count > 10 && shape.allSatisfy { $0 > 0.58 })
        if solid {
            #expect(early.gapAlpha < 0.02 && late.gapAlpha < 0.02)
        } else {
            #expect((0.06...0.44).contains(early.gapAlpha) && (0.06...0.44).contains(late.gapAlpha))
        }
        wave.bind(reading, reduceMotion: true, solid: solid)
        let quiet = try pixels().colors
        now += 0.5
        let settled = try pixels().colors
        #expect(!wave.isAnimating && settled == quiet)
        window.contentView = nil
        #expect(!wave.isAnimating)
    }

    @Test func aMeasuredPulseReachesAnOuterPairLaterAndLower() throws {
        let r = CGRect(x: 0, y: 0, width: 238, height: DictationWaveMotion.slotHeight)
        var m = DictationWaveMotion()
        m.set(.init(rms: 0.20), at: 1, reduceMotion: false); m.set(.quiet, at: 1.10, reduceMotion: false)
        func bar(_ pair: Int, _ t: Double) -> CGRect? {
            m.frame(in: r, at: t).bars.map(\.frame).first { abs($0.midX - (r.midX + 7.6 * Double(pair))) < 0.1 }
        }
        let center = try #require(bar(0,1.10))
        let waiting = try #require(bar(9,1.10))
        #expect(waiting.height == waiting.width)
        let later = try #require(bar(9,1.245)), decaying = try #require(bar(0,1.245))
        #expect(later.midX == waiting.midX && later.height > waiting.height)
        #expect(later.height < center.height && later.height > decaying.height)
    }

    @Test func compactAndExpandedStemsShareFixedPositionsAndVolumeControlsTheirHeight() {
        func bars(_ rms: Float,_ w: CGFloat) -> [CGRect] {
            var m = DictationWaveMotion()
            for i in 0...25 { m.set(.init(rms: rms), at: 1 + Double(i) * 0.04, reduceMotion: false) }
            return m.frame(in: CGRect(x: -w/2, y: 0, width: w, height: DictationWaveMotion.slotHeight), at: 2).bars.map(\.frame)
        }
        let small = bars(0,70), large = bars(0,238)
        #expect(small.count == 9 && large.count == 31)
        #expect(small.map(\.midX) == large.filter { abs($0.midX) < 32 }.map(\.midX))
        var oldCentres: Set<CGFloat> = []
        for width in stride(from: CGFloat(70), through: 238, by: 2) {
            let quiet = bars(0,width), loud = bars(0.2,width)
            let centres = Set(quiet.map(\.midX))
            #expect(oldCentres.isSubset(of: centres) && quiet.map(\.midX) == loud.map(\.midX))
            oldCentres = centres
        }
        for width in [DictationWaveMotion.compactWidth, DictationWaveMotion.expandedWidth] {
            let heights = [0.0126, 0.05, 0.25, 0.98].map { rms in bars(Float(rms),width).map(\.height).max() ?? 0 }
            #expect(heights[0] > 10 && heights[1] > heights[0]+4 && heights[2] > heights[1]+4)
            #expect(heights[3] > heights[2]+2 && heights[3] < DictationWaveMotion.slotHeight)
        }
    }

    @Test @MainActor func expansionIsMonotoneAnchoredInterruptibleAndHonoursReducedMotion() async throws {
        let s = DictationHUDStage(size: DictationHUD.expanded, content: NSView())
        s.configure(reduceMotion: false, solid: true)
        let plate = try #require(s.plate)
        #expect(plate.frame.size == DictationHUD.compact)
        s.expand()
        var last = plate.frame.width, sampledIntermediate = false
        let end = ContinuousClock.now.advanced(by: .seconds(2))
        while s.openness < 1 && ContinuousClock.now < end {
            try await Task.sleep(for: .milliseconds(20))
            s.expand() // further preview callbacks cannot restart the transition
            let r = plate.frame
            #expect(r.width >= last && abs(r.midX - s.bounds.midX) < 0.01 && r.minY == 0)
            if s.openness > 0 && s.openness < 1 { sampledIntermediate = true }
            last = r.width
        }
        #expect(sampledIntermediate && plate.frame.size == DictationHUD.expanded)
        let reduced = DictationHUDStage(size: DictationHUD.expanded, content: NSView())
        reduced.configure(reduceMotion: true, solid: true); reduced.expand()
        #expect(reduced.openness == 1 && reduced.plate?.frame.size == DictationHUD.expanded)
        let cancelled = DictationHUDStage(size: DictationHUD.expanded, content: NSView())
        cancelled.configure(reduceMotion: false, solid: true); cancelled.expand(); cancelled.stop()
        try await Task.sleep(for: .milliseconds(45)); #expect(cancelled.openness == 0)
    }

    @Test @MainActor func aQuietOrDetachedWaveDoesNotKeepAClockRunning() {
        _ = NSApplication.shared
        let rect = NSRect(x: 0, y: 0, width: DictationWaveMotion.expandedWidth, height: DictationWaveMotion.slotHeight)
        let w = NSWindow(contentRect: rect, styleMask: [.borderless], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false; defer { w.close() }
        let v = DictationWaveView(frame: rect); w.contentView = v
        v.set(.init(rms: 0.001), reduceMotion: false); #expect(!v.isAnimating)
        v.set(.init(rms: 0.02), reduceMotion: false); #expect(v.isAnimating)
        v.set(.init(rms: 0.02), reduceMotion: true); #expect(!v.isAnimating)
        v.set(.init(rms: 0.02), reduceMotion: false); #expect(v.isAnimating)
        w.contentView = nil; #expect(!v.isAnimating)
    }

    @Test @MainActor func theLatestGlyphsStayOnOneUncutLineWithNaturalWidths() throws {
        _ = NSApplication.shared
        let width = DictationHUD.captionWidth(in: DictationHUD.expanded.width)
        let rect = NSRect(x: 0,y: 0,width: width,height: DictationHUD.captionHeight)
        let view = DictationCaptionView(frame: rect); view.appearance = NSAppearance(named: .aqua)
        for text in ["🟥", "明天 上午 9 点去展览馆，🟥", String(repeating:"晨",count:19)+"🟥",
                     String(repeating:"沿河岸 café 👨‍👩‍👦\n",count:180)+"🟥"] {
            view.display(text, reduceMotion: true)
            let sample = try view.tickerInk(), marker = try #require(sample.redX)
            #expect(sample.box.height <= 20 && sample.box.minY >= 1 && sample.box.maxY < rect.height)
            if text == "🟥" { #expect(abs(marker - width/2) < 2) }
            if text.count > 19 { #expect(marker > width-17 && marker < width-3) }
            #expect(!view.isAnimating)
        }
        let slice = DictationCaptionSlice("  月\t  亮\n出来了  ")
        #expect(slice.line == "月 亮 出来了" && slice.summary == slice.line)
    }

    @Test @MainActor func actualOverflowMovesRetainedInkLeftThenHoldsAndCanBeRetargeted() throws {
        _ = NSApplication.shared
        var t = 20.0
        let width = DictationHUD.captionWidth(in: DictationHUD.expanded.width)
        let view = DictationCaptionView(frame: NSRect(x:0,y:0,width:width,height:DictationHUD.captionHeight), now: { t })
        view.appearance = NSAppearance(named: .aqua)
        func x() throws -> CGFloat { let ink = try view.tickerInk(); return try #require(ink.redX) }
        // The source window already rolls at 96 characters. The red marker is a
        // retained composite colour glyph, not a proxy for an internal scroll offset.
        let text = String(repeating:"晨",count:130) + "🟥" + String(repeating:"光",count:9)
        view.display(text, reduceMotion:true); let before = try x()
        view.display(text+"河岸",reduceMotion:false)
        #expect(abs(try x()-before) <= 1)
        t += 0.055; let early = try x()
        t += 0.055; let middle = try x()
        #expect(before > early+1 && early > middle+1)
        view.display(text+"河岸边",reduceMotion:false)
        #expect(abs(try x()-middle) <= 1)
        t += 1.8; let settled = try x()
        #expect(settled < middle-3 && (43...50).contains(before-settled))
        t += 90; #expect(abs(try x()-settled) < 0.1)
        view.display("🟥",reduceMotion:true); #expect(abs(try x()-width/2) < 2)
    }

    @Test @MainActor func aLongFirstPacketFillsOneLineThenSlidesWithoutAnotherCallback() throws {
        _ = NSApplication.shared
        var t = 12.0
        let view = DictationCaptionView(frame:NSRect(x:0,y:0,width:278,height:23),now:{ t })
        view.appearance=NSAppearance(named:.aqua)
        view.display(String(repeating:"晨",count:9)+"🟥"+String(repeating:"光",count:13),reduceMotion:false)
        t += 0.78; let early = try #require(view.tickerInk().redX)
        t += 1.5; let held = try #require(view.tickerInk().redX)
        #expect(early > held+30 && held > 20)
        t += 30; #expect(abs(try #require(view.tickerInk().redX)-held) < 0.1)
    }

    @Test func repeatedIdenticalSlidingTailsStillAddANewGraphemeWithoutRefadingNeighbours() {
        let old = DictationCaptionSlice(String(repeating:"晨",count:130)), next = DictationCaptionSlice(String(repeating:"晨",count:131))
        #expect(old.line == next.line && old != next && next.removedPrefix(from:old) == 1)
        var r = DictationDraftReveal()
        r.replace(with:old.line,at:0,reduceMotion:true)
        let edit = r.edit(to:next.line,discarding:next.removedPrefix(from:old))
        r.apply(edit,at:4,reduceMotion:false,firstVisibleUTF16:75)
        #expect(r.cells.count == 96 && r.cells.dropLast().allSatisfy { $0.start == nil } && r.cells.last?.start == 4)
        let cluster = String(repeating:"晨",count:95) + "👨‍👩‍👧‍👦"
        let older = DictationCaptionSlice(cluster), newer = DictationCaptionSlice(cluster+"月")
        #expect(newer.line.count == 96 && newer.removedPrefix(from:older) == 1 && newer.line.hasSuffix("👨‍👩‍👧‍👦月"))
    }

    @Test @MainActor func actualCaptionPixelsStartOneGraphemeAtATimeEvenFromTheSamePacket() throws {
        _ = NSApplication.shared
        var t = 50.0
        let rect = NSRect(x: 0,y: 0,width: DictationHUD.captionWidth(in: DictationHUD.expanded.width),
                          height: DictationHUD.captionHeight)
        let view = DictationCaptionView(frame: rect, now: { t })
        let window = NSWindow(contentRect: rect, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; defer { window.close() }
        window.contentView = view; window.appearance = NSAppearance(named: .aqua)
        view.display(String(repeating: "田", count: 12), reduceMotion: false)
        func imageColumns() throws -> [CGFloat] {
            view.needsDisplay = true
            let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: rep)
            return (0..<rep.pixelsWide).map { x in (0..<rep.pixelsHigh).reduce(0) { $0 + (rep.colorAt(x: x,y: $1)?.alphaComponent ?? 0) } }
        }
        t = 52; let full = try imageColumns()
        let x0 = try #require(full.firstIndex(where: { $0 > 0.2 })), x1 = try #require(full.lastIndex(where: { $0 > 0.2 }))
        let stride = Double(x1-x0+1)/12
        let centers = (0..<12).map { x0 + Int((Double($0)+0.5)*stride) }
        for i in 0..<12 {
            // Each probe samples the middle of one glyph, not anti-aliased side bearings.
            t = 50 + Double(i)*DictationDraftReveal.stagger + 0.066
            let ink = try imageColumns()
            for j in centers.indices {
                let x = centers[j], fraction = ink[x] / max(1,full[x])
                if j <= i { #expect(fraction > 0.02) } else { #expect(fraction < 0.004) }
            }
        }
        t = 53
        view.display("田田田田山田田田田田田田", reduceMotion: false)
        let revised = try imageColumns()
        #expect(revised[centers[4]] < 0.01 && revised[centers[3]] == full[centers[3]] && revised[centers[5]] == full[centers[5]])
    }

    @Test @MainActor func actualCaptionSettlesOnceAndDropsItsClockWhenDetached() async throws {
        _ = NSApplication.shared
        let rect = NSRect(x: 0, y: 0, width: 340, height: 44)
        let window = NSWindow(contentRect: rect, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; defer { window.close() }
        let view = DictationCaptionView(frame: rect)
        window.contentView = view // Offscreen, synthetic, no screen capture and no live microphone.
        window.appearance = NSAppearance(named: .aqua)
        func ink() throws -> CGFloat {
            let image = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: image)
            var ink: CGFloat = 0
            for x in 0..<image.pixelsWide { for y in 0..<image.pixelsHigh { ink += image.colorAt(x: x, y: y)?.alphaComponent ?? 0 } }
            return ink
        }
        view.display("明天下午开会。", reduceMotion: false)
        #expect(view.isAnimating)
        let initial = try ink()
        try await Task.sleep(for: .milliseconds(1200))
        let settled = try ink()
        #expect(!view.isAnimating && settled > 0 && initial < settled * 0.85)
        view.display("明天下午开会。", reduceMotion: false)
        #expect(!view.isAnimating)
        view.display("明天下午四点开会。", reduceMotion: true)
        #expect(!view.isAnimating)
        view.display("明天下午四点开会。新增", reduceMotion: false)
        #expect(view.isAnimating)
        window.contentView = nil
        #expect(!view.isAnimating)
    }
}

@MainActor private extension DictationCaptionView {
    func display(_ text: String, reduceMotion: Bool) { display(DictationCaptionSlice(text), reduceMotion: reduceMotion) }
    func tickerInk() throws -> (box: CGRect, redX: CGFloat?) {
        needsDisplay = true
        let rep = try #require(bitmapImageRepForCachingDisplay(in: bounds))
        cacheDisplay(in: bounds, to: rep)
        let sx = bounds.width/CGFloat(rep.pixelsWide), sy = bounds.height/CGFloat(rep.pixelsHigh)
        var box = CGRect.null, red: CGFloat = 0, n = 0
        for x in 0..<rep.pixelsWide { for y in 0..<rep.pixelsHigh {
            guard let c = rep.colorAt(x:x,y:y)?.usingColorSpace(.sRGB), c.alphaComponent > 0.25 else { continue }
            box = box.union(CGRect(x:CGFloat(x)*sx,y:CGFloat(y)*sy,width:sx,height:sy))
            if c.redComponent > c.greenComponent+0.3 && c.redComponent > c.blueComponent+0.3 {
                red += (CGFloat(x)+0.5)*sx; n += 1
            }
        } }
        return (box, n > 0 ? red/CGFloat(n) : nil)
    }
}
