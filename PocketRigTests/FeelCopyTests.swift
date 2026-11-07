import SwiftUI
import Testing
@testable import PocketRig

@Suite @MainActor struct FeelCopyTests {
    private func sentences(_ text: String) -> Int {
        text.split(whereSeparator: { ".!?".contains($0) })
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .count
    }

    @Test func everyNoteIsShortAndPlain() {
        let notes = [FeelSettingsSheet.vibrationFooter, FeelSettingsSheet.soundFooter, FeelSettingsSheet.noMotorNote]
            + GyroMode.allCases.map(FeelSettingsSheet.aimFooter(for:))
        for note in notes {
            #expect(!note.isEmpty)
            #expect(sentences(note) <= 2, "\(note)")
            #expect(!note.localizedCaseInsensitiveContains("error"))
        }
    }

    @Test func eachTiltChoiceExplainsItself() {
        #expect(Set(GyroMode.allCases.map(FeelSettingsSheet.aimFooter(for:))).count == GyroMode.allCases.count)
    }

    @Test func tapsDefaultToMedium() {
        #expect(EnvironmentValues().hapticsStrength == .medium)
    }

    @Test func tapsAreSafeAtAnyStrength() {
        let haptics = Haptics()
        for strength in HapticsStrength.allCases { haptics.tap(strength) }
    }
}
