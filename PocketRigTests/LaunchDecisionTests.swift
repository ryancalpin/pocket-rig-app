import Testing
@testable import PocketRig

struct LaunchDecisionTests {
    @Test func nothingRunningStarts() {
        #expect(LaunchDecision.decide(runningAppID: 0, selectedAppID: 5) == .start)
    }

    @Test func samePickedGameResumes() {
        #expect(LaunchDecision.decide(runningAppID: 5, selectedAppID: 5) == .resume)
    }

    @Test func differentGameAsksBeforeQuitting() {
        #expect(LaunchDecision.decide(runningAppID: 3, selectedAppID: 5) == .confirmQuit)
    }

    @Test func titleUsesRunningGameName() {
        #expect(LaunchDecision.confirmTitle(runningTitle: "Doom") == "Quit Doom on your PC?")
    }

    @Test func titleFallsBackWhenGameNotInList() {
        #expect(LaunchDecision.confirmTitle(runningTitle: nil) == "Quit the game that's running on your PC?")
    }
}
