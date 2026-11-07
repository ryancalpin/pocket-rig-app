import Foundation
import Testing
@testable import PocketRig

@Suite struct PCControlTests {
    private func sentences(_ text: String) -> Int {
        text.split(whereSeparator: { ".!?".contains($0) }).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count
    }

    @Test func everyControlHasPlainWords() {
        #expect(Set(PCControl.allCases.map(\.title)).count == PCControl.allCases.count)
        for control in PCControl.allCases {
            #expect(!control.title.isEmpty)
            #expect(!control.symbol.isEmpty)
            #expect(control.confirmTitle.hasSuffix("?"))
            #expect(!control.confirmButton.isEmpty)
            #expect(!control.doneMessage.isEmpty)
            for canWake in [true, false] {
                #expect(sentences(control.confirmMessage(canWake: canWake)) <= 2, "\(control)")
            }
        }
    }

    @Test func onlySleepAndRestartEndTheStream() {
        #expect(PCControl.allCases.filter(\.endsStream) == [.sleep, .restart])
    }

    @Test func lockIsTheOnlyGentleOne() {
        #expect(PCControl.allCases.filter { !$0.isDestructive } == [.lock])
    }

    @Test func sleepWarnsWhenThePhoneCantWakeThePC() {
        #expect(PCControl.sleep.confirmMessage(canWake: false).contains("power button"))
        #expect(!PCControl.sleep.confirmMessage(canWake: true).contains("power button"))
    }

    @Test func sleepOnlyPromisesWhatTheAppDoes() {
        let text = PCControl.sleep.confirmMessage(canWake: true)
        #expect(text.contains("Wake PC in Pocket Rig"))
        #expect(text.contains("while you're home"))
    }

    @Test func theNoteExplainsWhatsMissing() throws {
        #expect(PCControl.unavailableNote(for: .unknown)?.contains("Checking") == true)
        #expect(PCControl.unavailableNote(for: .absent)?.contains("Pocket Rig Helper") == true)
        let fresh = HelperStatus.present(try HelperFixtures.decode(HelperFixtures.freshInfo))
        #expect(PCControl.unavailableNote(for: fresh)?.contains("Steam") == true)
        let ready = HelperStatus.present(try HelperFixtures.decode(HelperFixtures.readyInfo))
        #expect(PCControl.unavailableNote(for: ready) == nil)
        let noPower = HelperStatus.present(try HelperFixtures.decode(
            #"{"apiVersion":1,"capabilities":["library","restart-steam","close-game","lock"],"steam":{"state":"ready"}}"#))
        #expect(PCControl.unavailableNote(for: noPower)?.contains("password") == true)
        let noDesktop = HelperStatus.present(try HelperFixtures.decode(
            #"{"apiVersion":1,"capabilities":["sleep","restart"],"steam":{"state":"ready"},"desktopReady":false}"#))
        let note = try #require(PCControl.unavailableNote(for: noDesktop))
        #expect(note.contains("desktop"))
        #expect(!note.contains("password"))
    }

    @Test func tilesFollowTheHelpersList() throws {
        let fresh = HelperStatus.present(try HelperFixtures.decode(HelperFixtures.freshInfo))
        #expect(PCControl.allCases.filter { fresh.can($0.capability) } == [.sleep, .restart, .lock])
        #expect(PCControl.allCases.filter { HelperStatus.absent.can($0.capability) }.isEmpty)
    }

    @Test func theStreamClosesJustBeforeThePCGoesAway() {
        // The Helper acts about half a second after it replies.
        #expect(PCControl.streamCloseDelay > .zero)
        #expect(PCControl.streamCloseDelay < .milliseconds(500))
    }
}

/// Wake PC is shared by the cover and the PC list.
@Suite @MainActor struct WakeCoordinatorTests {
    private func makeModel() throws -> AppModel {
        let g = try PairingCrypto.generateIdentity(p12Password: ClientIdentity.p12Password)
        let identity = ClientIdentity(certPEM: g.certPEM, keyPEM: g.keyPEM, p12: g.p12, uniqueID: "U")
        return AppModel(identity: identity, makeRequester: { _, _ in StubRequester() })
    }

    @Test func onlyAnOfflinePCWithAValidCardAddressIsOffered() {
        let mac = "04:0e:3c:2a:36:94"
        #expect(WakeCoordinator.canOffer(status: .offline, macAddress: mac))
        #expect(!WakeCoordinator.canOffer(status: .offline, macAddress: nil))
        #expect(!WakeCoordinator.canOffer(status: .offline, macAddress: "00:00:00:00:00:00"))
        #expect(!WakeCoordinator.canOffer(status: .checking, macAddress: mac))
        #expect(!WakeCoordinator.canOffer(status: nil, macAddress: mac))
        #expect(!WakeCoordinator.canOffer(status: .online(runningAppID: 0, runningTitle: nil, apps: []), macAddress: mac))
    }

    @Test func aPCWithNothingToSendToSaysSo() async throws {
        let model = try makeModel()
        let host = Host(serverUniqueID: "A", name: "Omen", lanAddress: "127.0.0.1", tailscaleAddress: nil)
        model.wakes.start(id: "A", host: host, model: model)
        #expect(model.wakes.isWaking("A"))
        #expect(model.wakes.notices["A"] == WakeOnLAN.wakingMessage)
        for _ in 0..<50 where model.wakes.isWaking("A") { try await Task.sleep(for: .milliseconds(20)) }
        #expect(!model.wakes.isWaking("A"))
        #expect(model.wakes.notices["A"] == WakeOnLAN.notSentMessage)
    }

    @Test func stoppingLeavesNoWakingLineBehind() async throws {
        let model = try makeModel()
        model.wakes.start(id: "demo", host: nil, model: model)   // a demo entry: message only
        model.wakes.stopAll()
        for _ in 0..<50 where model.wakes.isWaking("demo") { try await Task.sleep(for: .milliseconds(20)) }
        #expect(!model.wakes.isWaking("demo"))
    }
}
