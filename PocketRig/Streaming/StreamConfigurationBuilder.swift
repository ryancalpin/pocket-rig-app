import CMoonlight
import Foundation
import Security

struct StreamSettings: Sendable, Equatable {
    var width = 1920, height = 1080, fps = 60, bitrateKbps = 20_000
    /// False skips the audio renderer entirely (DEBUG `-pr.noAudio`, for machines with no usable audio).
    var audioEnabled = true
    static let `default` = StreamSettings()
}

/// AES key that encrypts input packets. The host derives the IV from `keyID`.
struct RemoteInputKey: Sendable {
    let key: Data
    let keyID: Int32
    /// `keyID` big-endian followed by 12 zero bytes.
    var iv: Data
}

enum StreamConfigurationBuilder {
    /// Mirrors `AUDIO_CONFIGURATION_STEREO` (`MAKE_AUDIO_CONFIGURATION(2, 0x3)`), a function-like macro
    /// Swift can't import.
    static let stereoAudioConfiguration: Int32 = (0x3 << 16) | (2 << 8) | 0xCA
    /// Channel mask << 16 | channel count, for the launch request's `surroundAudioInfo`.
    static let surroundAudioInfo: Int32 = (0x3 << 16) | 2
    static let packetSize: Int32 = 1392

    static func makeRemoteInputKey() -> RemoteInputKey {
        var key = [UInt8](repeating: 0, count: 16)
        var idBytes = [UInt8](repeating: 0, count: 4)
        if SecRandomCopyBytes(kSecRandomDefault, key.count, &key) != errSecSuccess {
            key = (0..<16).map { _ in UInt8.random(in: .min ... .max) }
        }
        if SecRandomCopyBytes(kSecRandomDefault, idBytes.count, &idBytes) != errSecSuccess {
            idBytes = (0..<4).map { _ in UInt8.random(in: .min ... .max) }
        }
        // Keep the ID non-negative so it survives any host-side parsing as a signed or unsigned number.
        let raw = idBytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) } & 0x7FFF_FFFF
        let keyID = Int32(bitPattern: raw)
        var iv = withUnsafeBytes(of: raw.bigEndian) { Data($0) }
        iv.append(Data(count: 12))
        return RemoteInputKey(key: Data(key), keyID: keyID, iv: iv)
    }

    /// HEVC when the server can encode it (cheaper on the network), always plus H.264 as the fallback.
    static func supportedVideoFormats(serverCodecSupport: Int32) -> Int32 {
        var formats = Int32(VIDEO_FORMAT_H264)
        if serverCodecSupport & Int32(SCM_HEVC) != 0 { formats |= Int32(VIDEO_FORMAT_H265) }
        return formats
    }

    static func streamConfiguration(settings: StreamSettings, address: String, riKey: RemoteInputKey,
                                    serverCodecSupport: Int32) -> STREAM_CONFIGURATION {
        var config = STREAM_CONFIGURATION()
        LiInitializeStreamConfiguration(&config)
        config.width = Int32(settings.width)
        config.height = Int32(settings.height)
        config.fps = Int32(settings.fps)
        config.bitrate = Int32(settings.bitrateKbps)
        config.packetSize = packetSize
        config.streamingRemotely = STREAM_CFG_AUTO
        config.audioConfiguration = stereoAudioConfiguration
        config.supportedVideoFormats = supportedVideoFormats(serverCodecSupport: serverCodecSupport)
        config.clientRefreshRateX100 = Int32(settings.fps * 100)
        config.colorSpace = COLORSPACE_REC_709
        config.colorRange = COLOR_RANGE_LIMITED
        config.encryptionFlags = Int32(bitPattern: ENCFLG_ALL)
        withUnsafeMutableBytes(of: &config.remoteInputAesKey) { dst in
            riKey.key.prefix(dst.count).withUnsafeBytes { dst.copyMemory(from: $0) }
        }
        withUnsafeMutableBytes(of: &config.remoteInputAesIv) { dst in
            riKey.iv.prefix(dst.count).withUnsafeBytes { dst.copyMemory(from: $0) }
        }
        return config
    }

    static func modeString(_ settings: StreamSettings) -> String {
        "\(settings.width)x\(settings.height)x\(settings.fps)"
    }
}
