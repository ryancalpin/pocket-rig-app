import Foundation
import SwiftData
import Testing
@testable import PocketRig

@Suite @MainActor struct FeelSettingsTests {
    private func context() throws -> ModelContext {
        let container = try ModelContainer(for: FeelSettings.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return ModelContext(container)
    }

    @Test func startsGentleWithTheExtrasOff() throws {
        let s = FeelSettings.current(in: try context()).snapshot
        #expect(s == FeelSnapshot())
        #expect(s.strength == .medium)
        #expect(!s.feelTheSound)
        #expect(s.gyroMode == .off)
        #expect(s.gyroSensitivity == 1)
        #expect(!s.gyroInvertY)
    }

    @Test func currentReusesTheSavedRecord() throws {
        let context = try context()
        FeelSettings.current(in: context).hapticsStrength = .high
        #expect(FeelSettings.current(in: context).hapticsStrength == .high)
        #expect(try context.fetchCount(FetchDescriptor<FeelSettings>()) == 1)
    }

    @Test func unknownStoredValuesReadAsDefaults() {
        let s = FeelSettings()
        s.hapticsStrengthRaw = "ludicrous"
        s.gyroModeRaw = "telepathy"
        #expect(s.hapticsStrength == .medium)
        #expect(s.gyroMode == .off)
    }

    @Test func strengthScalesFromSilentToFull() {
        #expect(HapticsStrength.allCases == [.off, .low, .medium, .high])
        #expect(HapticsStrength.off.scale == 0)
        #expect(HapticsStrength.low.scale < HapticsStrength.medium.scale)
        #expect(HapticsStrength.medium.scale < HapticsStrength.high.scale)
        #expect(HapticsStrength.high.scale == 1)
    }

    @Test func offMeansNoTaps() {
        #expect(HapticsStrength.off.tapIntensity == nil)
        #expect(HapticsStrength.high.tapIntensity == 1)
        #expect((HapticsStrength.low.tapIntensity ?? 0) < (HapticsStrength.medium.tapIntensity ?? 0))
    }

    @Test func sensitivityStaysInRange() {
        let s = FeelSettings()
        s.gyroSensitivity = 10
        #expect(s.snapshot.gyroSensitivity == 3)
        s.gyroSensitivity = .nan
        #expect(s.snapshot.gyroSensitivity == 1)
        s.gyroSensitivity = 0
        #expect(s.snapshot.gyroSensitivity == 0.25)
    }

    @Test func sensitivityTitlesAreShort() {
        let us = Locale(identifier: "en_US")
        #expect(FeelSettings.sensitivityTitle(1, locale: us) == "1×")
        #expect(FeelSettings.sensitivityTitle(0.5, locale: us) == "0.5×")
        #expect(FeelSettings.sensitivityTitle(2.25, locale: us) == "2.25×")
    }

    @Test func soundIsOnlyHeardWhenThePhoneMayVibrate() {
        #expect(FeelSnapshot(strength: .medium, feelTheSound: true).listensToSound)
        #expect(!FeelSnapshot(strength: .off, feelTheSound: true).listensToSound)
        #expect(!FeelSnapshot(strength: .high, feelTheSound: false).listensToSound)
    }

    @Test func tiltChoicesArePlain() {
        #expect(GyroMode.allCases.map(\.title) == ["Off", "Right stick", "Mouse"])
        #expect(HapticsStrength.allCases.map(\.title) == ["Off", "Low", "Medium", "High"])
    }
}
