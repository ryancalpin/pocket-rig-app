import Foundation
import SwiftData

/// The buttons a stream should use, and where they came from.
struct ResolvedLayout: Equatable, Sendable {
    enum Source: Equatable, Sendable { case game, pose, builtIn }

    var buttons: [ControlButton]
    var style: ControllerStyle
    var source: Source
}

/// Finds and saves button layouts. Lookup order: this game's layout for the pose, then the pose's
/// everyday layout, then the built-in one.
@MainActor
struct LayoutStore {
    let context: ModelContext

    nonisolated static func builtIn(pose: Pose) -> ResolvedLayout {
        ResolvedLayout(buttons: DefaultLayouts.buttons(for: pose), style: .xbox, source: .builtIn)
    }

    /// The saved record at exactly this level (nil `gameKey` = the pose's everyday layout).
    func saved(pose: Pose, gameKey: String?) -> ControlLayout? {
        let raw = pose.layoutPose.rawValue
        let descriptor = FetchDescriptor<ControlLayout>(predicate: #Predicate { $0.poseRaw == raw },
                                                        sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])
        return (try? context.fetch(descriptor))?.first { $0.gameKey == gameKey }
    }

    func resolve(pose: Pose, gameKey: String?) -> ResolvedLayout {
        if let gameKey, let layout = usable(saved(pose: pose, gameKey: gameKey)) {
            return ResolvedLayout(buttons: layout.buttons, style: layout.style, source: .game)
        }
        if let layout = usable(saved(pose: pose, gameKey: nil)) {
            return ResolvedLayout(buttons: layout.buttons, style: layout.style, source: .pose)
        }
        return Self.builtIn(pose: pose)
    }

    /// What a level falls back to without its own record: a game layout to the pose's, a pose layout
    /// to the built-in one.
    func fallback(pose: Pose, gameKey: String?) -> ResolvedLayout {
        gameKey == nil ? Self.builtIn(pose: pose) : resolve(pose: pose, gameKey: nil)
    }

    func save(buttons: [ControlButton], style: ControllerStyle, pose: Pose, gameKey: String?) throws {
        let data = try ControlLayout.encodeOrThrow(buttons)   // fail before touching anything
        if let existing = saved(pose: pose, gameKey: gameKey) {
            existing.buttonsData = data
            existing.updatedAt = .now
            existing.style = style
        } else {
            let title = pose.layoutPose.title
            context.insert(ControlLayout(name: gameKey == nil ? title : "\(title) · this game", pose: pose,
                                         style: style, gameKey: gameKey, buttons: buttons))
        }
        try context.save()
    }

    func reset(pose: Pose, gameKey: String?) throws {
        let raw = pose.layoutPose.rawValue
        let layouts = try context.fetch(FetchDescriptor<ControlLayout>(predicate: #Predicate { $0.poseRaw == raw }))
        for layout in layouts where layout.gameKey == gameKey {
            context.delete(layout)
        }
        try context.save()
    }

    /// One pose the user edited, and where its draft should live.
    struct PoseEdit: Equatable {
        var buttons: [ControlButton]
        var style: ControllerStyle
        /// True: save for this game only. False: save as the pose's everyday layout.
        var onlyThisGame: Bool
    }

    /// Saves exactly the edited poses and leaves every other pose alone. A game-only draft goes to the
    /// game level; an everyday draft goes to the pose level and removes that pose's game copy, which
    /// would otherwise hide it. A draft equal to what it falls back to is not stored.
    func commit(_ edits: [Pose: PoseEdit], gameKey: String?) throws {
        for (pose, edit) in edits {
            if let gameKey, edit.onlyThisGame {
                try apply(edit, pose: pose, gameKey: gameKey, fallback: fallback(pose: pose, gameKey: gameKey))
            } else {
                if let gameKey { try reset(pose: pose, gameKey: gameKey) }
                try apply(edit, pose: pose, gameKey: nil, fallback: Self.builtIn(pose: pose))
            }
        }
    }

    private func apply(_ edit: PoseEdit, pose: Pose, gameKey: String?, fallback: ResolvedLayout) throws {
        let action = LayoutEditing.saveAction(buttons: edit.buttons, style: edit.style,
                                              hasSaved: saved(pose: pose, gameKey: gameKey) != nil,
                                              fallback: fallback)
        switch action {
        case .save: try save(buttons: edit.buttons, style: edit.style, pose: pose, gameKey: gameKey)
        case .deleteSaved: try reset(pose: pose, gameKey: gameKey)
        case .nothing: break
        }
    }

    /// A record whose buttons can't be read is treated as missing rather than showing an empty pad.
    private func usable(_ layout: ControlLayout?) -> ControlLayout? {
        guard let layout, layout.hasReadableButtons else { return nil }
        return layout
    }
}
