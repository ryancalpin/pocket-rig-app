import Testing
import Foundation
import CMoonlight
@testable import PocketRig

@Suite struct StreamConfigurationBuilderTests {
    @Test func remoteInputIVStartsWithKeyIDBigEndian() {
        let key = StreamConfigurationBuilder.makeRemoteInputKey()
        #expect(key.key.count == 16 && key.iv.count == 16)
        let id = key.iv.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        #expect(Int32(bitPattern: id) == key.keyID)
        #expect(key.iv.dropFirst(4).allSatisfy { $0 == 0 })
    }

    @Test func prefersHEVCWhenServerSupportsIt() {
        let formats = StreamConfigurationBuilder.supportedVideoFormats(serverCodecSupport: Int32(SCM_H264 | SCM_HEVC))
        #expect(formats & Int32(VIDEO_FORMAT_H265) != 0)
        #expect(formats & Int32(VIDEO_FORMAT_H264) != 0)
        #expect(StreamConfigurationBuilder.supportedVideoFormats(serverCodecSupport: Int32(SCM_H264)) == Int32(VIDEO_FORMAT_H264))
    }

    @Test func configurationCopiesSettingsAndKeys() {
        let ri = StreamConfigurationBuilder.makeRemoteInputKey()
        var settings = StreamSettings.default
        settings.fps = 120
        let config = StreamConfigurationBuilder.streamConfiguration(settings: settings, address: "100.101.102.103",
                                                                   riKey: ri, serverCodecSupport: Int32(SCM_HEVC | SCM_H264))
        #expect(config.width == 1920 && config.height == 1080 && config.fps == 120)
        #expect(config.bitrate == 20_000)
        #expect(config.packetSize == 1392)
        #expect(config.streamingRemotely == STREAM_CFG_AUTO)
        // AUDIO_CONFIGURATION_STEREO is a function-like macro Swift can't import; mirrored in the builder.
        #expect(config.audioConfiguration == StreamConfigurationBuilder.stereoAudioConfiguration)
        #expect(StreamConfigurationBuilder.stereoAudioConfiguration == (0x3 << 16) | (2 << 8) | 0xCA)
        #expect(config.encryptionFlags == Int32(bitPattern: ENCFLG_ALL))
        #expect(config.clientRefreshRateX100 == 12_000)
        #expect(config.colorSpace == COLORSPACE_REC_709 && config.colorRange == COLOR_RANGE_LIMITED)
        let keyBytes = withUnsafeBytes(of: config.remoteInputAesKey) { Data($0) }
        #expect(keyBytes == ri.key)
        let ivBytes = withUnsafeBytes(of: config.remoteInputAesIv) { Data($0) }
        #expect(ivBytes == ri.iv)
        #expect(StreamConfigurationBuilder.modeString(settings) == "1920x1080x120")
        #expect(StreamConfigurationBuilder.surroundAudioInfo == (0x3 << 16) | 2)
    }
}
