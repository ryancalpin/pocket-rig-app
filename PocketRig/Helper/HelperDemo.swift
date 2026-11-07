#if DEBUG
import Foundation

/// `-pr.helperDemo YES`: a stand-in Pocket Rig Helper for screenshots, no PC needed.
/// `-pr.helperDemoSteam notSetUp` makes it a PC where Steam was never signed in.
enum HelperDemo {
    static var isOn: Bool { DebugLaunchOptions.flag("helperDemo") }
    static var steamNotSetUp: Bool { DebugLaunchOptions.text("helperDemoSteam") == "notSetUp" }
    static let sampleMAC = "04:0e:3c:2a:36:94"

    static func client() -> HelperClient { HelperClient(requester: Requester()) }

    // The JSON below is fixed; `DownloadsCardTests.demoDataDecodes` (Task 9) proves it decodes.
    static var info: HelperInfo { try! JSONDecoder().decode(HelperInfo.self, from: Data(infoJSON.utf8)) }
    static var games: [HelperGame] { try! JSONDecoder().decode(Games.self, from: Data(gamesJSON.utf8)).games }
    static var downloads: [HelperDownload] {
        steamNotSetUp ? [] : try! JSONDecoder().decode(Downloads.self, from: Data(downloadsJSON.utf8)).downloads
    }

    private struct Games: Decodable { let games: [HelperGame] }
    private struct Downloads: Decodable { let downloads: [HelperDownload] }

    private static var infoJSON: String {
        steamNotSetUp
            ? #"{"apiVersion":1,"version":"0.4.0","hostname":"Gaming PC","capabilities":["sleep","restart","lock"],"steam":{"state":"notSetUp","running":false},"wake":{"mac":"04:0e:3c:2a:36:94","interface":"enp34s0","linkUp":true,"broadcast":"192.168.1.255"}}"#
            : #"{"apiVersion":1,"version":"0.4.0","hostname":"Gaming PC","capabilities":["library","downloads","install","play","restart-steam","close-game","sleep","restart","lock"],"steam":{"state":"ready","running":true,"runningAppID":1145350},"wake":{"mac":"04:0e:3c:2a:36:94","interface":"enp34s0","linkUp":true,"broadcast":"192.168.1.255"}}"#
    }

    private static func art(_ id: Int) -> String {
        #""artURL":"https://cdn.cloudflare.steamstatic.com/steam/apps/\#(id)/library_600x900.jpg","headerURL":"https://cdn.cloudflare.steamstatic.com/steam/apps/\#(id)/header.jpg""#
    }

    private static var gamesJSON: String {
        #"{"games":[{"appID":1145350,"name":"Hades II","state":"installed","sizeOnDisk":10737418240,"lastPlayed":1762300800,"bytesDownloaded":0,"bytesToDownload":0,\#(art(1145350))},{"appID":1086940,"name":"Baldur's Gate 3","state":"downloading","sizeOnDisk":0,"bytesDownloaded":51539607552,"bytesToDownload":128849018880,\#(art(1086940))},{"appID":413150,"name":"Stardew Valley","state":"installed","sizeOnDisk":681574400,"lastPlayed":1762128000,"bytesDownloaded":0,"bytesToDownload":0,\#(art(413150))},{"appID":2379780,"name":"Balatro","state":"installed","sizeOnDisk":157286400,"lastPlayed":1761955200,"bytesDownloaded":0,"bytesToDownload":0,\#(art(2379780))},{"appID":1245620,"name":"ELDEN RING","state":"installed","sizeOnDisk":53687091200,"lastPlayed":1760918400,"bytesDownloaded":0,"bytesToDownload":0,\#(art(1245620))},{"appID":1091500,"name":"Cyberpunk 2077","state":"queued","sizeOnDisk":0,"bytesDownloaded":0,"bytesToDownload":75161927680,\#(art(1091500))}]}"#
    }

    private static let downloadsJSON = #"{"downloads":[{"appID":1086940,"name":"Baldur's Gate 3","state":"downloading","bytesDownloaded":51539607552,"bytesToDownload":128849018880,"progress":0.4,"headerURL":"https://cdn.cloudflare.steamstatic.com/steam/apps/1086940/header.jpg"},{"appID":1091500,"name":"Cyberpunk 2077","state":"queued","bytesDownloaded":0,"bytesToDownload":75161927680,"progress":0,"headerURL":"https://cdn.cloudflare.steamstatic.com/steam/apps/1091500/header.jpg"}]}"#

    private struct Requester: HelperRequesting {
        func send(method: String, path: String, timeout: TimeInterval) async throws -> (Data, Int) {
            try await Task.sleep(for: .milliseconds(150))
            let notReady = #"{"error":"steam_not_ready","message":"Steam isn't set up on this PC yet."}"#
            let reply: (String, Int) = switch (method, path) {
            case ("GET", "/v1/info"): (HelperDemo.infoJSON, 200)
            case ("GET", "/v1/library"): HelperDemo.steamNotSetUp ? (notReady, 409) : (HelperDemo.gamesJSON, 200)
            case ("GET", "/v1/downloads"): HelperDemo.steamNotSetUp ? (notReady, 409) : (HelperDemo.downloadsJSON, 200)
            case ("POST", let p) where p.hasPrefix("/v1/install/"): (#"{"accepted":true,"confirmOnPC":true}"#, 202)
            case ("POST", _): (#"{"accepted":true}"#, 202)
            default: (#"{"error":"failed","message":"Not found."}"#, 404)
            }
            return (Data(reply.0.utf8), reply.1)
        }
    }
}
#endif
