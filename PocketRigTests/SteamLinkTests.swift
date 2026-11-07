import Foundation
import Testing
@testable import PocketRig

@Suite struct SteamLinkTests {
    @Test(arguments: [
        ("570", 570),
        (" 1145350 \n", 1145350),
        ("https://store.steampowered.com/app/1145350/Hades_II/", 1145350),
        ("https://store.steampowered.com/app/1145350/Hades_II/?snr=1_5_9__205", 1145350),
        ("http://store.steampowered.com/app/570", 570),
        ("https://steamcommunity.com/app/413150/reviews/", 413150),
        ("https://steamdb.info/app/2379780/", 2379780),
        ("https://s.team/a/1245620", 1245620),
        ("steam://install/570", 570),
        ("steam://run/570", 570),
        ("steam://rungameid/1091500", 1091500),
        ("steam://store/1086940", 1086940),
        ("Check out Hades II on Steam! https://store.steampowered.com/app/1145350/Hades_II/", 1145350),
        ("4294967295", 4294967295),
        ("https://store.steampowered.com/app/570)", 570),
        ("(see https://store.steampowered.com/app/570).", 570),
        ("<https://s.team/a/1245620>", 1245620),
        ("570.", 570),
    ])
    func readsSteamLinks(text: String, appID: Int) {
        #expect(SteamLink.appID(from: text) == appID)
    }

    @Test(arguments: [
        "", "0", "-5", "abc", "99999999999", "4294967296",
        "https://evil.example/app/570",
        "https://steampowered.com.evil.example/app/570",
        "https://notsteampowered.com/app/570",
        "https://store.steampowered.com/sub/123",
        "https://store.steampowered.com/app/abc",
        "steam://uninstall/570",
        "javascript:alert(570)",
        "570; rm -rf ~",
        "$(reboot)",
    ])
    func ignoresEverythingElse(text: String) {
        #expect(SteamLink.appID(from: text) == nil)
    }

    @Test func artComesFromSteamsCDN() {
        #expect(SteamArt.header(570).absoluteString == "https://cdn.cloudflare.steamstatic.com/steam/apps/570/header.jpg")
        #expect(SteamArt.portrait(570).absoluteString == "https://cdn.cloudflare.steamstatic.com/steam/apps/570/library_600x900.jpg")
    }

    @Test func playStreamsTheDesktopApp() {
        let apps = [HostApp(id: 1, title: "Steam Big Picture", hdrSupported: false),
                    HostApp(id: 2, title: "desktop", hdrSupported: false)]
        #expect(SteamPlay.desktopApp(in: apps)?.id == 2)
        #expect(SteamPlay.desktopApp(in: [apps[0]]) == nil)
        #expect(SteamPlay.noDesktopMessage.contains("Desktop"))
    }

    @Test func installedGamesComeFirstMostRecentlyPlayed() throws {
        let games: [HelperGame] = try HelperFixtures.decode(#"""
        [{"appID":1,"name":"Zed","state":"installed","lastPlayed":100},
         {"appID":2,"name":"Beta","state":"downloading","bytesDownloaded":1,"bytesToDownload":2},
         {"appID":3,"name":"Alpha","state":"installed"},
         {"appID":4,"name":"Mid","state":"installed","lastPlayed":300},
         {"appID":5,"name":"Able","state":"queued"}]
        """#)
        #expect(SteamPlay.sorted(games).map(\.appID) == [4, 1, 3, 5, 2])
    }

    @Test func steamNotReadyGetsAPlainNotice() throws {
        let fresh: HelperInfo = try HelperFixtures.decode(HelperFixtures.freshInfo)
        let notice = try #require(SteamGamesSection.notice(for: fresh, pcName: "Omen"))
        #expect(notice.title == "Steam isn't set up yet")
        #expect(notice.message.contains("Omen"))
        let missing: HelperInfo = try HelperFixtures.decode(#"{"apiVersion":1,"steam":{"state":"notInstalled"}}"#)
        #expect(SteamGamesSection.notice(for: missing, pcName: "Omen")?.title == "Steam isn't installed")
        let ready: HelperInfo = try HelperFixtures.decode(HelperFixtures.readyInfo)
        #expect(SteamGamesSection.notice(for: ready, pcName: "Omen") == nil)
    }

    @Test func playPlanFollowsOneRule() {
        let desktop = HostApp(id: 2, title: "Desktop", hdrSupported: false)
        let other = HostApp(id: 1, title: "Steam Big Picture", hdrSupported: false)
        #expect(SteamPlay.plan(apps: [other, desktop], runningAppID: 0, desktopReady: false) == .desktopNotReady)
        #expect(SteamPlay.plan(apps: [other], runningAppID: 0, desktopReady: true) == .noDesktop)
        #expect(SteamPlay.plan(apps: [other, desktop], runningAppID: 0, desktopReady: true) == .go(desktop: desktop, decision: .start))
        #expect(SteamPlay.plan(apps: [other, desktop], runningAppID: 2, desktopReady: true) == .go(desktop: desktop, decision: .resume))
        #expect(SteamPlay.plan(apps: [other, desktop], runningAppID: 1, desktopReady: true) == .go(desktop: desktop, decision: .confirmQuit))
    }

    @Test func libraryRefreshesQuicklyOnlyWhileSomethingDownloads() throws {
        let games: [HelperGame] = try HelperFixtures.decode(#"""
        [{"appID":1,"name":"A","state":"installed"},{"appID":2,"name":"B","state":"queued"}]
        """#)
        #expect(LibraryRefresh.interval(for: games) == .seconds(5))
        #expect(LibraryRefresh.interval(for: [games[0]]) == .seconds(30))
        #expect(LibraryRefresh.interval(for: []) == .seconds(30))
        #expect(LibraryRefresh.interval(for: nil) == .seconds(30))
    }

    @Test func installPhaseTransitions() {
        typealias P = InstallGameSheet.Phase
        #expect(P.editing.afterTextChange == .editing)
        #expect(P.failed("x").afterTextChange == .editing)
        #expect(P.sent(confirmOnPC: true).afterTextChange == .editing)
        #expect(P.sending.afterTextChange == .sending)
        #expect(P.sent(confirmOnPC: false).isSent)
        #expect(!P.editing.isSent)
    }
}
