import Testing
import Foundation
import CoreMedia
@testable import PocketRig

enum Fixtures {
    static let sps = Data(hex: "6764001facd9405005bb011000000300100000030320f1831960")!
    static let pps = Data(hex: "68ebe3cb22c0")!
}

@Suite struct NALUnitParserTests {
    @Test func splitsThreeAndFourByteStartCodes() {
        let stream = Data([0, 0, 0, 1, 0x67, 0xAA, 0, 0, 1, 0x68, 0xBB, 0xCC, 0, 0, 0, 1, 0x65, 0x01])
        let nals = NALUnitParser.split(annexB: stream)
        #expect(nals == [Data([0x67, 0xAA]), Data([0x68, 0xBB, 0xCC]), Data([0x65, 0x01])])
    }
    @Test func joinsFragmentsBeforeSplitting() {
        // One slice NAL split across three packet-sized pieces, then a second NAL
        // whose start code itself straddles two pieces.
        let fragments = [
            Data([0, 0, 0, 1, 0x65, 0x01, 0x02]),
            Data([0x03, 0x04]),
            Data([0x05, 0, 0]),
            Data([1, 0x41, 0x09]),
        ]
        let nals = NALUnitParser.split(fragments: fragments)
        #expect(nals == [Data([0x65, 0x01, 0x02, 0x03, 0x04, 0x05]), Data([0x41, 0x09])])
    }
    @Test func lengthPrefixesEachUnit() {
        let out = NALUnitParser.lengthPrefixed([Data([0x65, 0x01]), Data([0x41])])
        #expect(out == Data([0, 0, 0, 2, 0x65, 0x01, 0, 0, 0, 1, 0x41]))
    }
}
