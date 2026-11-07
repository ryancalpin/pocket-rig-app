import Testing
@testable import PocketRig

@Suite struct CoverStatusTests {
    private let apps = [HostApp(id: 1, title: "Desktop", hdrSupported: false),
                        HostApp(id: 2, title: "Hades II", hdrSupported: false)]

    private func info(running: Int) -> ServerInfo {
        ServerInfo(hostname: "PC", appVersion: "7.1.431.-1", gfeVersion: "", uniqueID: "U", httpsPort: 47984,
                   macAddress: "", localIP: "", codecModeSupport: 1, isPaired: true, currentGameID: running,
                   isBusy: running != 0, maxLumaPixelsHEVC: 0)
    }

    @Test func aRunningGameCanBeResumed() {
        let status = CoverHostStatus.make(info: info(running: 2), apps: apps)
        #expect(status.text == "Online · Playing Hades II")
        #expect(status.runningAppID == 2)
        #expect(status.resumeTitle == "Resume Hades II")
        #expect(status.apps == apps)
    }

    @Test func nothingRunningHasNoResume() {
        let status = CoverHostStatus.make(info: info(running: 0), apps: apps)
        #expect(status.text == "Online · Nothing running")
        #expect(status.runningAppID == nil)
    }

    @Test func anUnlistedGameStillResumes() {
        let status = CoverHostStatus.make(info: info(running: 99), apps: apps)
        #expect(status.text == "Online · Playing a game")
        #expect(status.resumeTitle == "Resume game")
        #expect(status.runningAppID == 99)
    }

    @Test func failuresReadPlainly() {
        #expect(CoverHostStatus.failed(HostError.notPaired) == .needsPairing)
        #expect(CoverHostStatus.failed(HostError.unreachable) == .offline)
        #expect(CoverHostStatus.offline.text == "Offline · Make sure it's on")
        #expect(CoverHostStatus.needsPairing.text == "Needs pairing · Open your phone to pair")
        #expect(CoverHostStatus.checking.text == "Checking…")
        #expect(CoverHostStatus.offline.runningAppID == nil)
    }

    @Test func onlyStreamRoutesCount() {
        #expect(Route.stream(serverUniqueID: "U", appID: 1).isStream)
        #expect(!Route.apps(serverUniqueID: "U").isStream)
    }
}
