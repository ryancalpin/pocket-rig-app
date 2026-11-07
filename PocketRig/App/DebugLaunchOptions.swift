import Foundation

/// Launch arguments for hands-free testing: `-pr.host <ip> -pr.pin <4 digits> -pr.app <title>`, plus
/// `-pr.reuseTestPairing YES` to borrow the server certificate `LiveStreamSmokeTests` cached on this
/// simulator (no PIN needed when that pairing is still valid). Launch arguments land in
/// `UserDefaults.standard`. Release builds always see no options.
struct DebugLaunchOptions: Sendable {
    let hostAddress: String?
    let pairingPIN: String?
    let autoLaunchAppTitle: String?
    var reuseTestPairing = false

    /// `-pr.noAudio YES`: stream without starting audio. Release builds ignore it.
    static var noAudio: Bool {
        #if DEBUG
        UserDefaults.standard.bool(forKey: "pr.noAudio")
        #else
        false
        #endif
    }

    /// `-pr.<key> YES` switches for screenshots and hands-free testing. Release builds always see false.
    static func flag(_ key: String) -> Bool {
        #if DEBUG
        UserDefaults.standard.bool(forKey: "pr.\(key)")
        #else
        false
        #endif
    }

    /// `-pr.<key> <value>` text options. Release builds always see nil.
    static func text(_ key: String) -> String? {
        #if DEBUG
        nonEmpty(UserDefaults.standard.string(forKey: "pr.\(key)"))
        #else
        nil
        #endif
    }

    /// `-pr.showPose YES`: a caption at the top naming the pose the app thinks it's in.
    static var showPose: Bool { flag("showPose") }

    /// `-pr.streamPreview YES`: the stream screen with a stand-in picture, no PC needed.
    static var streamPreview: Bool { flag("streamPreview") }

    /// `-pr.ignorePhysicalControllers YES`: pretend no controller is connected (the simulator passes the
    /// Mac's gamepads through), so screenshots show the touch buttons.
    static var ignorePhysicalControllers: Bool { flag("ignorePhysicalControllers") }

    static var current: DebugLaunchOptions {
        #if DEBUG
        let defaults = UserDefaults.standard
        let pin = defaults.string(forKey: "pr.pin").flatMap { pin in
            pin.count == 4 && pin.allSatisfy(\.isASCIIDigit) ? pin : nil
        }
        return DebugLaunchOptions(hostAddress: nonEmpty(defaults.string(forKey: "pr.host")),
                                  pairingPIN: pin,
                                  autoLaunchAppTitle: nonEmpty(defaults.string(forKey: "pr.app")),
                                  reuseTestPairing: defaults.bool(forKey: "pr.reuseTestPairing"))
        #else
        return DebugLaunchOptions(hostAddress: nil, pairingPIN: nil, autoLaunchAppTitle: nil)
        #endif
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        return value
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}
