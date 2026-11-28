import Foundation

enum XiaomiRemoteVoice {
    static let serviceUUID = "AB5E0001-5A21-4F05-BC7D-AF01F617B664"
    static let commandUUID = "AB5E0002-5A21-4F05-BC7D-AF01F617B664"
    static let audioUUID = "AB5E0003-5A21-4F05-BC7D-AF01F617B664"
    static let controlUUID = "AB5E0004-5A21-4F05-BC7D-AF01F617B664"
    static let sampleRate = 16_000
    // ATVV v1.0, including the legacy capability word and Hold-to-Talk support.
    static let getCapabilities = Data([0x0A, 0x01, 0x00, 0x00, 0x03, 0x03])
    static let codec16k: UInt8 = 0x02

    enum Event: Equatable {
        case capabilities(frameBytes: Int)
        case incompatibleCapabilities
        case start(reason: UInt8, codec: UInt8, stream: UInt8)
        case stop
        case sync(codec: UInt8, predictor: Int16, step: Int)
    }

    static func close(stream: UInt8) -> Data { Data([0x0D, stream]) }

    static func control(_ data: Data) -> Event? {
        guard !data.isEmpty, data.count <= 64 else { return nil }
        let bytes = Array(data)
        switch bytes[0] {
        case 0x00:
            return .stop
        case 0x04:
            guard bytes.count >= 4 else { return nil }
            return .start(reason: bytes[1], codec: bytes[2], stream: bytes[3])
        case 0x0A:
            guard bytes.count >= 7, bytes[6] <= 88 else { return nil }
            return .sync(codec: bytes[1], predictor: Int16(bitPattern: word(bytes[4], bytes[5])), step: Int(bytes[6]))
        case 0x0B:
            guard bytes.count >= 7, word(bytes[1], bytes[2]) == 0x0100 else { return .incompatibleCapabilities }
            // Some Xiaomi firmware places its codec mask one byte later.
            let codecs = bytes[3] == 0 && bytes.count >= 9 ? bytes[4] : bytes[3]
            let declaredSize = Int(word(bytes[5], bytes[6]))
            let size = declaredSize == 0 ? 120 : declaredSize
            guard codecs & codec16k != 0, (1...512).contains(size) else { return .incompatibleCapabilities }
            return .capabilities(frameBytes: size)
        default:
            return nil
        }
    }

    private static func word(_ high: UInt8, _ low: UInt8) -> UInt16 { UInt16(high) << 8 | UInt16(low) }
}

/// ATVV v1.0 sends raw high-nibble-first IMA ADPCM, with predictor state in control notifications.
struct XiaomiVoiceDecoder {
    private static let steps = [
        7, 8, 9, 10, 11, 12, 13, 14, 16, 17, 19, 21, 23, 25, 28, 31, 34, 37,
        41, 45, 50, 55, 60, 66, 73, 80, 88, 97, 107, 118, 130, 143, 157, 173, 190,
        209, 230, 253, 279, 307, 337, 371, 408, 449, 494, 544, 598, 658, 724, 796,
        876, 963, 1060, 1166, 1282, 1411, 1552, 1707, 1878, 2066, 2272, 2499, 2749,
        3024, 3327, 3660, 4026, 4428, 4871, 5358, 5894, 6484, 7132, 7845, 8630,
        9493, 10442, 11487, 12635, 13899, 15289, 16818, 18500, 20350, 22385, 24623,
        27086, 29794, 32767,
    ]
    private static let indexAdjustment = [-1, -1, -1, -1, 2, 4, 6, 8]
    private var predictor = 0
    private var index = 0
    private var pending = Data()
    let frameBytes: Int

    init(frameBytes: Int) {
        precondition((1...512).contains(frameBytes))
        self.frameBytes = frameBytes
    }

    mutating func synchronize(predictor: Int16, step: Int) {
        self.predictor = Int(predictor)
        index = min(88, max(0, step))
        pending.removeAll(keepingCapacity: true)
    }

    mutating func append(_ notification: Data) -> [Int16] {
        guard !notification.isEmpty, notification.count <= 512 else { return [] }
        pending.append(notification)
        let completeBytes = pending.count / frameBytes * frameBytes
        guard completeBytes > 0 else { return [] }
        let frame = pending.prefix(completeBytes)
        pending.removeFirst(completeBytes)
        var samples: [Int16] = []
        samples.reserveCapacity(completeBytes * 2)
        for byte in frame {
            samples.append(decode(Int(byte >> 4)))
            samples.append(decode(Int(byte & 0x0F)))
        }
        return samples
    }

    private mutating func decode(_ nibble: Int) -> Int16 {
        let step = Self.steps[index]
        var difference = step >> 3
        if nibble & 4 != 0 { difference += step }
        if nibble & 2 != 0 { difference += step >> 1 }
        if nibble & 1 != 0 { difference += step >> 2 }
        predictor = min(32767, max(-32768, predictor + (nibble & 8 == 0 ? difference : -difference)))
        index = min(88, max(0, index + Self.indexAdjustment[nibble & 7]))
        return Int16(predictor)
    }
}
