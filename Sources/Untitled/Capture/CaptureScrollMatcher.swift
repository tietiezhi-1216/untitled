import CoreGraphics

/// The seam is in the previous viewport's pixel coordinates (top/left origin).
struct ScrollStitchAlignment {
    let shift: Int
    let seam: Int
}

enum CaptureScrollMatcher {
    // Keep the full pixel grid along the scrolling axis. Only the other axis
    // is reduced; scaling both axes can hide thin text or round a Retina seam.
    private static let maxLength = 16_384
    private static let maxCross = 64
    private static let lanes = 8
    private static let coarseCount = 10

    static func align(_ first: CGImage, _ second: CGImage, axis: StitchAxis) -> ScrollStitchAlignment? {
        guard first.width == second.width, first.height == second.height,
              let a = Strip(first, axis: axis), let b = Strip(second, axis: axis) else { return nil }
        if a.bytes == b.bytes { return .init(shift: 0, seam: a.length / 2) }
        let leading = stationaryEdge(a, b, reversed: false)
        let trailing = stationaryEdge(a, b, reversed: true)
        let body = max(2, leading + 2)..<min(a.length - 2, a.length - trailing - 2)
        let minOverlap = max(16, body.count / 3)
        let limit = body.count - minOverlap
        guard limit > 0 else { return nil }

        let anchors = a.anchors(in: body)
        guard anchors.count >= 2 else { return nil }
        var proposals: [(shift: Int, cost: Double)] = []
        for shift in -limit...limit {
            let overlap = max(body.lowerBound, body.lowerBound + shift)..<min(body.upperBound, body.upperBound + shift)
            if let cost = coarseCost(a, b, anchors: anchors, overlap: overlap, shift: shift) {
                proposals.append((shift, cost))
            }
        }
        proposals.sort { $0.cost == $1.cost ? abs($0.shift) < abs($1.shift) : $0.cost < $1.cost }
        var peaks: [Int] = []
        for proposal in proposals where peaks.allSatisfy({ abs($0 - proposal.shift) > 3 }) {
            peaks.append(proposal.shift)
            if peaks.count == coarseCount { break }
        }
        let candidates = Set(peaks.flatMap { ($0 - 1)...($0 + 1) }.filter { abs($0) <= limit }).union([0])
        var verified: [Verified] = []
        for shift in candidates {
            let overlap = max(body.lowerBound, body.lowerBound + shift)..<min(body.upperBound, body.upperBound + shift)
            if let check = verify(a, b, overlap: overlap, shift: shift) { verified.append(check) }
        }
        verified.sort { $0.loss == $1.loss ? abs($0.alignment.shift) < abs($1.alignment.shift) : $0.loss < $1.loss }
        guard let best = verified.first, best.loss <= 0.26 else { return nil }
        if best.alignment.shift == 0 { return best.alignment }
        // Check other well-supported placements, including repeat distances.
        // A tie is not a match, even when the entire background is identical.
        if let second = verified.dropFirst().first(where: { abs($0.alignment.shift - best.alignment.shift) > 1 }),
           second.loss < best.loss + max(0.075, best.loss * 0.42) { return nil }
        if let neighbor = verified.dropFirst().first(where: { abs($0.alignment.shift - best.alignment.shift) == 1 }),
           neighbor.loss < best.loss + 0.025 { return nil }
        return best.alignment
    }

    private struct Strip {
        let length: Int
        let cross: Int
        let bytes: [UInt8]
        let edges: [Int16]
        let profiles: [Int16]
        let activity: [Int]
        var across: Range<Int> { cross / 16 ..< cross - cross / 16 }

        init?(_ image: CGImage, axis: StitchAxis) {
            let vertical = axis == .vertical
            let length = vertical ? image.height : image.width
            let cross = min(maxCross, vertical ? image.width : image.height)
            guard (20...maxLength).contains(length), cross >= lanes else { return nil }
            self.length = length; self.cross = cross
            let width = vertical ? cross : length
            let height = vertical ? length : cross
            var gray = [UInt8](repeating: 0, count: width * height)
            let drawn = gray.withUnsafeMutableBytes { memory in
                guard let context = CGContext(data: memory.baseAddress, width: width, height: height,
                    bitsPerComponent: 8, bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0) else { return false }
                context.interpolationQuality = .high
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
                return true
            }
            guard drawn else { return nil }
            if !vertical {
                var transposed = gray
                for y in 0..<cross {
                    for x in 0..<length { transposed[x * cross + y] = gray[y * length + x] }
                }
                gray = transposed
            }
            bytes = gray
            var edges = [Int16](repeating: 0, count: gray.count)
            var profiles = [Int16](repeating: 0, count: length * lanes * 2)
            var activity = [Int](repeating: 0, count: length)
            let inset = cross / 16, coverage = cross - inset * 2
            for row in 2..<(length - 2) {
                let index = row * cross
                for lane in 0..<lanes {
                    let from = inset + lane * coverage / lanes
                    let to = inset + (lane + 1) * coverage / lanes
                    guard from < to else { continue }
                    var luma = 0, edgeSum = 0
                    for column in from..<to {
                        let i = index + column
                        let edge = Int16(gray[i + 2 * cross]) - Int16(gray[i - 2 * cross])
                        edges[i] = edge
                        luma += Int(gray[i]); edgeSum += abs(Int(edge))
                    }
                    let cell = row * lanes * 2 + lane * 2
                    profiles[cell] = Int16(luma / (to - from))
                    profiles[cell + 1] = Int16(edgeSum / (to - from))
                    activity[row] += edgeSum
                }
            }
            self.edges = edges; self.profiles = profiles; self.activity = activity
        }

        func anchors(in range: Range<Int>) -> [Int] {
            let bands = min(64, range.count / 3)
            guard bands > 0 else { return [] }
            return (0..<bands).compactMap { band in
                let start = range.lowerBound + range.count * band / bands
                let end = range.lowerBound + range.count * (band + 1) / bands
                let best = (start..<end).max { activity[$0] < activity[$1] }
                return best.flatMap { activity[$0] >= cross * 3 ? $0 : nil }
            }
        }
    }

    /// A stationary edge must contain structure as well as stay in place.
    /// Blank/common backgrounds alone never count as fixed chrome.
    private static func stationaryEdge(_ a: Strip, _ b: Strip, reversed: Bool) -> Int {
        let cap = a.length / 5
        var lastStructure = 0
        var still = 0
        for distance in 0..<cap {
            let row = reversed ? a.length - 1 - distance : distance
            let start = row * a.cross
            var error = 0, changed = 0
            for column in a.across {
                let d = abs(Int(a.bytes[start + column]) - Int(b.bytes[start + column]))
                error += d
                if d >= 7 { changed += 1 }
            }
            if error > a.cross * 2 || changed > max(1, a.cross / 12) { break }
            still += 1
            if min(a.activity[row], b.activity[row]) >= a.cross * 4 { lastStructure = distance + 1 }
        }
        guard still < cap, lastStructure >= 5 else { return 0 }
        return min(still, lastStructure + 3)
    }

    private static func coarseCost(_ a: Strip, _ b: Strip, anchors: [Int], overlap: Range<Int>, shift: Int) -> Double? {
        var error = 0, evidence = 0, rows = 0
        for row in anchors where overlap.contains(row) {
            let i = row * lanes * 2
            let j = (row - shift) * lanes * 2
            for lane in stride(from: 0, to: lanes * 2, by: 2) {
                let ap = Int(a.profiles[i + lane + 1]), bp = Int(b.profiles[j + lane + 1])
                evidence += max(ap, bp)
                error += abs(ap - bp) * 2 + abs(Int(a.profiles[i + lane]) - Int(b.profiles[j + lane]))
            }
            rows += 1
        }
        guard rows >= 2, evidence >= 28 else { return nil }
        return Double(error) / Double(evidence)
    }

    private struct Verified {
        let alignment: ScrollStitchAlignment
        let loss: Double
    }

    private static func verify(_ a: Strip, _ b: Strip, overlap: Range<Int>, shift: Int) -> Verified? {
        let middle = overlap.lowerBound + overlap.count / 2
        let rowStep = max(1, overlap.count / 1024)
        let count = 10
        var weights = [Int](repeating: 0, count: count)
        var errors = weights
        var texturedRows = weights
        var flatError = 0, flatSamples = 0
        var seam = middle, seamCost = Double.infinity
        for row in stride(from: overlap.lowerBound, to: overlap.upperBound, by: rowStep) {
            let band = min(count - 1, (row - overlap.lowerBound) * count / overlap.count)
            let i = row * a.cross, j = (row - shift) * a.cross
            var energy = 0, loss = 0, raw = 0
            for column in a.across {
                let luma = abs(Int(a.bytes[i + column]) - Int(b.bytes[j + column]))
                raw += luma
                let ea = Int(a.edges[i + column]), eb = Int(b.edges[j + column])
                let ink = max(abs(ea), abs(eb))
                guard ink >= 8 else { continue }
                energy += ink
                loss += abs(ea - eb) * 2 + min(luma, ink * 2)
            }
            flatError += raw; flatSamples += a.across.count
            weights[band] += energy; errors[band] += loss
            if energy >= a.cross * 3 { texturedRows[band] += 1 }
            if abs(row - middle) <= max(1, overlap.count / 5) {
                let cost = Double(raw * 2 + loss + energy / 16) / Double(a.cross)
                    + Double(abs(row - middle)) * 2 / Double(overlap.count)
                if cost < seamCost { seam = row; seamCost = cost }
            }
        }
        let weight = weights.reduce(0, +)
        guard weight >= a.cross * 14, flatError <= 7 * flatSamples else { return nil }
        let agreeing = (0..<count).filter {
            texturedRows[$0] >= 2 && weights[$0] >= a.cross * 5 && errors[$0] * 10 <= weights[$0] * 9
        }
        guard let first = agreeing.first, let last = agreeing.last, last - first >= 2,
              agreeing.reduce(0, { $0 + weights[$1] }) * 100 >= weight * 70 else { return nil }
        let gradientLoss = Double(errors.reduce(0, +)) / Double(3 * weight)
        let averageDifference = Double(flatError) / Double(max(1, flatSamples))
        return Verified(alignment: .init(shift: shift, seam: seam), loss: gradientLoss + averageDifference / 40)
    }
}
