import Foundation

/// How far the stream is held back to cool the phone down.
enum HeatStep: Int, Comparable, Sendable, CaseIterable {
    case normal, warm, hot

    static func < (lhs: HeatStep, rhs: HeatStep) -> Bool { lhs.rawValue < rhs.rawValue }

    /// The line shown when the step changes; nil when it didn't.
    static func notice(from old: HeatStep, to new: HeatStep) -> String? {
        guard old != new else { return nil }
        switch new {
        case .warm where old == .normal: return "Your phone is getting warm, so the picture is a little softer for now."
        case .warm: return "Your phone is cooling down. Quality is going back up a step."
        case .hot: return "Your phone is hot. Quality is lower until it cools down."
        case .normal: return "Your phone has cooled down. Quality is back to normal."
        }
    }
}

/// Overheat protection. `.serious` lowers quality one step; `.critical` goes straight to the lowest.
/// Quality comes back one step at a time, and only after 5 minutes at `.nominal` or `.fair`. Apart from
/// `.critical`, it never changes twice within 3 minutes, so the stream doesn't keep reconnecting.
struct HeatGovernor: Sendable {
    static let minimumGap: Duration = .seconds(180)
    static let coolDown: Duration = .seconds(300)

    private(set) var step: HeatStep = .normal
    private var lastChange: ContinuousClock.Instant?
    private var coolSince: ContinuousClock.Instant?

    /// Feed it the phone's thermal state when it changes and now and then. Returns the new step when it changes.
    mutating func update(_ thermal: ProcessInfo.ThermalState, enabled: Bool, now: ContinuousClock.Instant) -> HeatStep? {
        guard enabled else {
            coolSince = nil
            return change(to: .normal, now: now)
        }
        switch thermal {
        case .critical:
            coolSince = nil
            return step < .hot ? change(to: .hot, now: now) : nil
        case .serious:
            coolSince = nil
            guard step == .normal, gapPassed(now) else { return nil }
            return change(to: .warm, now: now)
        default:   // .nominal, .fair
            guard step > .normal else {
                coolSince = nil
                return nil
            }
            guard let since = coolSince else {
                coolSince = now
                return nil
            }
            guard now - since >= Self.coolDown, gapPassed(now) else { return nil }
            coolSince = now   // the next step up waits for another full cool-down
            return change(to: HeatStep(rawValue: step.rawValue - 1) ?? .normal, now: now)
        }
    }

    private func gapPassed(_ now: ContinuousClock.Instant) -> Bool {
        lastChange.map { now - $0 >= Self.minimumGap } ?? true
    }

    private mutating func change(to new: HeatStep, now: ContinuousClock.Instant) -> HeatStep? {
        guard new != step else { return nil }
        step = new
        lastChange = now
        return new
    }
}

/// What the phone's network costs right now.
struct NetworkSnapshot: Equatable, Sendable {
    /// Mobile data or a phone's hotspot.
    var isExpensive = false
    /// Low Data Mode is on.
    var isConstrained = false

    var costsData: Bool { isExpensive || isConstrained }

    static let home = NetworkSnapshot()
}

/// What is holding the stream back right now, on top of the user's own Quality choices.
struct QualityContext: Equatable, Sendable {
    var heat: HeatStep = .normal
    /// The most data the stream may use away from home; nil at home, or when the user picked "Same as at home".
    var awayLimitKbps: Int?
}

enum StreamQualityRules {
    static let warmFPS = 60, warmKbps = 15_000
    static let hotFPS = 30, hotKbps = 8_000

    /// A warm or hot phone streams at 720p at most.
    static func cap(_ cap: ResolutionCap, heat: HeatStep) -> ResolutionCap {
        heat == .normal ? cap : .p720
    }

    /// Lowers frame rate and data for heat and for being away from home. Never raises anything.
    static func adjust(_ settings: StreamSettings, for context: QualityContext) -> StreamSettings {
        var adjusted = settings
        switch context.heat {
        case .normal:
            break
        case .warm:
            adjusted.fps = min(adjusted.fps, warmFPS)
            adjusted.bitrateKbps = min(adjusted.bitrateKbps, warmKbps)
        case .hot:
            adjusted.fps = min(adjusted.fps, hotFPS)
            adjusted.bitrateKbps = min(adjusted.bitrateKbps, hotKbps)
        }
        if let limit = context.awayLimitKbps, limit > 0 { adjusted.bitrateKbps = min(adjusted.bitrateKbps, limit) }
        return adjusted
    }

    /// Away from home: on mobile data or Low Data Mode, or reaching the PC over Tailscale.
    static func isAway(network: NetworkSnapshot, streamAddress: String?) -> Bool {
        network.costsData || (streamAddress.map(HostAddressResolver.isTailscale) ?? false)
    }

    /// The away-from-home data limit to use now. `preference` 0 means "Same as at home".
    static func awayLimit(network: NetworkSnapshot, streamAddress: String?, preference: Int) -> Int? {
        guard preference > 0, isAway(network: network, streamAddress: streamAddress) else { return nil }
        return preference
    }
}

/// How much mobile data a stream uses. 1 Mbps for an hour is 0.45 GB (decimal gigabytes, as carriers count).
enum DataUse {
    static func gigabytesPerHour(kbps: Int) -> Double { Double(kbps) * 3600 / 8 / 1_000_000 }

    /// "about 4.5 GB an hour"; whole numbers from 10 GB up.
    static func perHourText(kbps: Int) -> String {
        let gigabytes = gigabytesPerHour(kbps: kbps)
        let number = gigabytes >= 10
            ? String(Int(gigabytes.rounded()))
            : gigabytes.formatted(.number.precision(.fractionLength(0...1)))
        return "about \(number) GB an hour"
    }

    static func warning(kbps: Int) -> String {
        "You're on mobile data. At this quality, streaming uses \(perHourText(kbps: kbps))."
    }
}
