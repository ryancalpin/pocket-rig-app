import Foundation
import SwiftData
import Testing
@testable import PocketRig

@Suite @MainActor struct LayoutStoreTests {
    private let game = "PC1/7"

    private func store() throws -> LayoutStore {
        let container = try ModelContainer(for: ControlLayout.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return LayoutStore(context: ModelContext(container))
    }

    private func moved(_ pose: Pose) -> [ControlButton] {
        var buttons = DefaultLayouts.buttons(for: pose)
        buttons[0].frame.x += 0.05
        return buttons
    }

    @Test func nothingSavedUsesTheBuiltInLayout() throws {
        let resolved = try store().resolve(pose: .laptop, gameKey: game)
        #expect(resolved == LayoutStore.builtIn(pose: .laptop))
        #expect(resolved.source == .builtIn)
        #expect(resolved.style == .xbox)
    }

    @Test func aPoseLayoutAppliesToEveryGame() throws {
        let store = try store()
        try store.save(buttons: moved(.laptop), style: .nintendo, pose: .laptop, gameKey: nil)
        #expect(store.resolve(pose: .laptop, gameKey: nil).source == .pose)
        let forGame = store.resolve(pose: .laptop, gameKey: game)
        #expect(forGame.source == .pose)
        #expect(forGame.style == .nintendo)
    }

    @Test func aGameLayoutWinsForThatGameOnly() throws {
        let store = try store()
        try store.save(buttons: moved(.laptop), style: .xbox, pose: .laptop, gameKey: nil)
        try store.save(buttons: moved(.laptop), style: .playStation, pose: .laptop, gameKey: game)
        #expect(store.resolve(pose: .laptop, gameKey: game).source == .game)
        #expect(store.resolve(pose: .laptop, gameKey: game).style == .playStation)
        #expect(store.resolve(pose: .laptop, gameKey: "PC1/8").source == .pose)
    }

    @Test func fallbackIsOneLevelDown() throws {
        let store = try store()
        try store.save(buttons: moved(.book), style: .nintendo, pose: .book, gameKey: nil)
        #expect(store.fallback(pose: .book, gameKey: game).source == .pose)
        #expect(store.fallback(pose: .book, gameKey: nil) == LayoutStore.builtIn(pose: .book))
    }

    @Test func resettingAGameLayoutFallsBackToThePose() throws {
        let store = try store()
        try store.save(buttons: moved(.upright), style: .xbox, pose: .upright, gameKey: nil)
        try store.save(buttons: moved(.upright), style: .nintendo, pose: .upright, gameKey: game)
        try store.reset(pose: .upright, gameKey: game)
        #expect(store.resolve(pose: .upright, gameKey: game).source == .pose)
        #expect(store.saved(pose: .upright, gameKey: nil) != nil)
    }

    @Test func savingAgainUpdatesInPlace() throws {
        let store = try store()
        try store.save(buttons: moved(.sideways), style: .xbox, pose: .sideways, gameKey: nil)
        try store.save(buttons: DefaultLayouts.buttons(for: .sideways), style: .nintendo, pose: .sideways, gameKey: nil)
        #expect(try store.context.fetchCount(FetchDescriptor<ControlLayout>()) == 1)
        #expect(store.resolve(pose: .sideways, gameKey: nil).style == .nintendo)
    }

    @Test func posesKeepTheirOwnLayouts() throws {
        let store = try store()
        try store.save(buttons: moved(.laptop), style: .nintendo, pose: .laptop, gameKey: nil)
        #expect(store.resolve(pose: .book, gameKey: nil).source == .builtIn)
    }

    @Test func theCoverScreenUsesTheHalfFoldedLayout() throws {
        let store = try store()
        try store.save(buttons: moved(.laptop), style: .nintendo, pose: .laptop, gameKey: nil)
        #expect(store.resolve(pose: .cover, gameKey: nil).style == .nintendo)
    }

    // MARK: Scope (commit)

    @Test func gameOnlyEditSavesJustThatPoseAtGameLevel() throws {
        let store = try store()
        let edit = LayoutStore.PoseEdit(buttons: moved(.upright), style: .nintendo, onlyThisGame: true)
        try store.commit([.upright: edit], gameKey: game)
        #expect(store.saved(pose: .upright, gameKey: game) != nil)
        #expect(store.saved(pose: .upright, gameKey: nil) == nil)
        #expect(store.resolve(pose: .upright, gameKey: "PC1/8").source == .builtIn)
    }

    @Test func turningGameOnlyOffMovesTheEditedDraftToEveryday() throws {
        let store = try store()
        var stale = moved(.laptop)
        stale[1].frame.x += 0.1
        try store.save(buttons: stale, style: .playStation, pose: .laptop, gameKey: game)
        try store.save(buttons: DefaultLayouts.buttons(for: .laptop), style: .nintendo, pose: .laptop, gameKey: nil)
        let edited = moved(.laptop)
        try store.commit([.laptop: .init(buttons: edited, style: .xbox, onlyThisGame: false)], gameKey: game)
        #expect(store.saved(pose: .laptop, gameKey: game) == nil)
        let everyday = try #require(store.saved(pose: .laptop, gameKey: nil))
        #expect(everyday.buttons == edited)
        #expect(everyday.style == .xbox)
    }

    @Test func unvisitedPosesAreUntouched() throws {
        let store = try store()
        try store.save(buttons: moved(.book), style: .nintendo, pose: .book, gameKey: game)
        try store.save(buttons: moved(.sideways), style: .playStation, pose: .sideways, gameKey: nil)
        try store.commit([.laptop: .init(buttons: moved(.laptop), style: .xbox, onlyThisGame: false)], gameKey: game)
        #expect(store.saved(pose: .book, gameKey: game)?.style == .nintendo)
        #expect(store.saved(pose: .sideways, gameKey: nil)?.style == .playStation)
        #expect(try store.context.fetchCount(FetchDescriptor<ControlLayout>()) == 3)
    }

    // MARK: Corrupt data

    @Test func aCorruptGameLayoutFallsThroughToThePoseLayout() throws {
        let store = try store()
        try store.save(buttons: moved(.upright), style: .nintendo, pose: .upright, gameKey: nil)
        try store.save(buttons: moved(.upright), style: .playStation, pose: .upright, gameKey: game)
        let gameLayout = try #require(store.saved(pose: .upright, gameKey: game))
        gameLayout.buttonsData = Data("not json".utf8)
        #expect(!gameLayout.hasReadableButtons)
        let resolved = store.resolve(pose: .upright, gameKey: game)
        #expect(resolved.source == .pose)
        #expect(resolved.style == .nintendo)
    }
}
