import Foundation
import Testing
import UniformTypeIdentifiers
@testable import PocketRig

@Suite struct LayoutFileTests {
    private func file(_ buttons: [ControlButton] = DefaultLayouts.buttons(for: .laptop)) -> LayoutFile {
        LayoutFile(name: "Racing", pose: .laptop, style: .nintendo, buttons: buttons)
    }

    @Test func roundTrips() throws {
        let original = file()
        #expect(try LayoutFile.decode(original.encoded()) == original)
    }

    @Test func aNewerFileIsTurnedAwayPolitely() {
        let json = #"{"version":99,"name":"x","pose":"laptop","style":"xbox","buttons":[],"newThing":true}"#
        #expect(throws: LayoutFile.ImportError.newerVersion) { try LayoutFile.decode(Data(json.utf8)) }
    }

    @Test func somethingElseIsUnreadable() {
        #expect(throws: LayoutFile.ImportError.unreadable) { try LayoutFile.decode(Data("not json".utf8)) }
        #expect(throws: LayoutFile.ImportError.unreadable) { try LayoutFile.decode(Data(#"{"version":1}"#.utf8)) }
    }

    @Test func aLayoutWithNoButtonsIsRefused() throws {
        let empty = try file([]).encoded()
        #expect(throws: LayoutFile.ImportError.empty) { try LayoutFile.decode(empty) }
    }

    @Test func duplicateIDsAreMadeUnique() throws {
        var buttons = DefaultLayouts.buttons(for: .laptop)
        buttons[1].id = buttons[0].id
        let decoded = try LayoutFile.decode(file(buttons).encoded())
        #expect(Set(decoded.buttons.map(\.id)).count == buttons.count)
    }

    @Test func offScreenButtonsAreBroughtBack() throws {
        var buttons = DefaultLayouts.buttons(for: .laptop)
        buttons[0].frame.x = 1.4
        let decoded = try LayoutFile.decode(file(buttons).encoded())
        #expect(decoded.buttons[0].frame.x + decoded.buttons[0].frame.width <= 1.0001)
    }

    @Test func aCoverLayoutBecomesHalfFolded() throws {
        let cover = LayoutFile(name: "x", pose: .cover, style: .xbox, buttons: DefaultLayouts.buttons(for: .laptop))
        #expect(try LayoutFile.decode(cover.encoded()).pose == .laptop)
    }

    @Test func fileNamesAreSafe() {
        #expect(LayoutFile(name: "Racing: wheel/2", pose: .laptop, style: .xbox, buttons: []).fileName == "Racing wheel2.pocketriglayout")
        #expect(LayoutFile(name: "///", pose: .laptop, style: .xbox, buttons: []).fileName == "Layout.pocketriglayout")
    }

    @Test func importMessagesArePlain() {
        #expect(LayoutFile.ImportError.unreadable.message == "This file isn't a Pocket Rig button layout.")
        #expect(LayoutFile.ImportError.newerVersion.message.contains("Update"))
    }

    @Test func theFileTypeIsDeclared() {
        #expect(UTType.pocketRigLayout.preferredFilenameExtension == "pocketriglayout")
        #expect(UTType(filenameExtension: "pocketriglayout") == .pocketRigLayout)
        #expect(UTType.pocketRigLayout.conforms(to: .json))
    }

    // Shared files are untrusted input.
    @Test func tooManyButtonsAreRefused() throws {
        let one = DefaultLayouts.buttons(for: .laptop)[0]
        let many = (0..<(LayoutFile.maximumButtons + 1)).map { _ in
            ControlButton(kind: one.kind, frame: one.frame)
        }
        let data = try file(many).encoded()
        #expect(throws: LayoutFile.ImportError.unreadable) { try LayoutFile.decode(data) }
    }

    @Test func anOversizedFileIsRefused() {
        let data = Data(count: LayoutFile.maximumBytes + 1)
        #expect(throws: LayoutFile.ImportError.unreadable) { try LayoutFile.decode(data) }
    }

    @Test func garbageFramesAreRepaired() throws {
        let json = #"{"version":1,"name":"x","pose":"laptop","style":"xbox","buttons":[{"id":"\#(UUID().uuidString)","kind":"faceSouth","frame":{"x":-5,"y":9,"width":0,"height":-2}}]}"#
        let decoded = try LayoutFile.decode(Data(json.utf8))
        let f = decoded.buttons[0].frame
        #expect(f.x >= 0 && f.y >= 0 && f.x + f.width <= 1.0001 && f.y + f.height <= 1.0001)
        let size = DefaultLayouts.referenceSize(for: .laptop)
        #expect(f.width * size.width >= 43.9 && f.height * size.height >= 43.9)
    }

    @Test func unknownButtonsAreSkippedNotFatal() throws {
        let id = UUID().uuidString
        let json = #"{"version":1,"name":"x","pose":"laptop","style":"xbox","buttons":[{"id":"\#(id)","kind":"faceSouth","frame":{"x":0.1,"y":0.1,"width":0.2,"height":0.2}},{"kind":"warpDrive"}]}"#
        #expect(try LayoutFile.decode(Data(json.utf8)).buttons.count == 1)
    }
}
