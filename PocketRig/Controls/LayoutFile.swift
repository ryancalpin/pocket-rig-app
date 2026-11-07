import CoreTransferable
import Foundation
import UniformTypeIdentifiers

extension UTType {
    /// A shared Pocket Rig button layout: JSON in a `.pocketriglayout` file. Declared in project.yml.
    static let pocketRigLayout = UTType(exportedAs: "com.ryancalpin.pocketrig.layout", conformingTo: .json)
}

/// The `.pocketriglayout` file: one position's buttons and labels.
/// A file someone sends you is untrusted, so reading one is strict about size and forgiving about content.
struct LayoutFile: Codable, Equatable, Sendable {
    static let currentVersion = 1
    /// A real layout is a few KB; anything far bigger is not one.
    static let maximumBytes = 256 * 1024
    /// There are only 16 kinds of control; a few extras is generous.
    static let maximumButtons = 64
    static let maximumNameLength = 80

    var version: Int
    var name: String
    var pose: Pose
    var style: ControllerStyle
    var buttons: [ControlButton]

    init(name: String, pose: Pose, style: ControllerStyle, buttons: [ControlButton]) {
        self.version = Self.currentVersion
        self.name = name
        self.pose = pose.layoutPose
        self.style = style
        self.buttons = buttons
    }

    enum ImportError: Error, Equatable {
        case unreadable, newerVersion, empty

        var message: String {
            switch self {
            case .unreadable: "This file isn't a Pocket Rig button layout."
            case .newerVersion: "This layout was made with a newer Pocket Rig. Update the app, then try again."
            case .empty: "This layout has no buttons in it."
            }
        }
    }

    /// Same fields as the file, but one unreadable button doesn't sink the rest.
    private struct Wire: Decodable {
        var version: Int
        var name: String?
        var pose: Pose
        var style: ControllerStyle
        var buttons: [FailableDecodable<ControlButton>]
    }

    /// Reads a file someone shared. Checks size and version first so a newer format gets a helpful message,
    /// then repairs what it can (duplicate IDs, frames off the edge or too small to tap).
    static func decode(_ data: Data) throws -> LayoutFile {
        guard data.count <= maximumBytes else { throw ImportError.unreadable }
        struct Header: Decodable { var version: Int? }
        guard let header = try? JSONDecoder().decode(Header.self, from: data) else { throw ImportError.unreadable }
        if let version = header.version, version > currentVersion { throw ImportError.newerVersion }
        guard let wire = try? JSONDecoder().decode(Wire.self, from: data) else { throw ImportError.unreadable }
        guard wire.buttons.count <= maximumButtons else { throw ImportError.unreadable }
        let good = wire.buttons.compactMap(\.value)
        guard !good.isEmpty else { throw ImportError.empty }
        let pose = wire.pose.layoutPose
        let size = DefaultLayouts.referenceSize(for: pose)
        var seen = Set<UUID>()
        let buttons = good.map { button -> ControlButton in
            var fixed = button
            if !seen.insert(fixed.id).inserted { fixed.id = UUID() }
            fixed.frame = fixed.frame.sanitized().clamped(in: size)
            return fixed
        }
        var file = LayoutFile(name: String((wire.name ?? "").prefix(maximumNameLength)),
                              pose: pose, style: wire.style, buttons: buttons)
        file.version = wire.version
        return file
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    var fileName: String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -_"))
        let cleaned = String(String.UnicodeScalarView(name.unicodeScalars.filter { allowed.contains($0) }))
            .trimmingCharacters(in: .whitespaces)
        return "\(cleaned.isEmpty ? "Layout" : cleaned).pocketriglayout"
    }
}

extension LayoutFile: Transferable {
    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(contentType: .pocketRigLayout) { file in
            try file.encoded()
        } importing: { data in
            try LayoutFile.decode(data)
        }
        .suggestedFileName { $0.fileName }
    }
}
