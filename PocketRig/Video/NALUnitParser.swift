import Foundation

enum VideoCodec: Sendable { case h264, hevc }

enum NALUnitParser {
    /// Splits an Annex B byte stream into NAL payloads (start codes removed, empties dropped).
    static func split(annexB: Data) -> [Data] {
        let bytes = [UInt8](annexB)
        var starts: [(codeStart: Int, payloadStart: Int)] = []
        var i = 0
        while i + 2 < bytes.count {
            if bytes[i] == 0, bytes[i + 1] == 0, bytes[i + 2] == 1 {
                let codeStart = (i > 0 && bytes[i - 1] == 0) ? i - 1 : i
                starts.append((codeStart, i + 3))
                i += 3
            } else {
                i += 1
            }
        }
        var nals: [Data] = []
        for (index, start) in starts.enumerated() {
            let end = index + 1 < starts.count ? starts[index + 1].codeStart : bytes.count
            if end > start.payloadStart {
                nals.append(Data(bytes[start.payloadStart..<end]))
            }
        }
        return nals
    }

    /// Joins buffer fragments into one Annex B stream, then splits it.
    /// Moonlight hands a frame over in packet-sized pieces that do not line up
    /// with NAL boundaries, so splitting each piece on its own loses data.
    static func split(fragments: [Data]) -> [Data] {
        var joined = Data()
        joined.reserveCapacity(fragments.reduce(0) { $0 + $1.count })
        for fragment in fragments { joined.append(fragment) }
        return split(annexB: joined)
    }

    /// 4-byte big-endian length followed by the payload, for each unit (AVCC/HVCC framing).
    static func lengthPrefixed(_ nals: [Data]) -> Data {
        var out = Data()
        out.reserveCapacity(nals.reduce(0) { $0 + $1.count + 4 })
        for nal in nals {
            var length = UInt32(nal.count).bigEndian
            withUnsafeBytes(of: &length) { out.append(contentsOf: $0) }
            out.append(nal)
        }
        return out
    }
}
