import Testing
import Foundation
import CoreMedia
import CMoonlight
@testable import PocketRig

@Suite struct VideoFormatBuilderTests {
    @Test func buildsH264FormatFromParameterSets() throws {
        let format = try VideoFormatBuilder.formatDescription(codec: .h264, parameterSets: [Fixtures.sps, Fixtures.pps])
        let dims = CMVideoFormatDescriptionGetDimensions(format)
        #expect(dims.width == 1280 && dims.height == 720)
    }
    @Test func sampleBufferIsMarkedDisplayImmediately() throws {
        let format = try VideoFormatBuilder.formatDescription(codec: .h264, parameterSets: [Fixtures.sps, Fixtures.pps])
        let sample = try VideoFormatBuilder.sampleBuffer(avcc: NALUnitParser.lengthPrefixed([Data([0x65, 0x88, 0x84])]), format: format)
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
        #expect(attachments?.first?[kCMSampleAttachmentKey_DisplayImmediately] as? Bool == true)
    }
}

@Suite @MainActor struct VideoRendererTests {
    private let startCode = Data([0, 0, 0, 1])

    @Test func pFrameBeforeAnyIDRNeedsIDR() {
        let renderer = VideoRenderer()
        renderer.setup(codec: .h264)
        let result = renderer.submit(units: [(type: BUFFER_TYPE_PICDATA, data: startCode + Data([0x41, 0x9A, 0x00]))], isIDR: false, ptsUs: 16_667)
        #expect(result == DR_NEED_IDR)
    }
    @Test func idrWithParameterSetsIsAccepted() {
        let renderer = VideoRenderer()
        renderer.setup(codec: .h264)
        let units: [(type: Int32, data: Data)] = [
            (BUFFER_TYPE_SPS, startCode + Fixtures.sps),
            (BUFFER_TYPE_PPS, startCode + Fixtures.pps),
            (BUFFER_TYPE_PICDATA, startCode + Data([0x65, 0x88, 0x84])),
        ]
        #expect(renderer.submit(units: units, isIDR: true, ptsUs: 0) == DR_OK)
        // A following P-frame is accepted now that a format exists.
        #expect(renderer.submit(units: [(BUFFER_TYPE_PICDATA, startCode + Data([0x41, 0x9A, 0x00]))], isIDR: false, ptsUs: 16_667) == DR_OK)
    }
}
