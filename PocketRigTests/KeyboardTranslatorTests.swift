import Testing
@testable import PocketRig

@Suite struct KeyboardTranslatorTests {
    @Test func plainTextStaysTogether() {
        #expect(KeyboardTranslator.events(for: "hello") == [.text("hello")])
    }

    @Test func returnBecomesEnter() {
        #expect(KeyboardTranslator.events(for: "hi\nthere") == [.text("hi"), .key(.enter), .text("there")])
        #expect(KeyboardTranslator.events(for: "\r\n") == [.key(.enter)])
        #expect(KeyboardTranslator.events(for: "\r") == [.key(.enter)])
    }

    @Test func tabBecomesTheTabKey() {
        #expect(KeyboardTranslator.events(for: "a\tb") == [.text("a"), .key(.tab), .text("b")])
    }

    @Test func emojiPassThrough() {
        #expect(KeyboardTranslator.events(for: "👍") == [.text("👍")])
    }

    @Test func nothingTypedSendsNothing() {
        #expect(KeyboardTranslator.events(for: "").isEmpty)
    }

    @Test func keyCodesMatchWindows() {
        #expect(VirtualKey.enter.rawValue == 0x0D)
        #expect(VirtualKey.escape.rawValue == 0x1B)
        #expect(VirtualKey.volumeUp.rawValue == 0xAF)
        #expect(KeyModifiers.meta.rawValue == 8)
    }

    @Test func longTextIsChunkedToThirtyTwoBytes() {
        let text = String(repeating: "a", count: 70)
        let chunks = TextChunker.chunks(of: text)
        #expect(chunks.map(\.utf8.count) == [32, 32, 6])
        #expect(chunks.joined() == text)
    }

    @Test func chunksNeverSplitACharacter() {
        let text = String(repeating: "👍", count: 9) // 4 bytes each
        let chunks = TextChunker.chunks(of: text)
        #expect(chunks.allSatisfy { $0.utf8.count <= 32 })
        #expect(chunks.joined() == text)
        let accents = String(repeating: "e\u{301}", count: 20) // 3 bytes per character
        let accentChunks = TextChunker.chunks(of: accents)
        #expect(accentChunks.allSatisfy { $0.utf8.count <= 32 && $0.count == $0.unicodeScalars.count / 2 })
        #expect(accentChunks.joined() == accents)
    }

    @Test func hugeSingleCharactersSplitBetweenScalars() {
        let family = String(repeating: "👨\u{200D}👩\u{200D}👧\u{200D}👦\u{200D}", count: 2) + "👨"
        let chunks = TextChunker.chunks(of: family)
        #expect(chunks.allSatisfy { $0.utf8.count <= 32 })
        #expect(chunks.joined() == family)
    }

    @Test func emptyTextHasNoChunks() {
        #expect(TextChunker.chunks(of: "").isEmpty)
    }
}
