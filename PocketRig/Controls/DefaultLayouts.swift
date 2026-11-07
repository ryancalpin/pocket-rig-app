import CoreGraphics
import CryptoKit
import Foundation

/// The layout each pose starts with, drawn in points on the iPhone Duo's deck area for that pose and
/// stored as fractions so it scales to other screens.
enum DefaultLayouts {
    /// The deck area (or the whole screen, sideways) the point tables below were drawn for.
    static func referenceSize(for pose: Pose) -> CGSize {
        switch pose.layoutPose {
        case .laptop, .cover: CGSize(width: 669, height: 465)
        case .book: CGSize(width: 465, height: 669)
        case .sideways: CGSize(width: 951, height: 669)
        case .upright: CGSize(width: 669, height: 634)
        }
    }

    static func buttons(for pose: Pose) -> [ControlButton] {
        let pose = pose.layoutPose
        let size = referenceSize(for: pose)
        let opacity = pose == .sideways ? 0.4 : 1
        return table(for: pose).map { kind, rect in
            ControlButton(id: stableID(pose: pose, kind: kind), kind: kind,
                          frame: NormalizedRect(rect, in: size), opacity: opacity)
        }
    }

    /// The same ID every time, so "reset" and "is this still the default?" compare cleanly.
    /// Derived from the raw names (not enum order), so adding a case never reshuffles saved IDs.
    private static func stableID(pose: Pose, kind: ControlKind) -> UUID {
        let digest = Array(SHA256.hash(data: Data("\(pose.rawValue)|\(kind.rawValue)".utf8)).prefix(16))
        var b = digest
        b[6] = (b[6] & 0x0F) | 0x50
        b[8] = (b[8] & 0x3F) | 0x80
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
                           b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }

    // MARK: Small decks

    /// Decks narrower and shorter than this get the compact upright layout (iPhone SE upright).
    static let compactDeckLimit: CGFloat = 450
    /// The deck the compact upright table was drawn for: the iPhone SE upright gamepad area.
    static let compactReferenceSize = CGSize(width: 375, height: 396)

    private static let builtInUpright = buttons(for: .upright)

    /// The built-in upright layout, redrawn for small decks: Back and Start move between the stick and
    /// the face buttons, and the stick clicks sit at the bottom middle, so every control keeps its 44 pt
    /// floor and an 8 pt gap. Same IDs as the full layout.
    static let compactUpright: [ControlButton] = compactTable.map { kind, rect in
        ControlButton(id: stableID(pose: .upright, kind: kind), kind: kind,
                      frame: NormalizedRect(rect, in: compactReferenceSize), opacity: 1)
    }

    /// The buttons to draw in an area this size: an untouched built-in upright layout on a small deck
    /// swaps to the compact one. Customised layouts are drawn as saved.
    static func adapted(_ buttons: [ControlButton], to size: CGSize) -> [ControlButton] {
        guard size.width < compactDeckLimit, size.height < compactDeckLimit, buttons == builtInUpright
        else { return buttons }
        return compactUpright
    }

    private static let compactTable: [(ControlKind, CGRect)] = [
        (.leftTrigger, r(8, 8, 56, 44)), (.leftBumper, r(72, 8, 56, 44)), (.guide, r(165.5, 8, 44, 44)),
        (.rightBumper, r(247, 8, 56, 44)), (.rightTrigger, r(311, 8, 56, 44)),
        (.leftStick, r(16, 64, 112, 112)), (.back, r(148, 68, 44, 44)), (.start, r(148, 120, 44, 44)),
        (.faceNorth, r(271, 60, 44, 44)), (.faceWest, r(219, 112, 44, 44)),
        (.faceEast, r(323, 112, 44, 44)), (.faceSouth, r(271, 164, 44, 44)),
        (.dpad, r(8, 220, 132, 132)), (.rightStick, r(251, 224, 104, 104)),
        (.leftStickClick, r(150, 336, 44, 44)), (.rightStickClick, r(202, 336, 44, 44)),
    ]

    private static func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
        CGRect(x: x, y: y, width: w, height: h)
    }

    private static func table(for pose: Pose) -> [(ControlKind, CGRect)] {
        switch pose {
        case .laptop, .cover:
            [(.leftTrigger, r(16, 8, 64, 44)), (.leftBumper, r(88, 8, 64, 44)),
             (.back, r(254, 8, 44, 44)), (.guide, r(312, 8, 44, 44)), (.start, r(370, 8, 44, 44)),
             (.rightBumper, r(517, 8, 64, 44)), (.rightTrigger, r(589, 8, 64, 44)),
             (.leftStick, r(32, 72, 150, 150)),
             (.faceNorth, r(521, 72, 56, 56)), (.faceWest, r(457, 136, 56, 56)),
             (.faceEast, r(585, 136, 56, 56)), (.faceSouth, r(521, 200, 56, 56)),
             (.dpad, r(150, 260, 156, 156)), (.rightStick, r(363, 260, 150, 150)),
             (.leftStickClick, r(40, 405, 64, 44)), (.rightStickClick, r(565, 405, 64, 44))]
        case .book:
            [(.leftTrigger, r(8, 8, 56, 44)), (.leftBumper, r(72, 8, 56, 44)),
             (.back, r(152, 8, 44, 44)), (.guide, r(210, 8, 44, 44)), (.start, r(268, 8, 44, 44)),
             (.rightBumper, r(337, 8, 56, 44)), (.rightTrigger, r(401, 8, 56, 44)),
             (.leftStick, r(24, 72, 140, 140)),
             (.faceNorth, r(337, 72, 56, 56)), (.faceWest, r(273, 136, 56, 56)),
             (.faceEast, r(401, 136, 56, 56)), (.faceSouth, r(337, 200, 56, 56)),
             (.dpad, r(24, 300, 156, 156)), (.rightStick, r(301, 300, 140, 140)),
             (.leftStickClick, r(40, 480, 64, 44)), (.rightStickClick, r(361, 480, 64, 44))]
        case .sideways:
            [(.leftTrigger, r(16, 16, 64, 44)), (.leftBumper, r(88, 16, 64, 44)),
             (.rightBumper, r(799, 16, 64, 44)), (.rightTrigger, r(871, 16, 64, 44)),
             (.back, r(397, 600, 44, 44)), (.guide, r(453, 600, 44, 44)), (.start, r(509, 600, 44, 44)),
             (.leftStick, r(40, 290, 150, 150)), (.dpad, r(190, 470, 156, 156)),
             (.faceNorth, r(819, 280, 56, 56)), (.faceWest, r(755, 344, 56, 56)),
             (.faceEast, r(883, 344, 56, 56)), (.faceSouth, r(819, 408, 56, 56)),
             (.rightStick, r(605, 470, 150, 150)),
             (.leftStickClick, r(40, 600, 64, 44)), (.rightStickClick, r(847, 600, 64, 44))]
        case .upright:
            [(.leftTrigger, r(16, 8, 64, 44)), (.leftBumper, r(88, 8, 64, 44)),
             (.back, r(254, 8, 44, 44)), (.guide, r(312, 8, 44, 44)), (.start, r(370, 8, 44, 44)),
             (.rightBumper, r(517, 8, 64, 44)), (.rightTrigger, r(589, 8, 64, 44)),
             (.leftStick, r(40, 80, 160, 160)),
             (.faceNorth, r(521, 80, 56, 56)), (.faceWest, r(457, 144, 56, 56)),
             (.faceEast, r(585, 144, 56, 56)), (.faceSouth, r(521, 208, 56, 56)),
             (.dpad, r(40, 280, 156, 156)), (.rightStick, r(469, 280, 160, 160)),
             (.leftStickClick, r(90, 476, 64, 44)), (.rightStickClick, r(515, 476, 64, 44))]
        }
    }
}
