import Foundation
import os
import SwiftData

private let layoutLog = Logger(subsystem: "com.ryancalpin.pocketrig", category: "ControlLayout")

/// Lets one bad element in a saved array fail on its own instead of sinking the whole array.
struct FailableDecodable<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws {
        value = try? T(from: decoder)
    }
}

/// A saved button layout for one pose, optionally for one game. The buttons live in one JSON blob so
/// adding button features later never needs a SwiftData migration.
@Model
final class ControlLayout {
    static let currentFormatVersion = 1

    var id: UUID
    var name: String
    var poseRaw: String
    var styleRaw: String
    /// "<PC unique ID>/<app ID>" for a per-game layout; nil for the pose's everyday layout.
    var gameKey: String?
    var buttonsData: Data
    /// Written on save for future migrations. Nothing reads it yet: the JSON is decoded leniently
    /// (unknown or broken buttons are skipped), so version 1 needs no branching.
    var formatVersion: Int
    var updatedAt: Date

    init(id: UUID = UUID(), name: String, pose: Pose, style: ControllerStyle, gameKey: String? = nil,
         buttons: [ControlButton]) {
        self.id = id
        self.name = name
        self.poseRaw = pose.layoutPose.rawValue
        self.styleRaw = style.rawValue
        self.gameKey = gameKey
        self.buttonsData = Self.encode(buttons) ?? Data()
        self.formatVersion = Self.currentFormatVersion
        self.updatedAt = .now
    }

    var pose: Pose {
        get { Pose(rawValue: poseRaw) ?? .upright }
        set { poseRaw = newValue.layoutPose.rawValue }
    }

    var style: ControllerStyle {
        get { ControllerStyle(rawValue: styleRaw) ?? .xbox }
        set { styleRaw = newValue.rawValue }
    }

    /// Skips buttons that can't be read (for example a kind from a newer build). If nothing is readable,
    /// returns the pose's defaults. Reading never rewrites the stored data.
    var buttons: [ControlButton] {
        get {
            if let good = readableButtons() { return good }
            return DefaultLayouts.buttons(for: pose)
        }
        set {
            guard let data = Self.encode(newValue) else {
                layoutLog.error("Layout \(self.id): encoding failed; keeping the old buttons")
                return
            }
            buttonsData = data
            updatedAt = .now
        }
    }

    /// False when `buttons` would fall back to the defaults because nothing in the stored data could be read.
    var hasReadableButtons: Bool { readableButtons() != nil }

    private func readableButtons() -> [ControlButton]? {
        guard let items = try? JSONDecoder().decode([FailableDecodable<ControlButton>].self, from: buttonsData) else {
            layoutLog.error("Layout \(self.id) has unreadable button data; using defaults")
            return nil
        }
        let good = items.compactMap(\.value)
        if good.count < items.count {
            layoutLog.error("Layout \(self.id): skipped \(items.count - good.count) unreadable button(s)")
        }
        if good.isEmpty {
            layoutLog.error("Layout \(self.id) has no readable buttons; using defaults")
            return nil
        }
        return good
    }

    /// Like setting `buttons`, but reports an encoding failure instead of silently keeping the old data.
    func setButtons(_ newValue: [ControlButton]) throws {
        buttonsData = try Self.encodeOrThrow(newValue)
        updatedAt = .now
    }

    static func gameKey(serverUniqueID: String, appID: Int) -> String {
        "\(serverUniqueID)/\(appID)"
    }

    static func encodeOrThrow(_ buttons: [ControlButton]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(buttons)
    }

    private static func encode(_ buttons: [ControlButton]) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(buttons)
    }
}
