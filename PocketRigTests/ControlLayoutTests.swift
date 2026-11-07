import CoreGraphics
import Foundation
import SwiftData
import Testing
@testable import PocketRig

@Suite struct ControlLayoutTests {
    @Test(arguments: Pose.layoutPoses)
    func builtInLayoutHasEveryControlOnce(pose: Pose) {
        let kinds = DefaultLayouts.buttons(for: pose).map(\.kind)
        #expect(kinds.count == ControlKind.allCases.count)
        #expect(Set(kinds) == Set(ControlKind.allCases))
    }

    @Test(arguments: Pose.layoutPoses)
    func builtInLayoutFitsAndIsTappable(pose: Pose) {
        let size = DefaultLayouts.referenceSize(for: pose)
        let rects = DefaultLayouts.buttons(for: pose).map { $0.frame.rect(in: size) }
        for rect in rects {
            #expect(rect.minX >= 0 && rect.minY >= 0 && rect.maxX <= size.width + 0.01 && rect.maxY <= size.height + 0.01)
            #expect(rect.width >= 44 - 0.01 && rect.height >= 44 - 0.01)
        }
        for (i, a) in rects.enumerated() {
            for b in rects[(i + 1)...] {
                let overlap = a.intersection(b)
                #expect(overlap.isNull || overlap.width < 0.5 || overlap.height < 0.5, "\(pose): \(a) overlaps \(b)")
                let gapX = max(a.minX - b.maxX, b.minX - a.maxX), gapY = max(a.minY - b.maxY, b.minY - a.maxY)
                #expect(max(gapX, gapY) >= 4 - 0.01, "\(pose): \(a) is too close to \(b)")
            }
        }
    }

    @Test func builtInIDsAreStable() {
        #expect(DefaultLayouts.buttons(for: .laptop) == DefaultLayouts.buttons(for: .laptop))
        let laptop = DefaultLayouts.buttons(for: .laptop), book = DefaultLayouts.buttons(for: .book)
        #expect(zip(laptop, book).allSatisfy { $0.id != $1.id })
        let all = Pose.layoutPoses.flatMap { DefaultLayouts.buttons(for: $0).map(\.id) }
        #expect(Set(all).count == all.count)
    }

    private func layout(with data: Data) -> ControlLayout {
        let layout = ControlLayout(name: "T", pose: .laptop, style: .xbox, buttons: [])
        layout.buttonsData = data
        return layout
    }

    @Test func unknownKindKeepsTheGoodButtons() throws {
        let good = DefaultLayouts.buttons(for: .laptop).prefix(2)
        let goodJSON = try JSONEncoder().encode(Array(good))
        var array = try #require(try JSONSerialization.jsonObject(with: goodJSON) as? [[String: Any]])
        var bad = array[0]
        bad["kind"] = "holographicButton"
        array.insert(bad, at: 1)
        let data = try JSONSerialization.data(withJSONObject: array)
        let l = layout(with: data)
        #expect(l.buttons == Array(good))
        #expect(l.buttonsData == data)
    }

    @Test func garbageDataFallsBackToDefaults() {
        let l = layout(with: Data("not json".utf8))
        #expect(l.buttons == DefaultLayouts.buttons(for: .laptop))
        let empty = layout(with: Data("[]".utf8))
        #expect(empty.buttons == DefaultLayouts.buttons(for: .laptop))
    }

    @Test func decodedFramesAreRepaired() throws {
        let json = #"{"id":"00000000-0000-4000-8000-000000000001","kind":"faceSouth","frame":{"x":-3,"y":9,"width":50,"height":-1}}"#
        let f = try JSONDecoder().decode(ControlButton.self, from: Data(json.utf8)).frame
        #expect(f.width == 1 && f.height == 0.01)
        #expect(f.x == 0 && abs(f.y - 0.99) < 0.0001)
    }

    @Test func sidewaysButtonsAreSeeThrough() {
        #expect(DefaultLayouts.buttons(for: .sideways).allSatisfy { $0.opacity == 0.4 })
        #expect(DefaultLayouts.buttons(for: .upright).allSatisfy { $0.opacity == 1 })
    }

    @Test func coverBorrowsTheHalfFoldedLayout() {
        #expect(DefaultLayouts.buttons(for: .cover) == DefaultLayouts.buttons(for: .laptop))
    }

    @Test func normalizedRectRoundTrips() {
        let size = CGSize(width: 669, height: 634)
        let rect = CGRect(x: 40, y: 80, width: 160, height: 160)
        let back = NormalizedRect(rect, in: size).rect(in: size)
        #expect(abs(back.minX - 40) < 0.001 && abs(back.width - 160) < 0.001)
    }

    @Test func clampingKeepsButtonsOnScreenAndTappable() {
        let size = CGSize(width: 500, height: 500)
        let clamped = NormalizedRect(x: 0.95, y: -0.2, width: 0.01, height: 0.5).clamped(in: size)
        #expect(abs(clamped.width - 44.0 / 500) < 0.0001)
        #expect(abs(clamped.x - (1 - 44.0 / 500)) < 0.0001)
        #expect(clamped.y == 0)
    }

    @Test func decodingFillsInMissingFieldsAndIgnoresNewOnes() throws {
        let json = #"{"id":"00000000-0000-4000-8000-000000000001","kind":"faceSouth","frame":{"x":0.1,"y":0.1,"width":0.1,"height":0.1},"turbo":true}"#
        let button = try JSONDecoder().decode(ControlButton.self, from: Data(json.utf8))
        #expect(button.opacity == 1)
        #expect(!button.isHidden)
        #expect(button.kind == .faceSouth)
    }

    @Test func opacityNeverDropsBelowTheFloor() throws {
        let json = #"{"id":"00000000-0000-4000-8000-000000000001","kind":"faceSouth","frame":{"x":0,"y":0,"width":0.1,"height":0.1},"opacity":0}"#
        let button = try JSONDecoder().decode(ControlButton.self, from: Data(json.utf8))
        #expect(button.opacity == ControlButton.minimumOpacity)
    }

    @Test func nintendoSwapsAAndB() {
        #expect(ControllerStyle.xbox.input(for: .faceSouth) == .button(.a))
        #expect(ControllerStyle.nintendo.input(for: .faceSouth) == .button(.b))
        #expect(ControllerStyle.nintendo.input(for: .faceEast) == .button(.a))
        #expect(ControllerStyle.nintendo.input(for: .faceWest) == .button(.y))
        #expect(ControllerStyle.nintendo.face(for: .faceEast).title == "A")
        #expect(ControllerStyle.xbox.face(for: .faceEast).title == "B")
    }

    @Test func playStationUsesShapes() {
        let cross = ControllerStyle.playStation.face(for: .faceSouth)
        #expect(cross.symbol == "xmark")
        #expect(cross.name == "Cross button")
        #expect(ControllerStyle.playStation.face(for: .leftBumper).title == "L1")
        #expect(ControllerStyle.playStation.input(for: .faceSouth) == .button(.a))
    }

    @Test func controlsMapToTheirInputs() {
        #expect(ControllerStyle.xbox.input(for: .leftTrigger) == .trigger(left: true))
        #expect(ControllerStyle.xbox.input(for: .rightStick) == .stick(left: false))
        #expect(ControllerStyle.xbox.input(for: .dpad) == .dpad)
        #expect(ControllerStyle.xbox.input(for: .guide) == .button(.guide))
        #expect(ControllerStyle.xbox.input(for: .leftStickClick) == .button(.leftStick))
    }

    @Test func gameKeyJoinsPCAndApp() {
        #expect(ControlLayout.gameKey(serverUniqueID: "ABC", appID: 7) == "ABC/7")
    }

    @Test @MainActor func layoutSurvivesSaving() throws {
        let container = try ModelContainer(for: ControlLayout.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        var buttons = DefaultLayouts.buttons(for: .laptop)
        buttons[0].opacity = 0.5
        context.insert(ControlLayout(name: "Mine", pose: .laptop, style: .nintendo, gameKey: "ABC/7", buttons: buttons))
        try context.save()
        let loaded = try #require(try context.fetch(FetchDescriptor<ControlLayout>()).first)
        #expect(loaded.pose == .laptop)
        #expect(loaded.style == .nintendo)
        #expect(loaded.gameKey == "ABC/7")
        #expect(loaded.buttons == buttons)
        #expect(loaded.formatVersion == ControlLayout.currentFormatVersion)
    }
}
