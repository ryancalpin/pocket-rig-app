import SwiftData
import Testing
@testable import PocketRig

@Suite @MainActor struct StreamPreferencesTests {
    private func context() throws -> ModelContext {
        let container = try ModelContainer(for: StreamPreferences.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return ModelContext(container)
    }

    @Test func startsAt1080p60Balanced() throws {
        let prefs = StreamPreferences.current(in: try context())
        #expect(prefs.resolutionCap == .p1080)
        #expect(prefs.fps == 60)
        #expect(prefs.bitrateKbps == 20_000)
    }

    @Test func currentReusesTheSavedRecord() throws {
        let context = try context()
        let first = StreamPreferences.current(in: context)
        first.fps = 30
        let second = StreamPreferences.current(in: context)
        #expect(second.fps == 30)
        #expect(try context.fetchCount(FetchDescriptor<StreamPreferences>()) == 1)
    }

    @Test func offers120OnlyOnFastScreens() {
        #expect(StreamPreferences.frameRates(screenMaxFPS: 120) == [30, 60, 120])
        #expect(StreamPreferences.frameRates(screenMaxFPS: 60) == [30, 60])
    }

    @Test func aSlowScreenCaps120Down() {
        let prefs = StreamPreferences(fps: 120)
        #expect(prefs.effectiveFPS(screenMaxFPS: 60) == 60)
        #expect(prefs.effectiveFPS(screenMaxFPS: 120) == 120)
    }

    @Test func buildsStreamSettings() {
        let prefs = StreamPreferences(resolutionCap: .p720, fps: 30, bitrateKbps: 10_000)
        let settings = prefs.streamSettings(size: PixelSize(width: 1016, height: 720), screenMaxFPS: 120, audioEnabled: false)
        #expect(settings == StreamSettings(width: 1016, height: 720, fps: 30, bitrateKbps: 10_000, audioEnabled: false))
    }

    @Test func bitrateTitlesArePlain() {
        #expect(StreamPreferences.bitrateTitle(20_000) == "Balanced · 20 Mbps")
        #expect(StreamPreferences.bitrateTitle(10_000) == "Data saver · 10 Mbps")
        #expect(StreamPreferences.bitrateTitle(12_000) == "12 Mbps")
        #expect(StreamPreferences.bitrateChoices == [10_000, 20_000, 35_000, 50_000])
    }

    @Test func anUnknownCapReadsAs1080() {
        let prefs = StreamPreferences()
        prefs.resolutionCapRaw = "p4k"
        #expect(prefs.resolutionCap == .p1080)
    }

    @Test func awayFromHomeAndOverheatStartWithSafeDefaults() throws {
        let prefs = StreamPreferences.current(in: try context())
        #expect(prefs.awayBitrateKbpsRaw == nil)
        #expect(prefs.awayBitrateKbps == 10_000)
        #expect(prefs.heatProtection)
        prefs.awayBitrateKbps = 0
        prefs.heatProtection = false
        #expect(prefs.awayBitrateKbpsRaw == 0)
        #expect(prefs.heatProtectionRaw == false)
    }

    @Test func awayChoicesHavePlainTitles() {
        #expect(StreamPreferences.awayBitrateChoices == [5_000, 10_000, 0])
        #expect(StreamPreferences.awayBitrateTitle(5_000) == "Data saver · 5 Mbps")
        #expect(StreamPreferences.awayBitrateTitle(10_000) == "Balanced · 10 Mbps")
        #expect(StreamPreferences.awayBitrateTitle(0) == "Same as at home")
    }
}
