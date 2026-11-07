import Foundation
import Testing
@testable import PocketRig

/// The Helper's golden replies, written by the Go tests into `helper/testdata/contract`.
enum HelperContract {
    static var folder: URL {
        Bundle(for: BundleToken.self).resourceURL!.appendingPathComponent("contract", isDirectory: true)
    }

    private final class BundleToken {}

    static func names(prefix: String) -> [String] {
        let all = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return all.filter { $0.hasPrefix(prefix) && $0.hasSuffix(".json") }.sorted()
    }

    static func text(_ name: String) throws -> String {
        try String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8)
    }

    /// Every error code the Helper can send, taken from the golden `error-<code>.json` files.
    static var errorCodes: [String] {
        names(prefix: "error-").map { String($0.dropFirst("error-".count).dropLast(".json".count)) }
    }
}

@Suite struct HelperContractTests {
    private func client(_ status: Int, _ body: String) -> HelperClient {
        HelperClient(requester: FakeHelperRequester(replies: [
            "GET /v1/info": (body, status), "GET /v1/library": (body, status), "GET /v1/downloads": (body, status),
            "POST /v1/install/5": (body, status), "POST /v1/play/5": (body, status),
            "POST /v1/actions/lock": (body, status),
        ]))
    }

    @Test func theGoldenFolderIsInTheTestBundle() {
        #expect(HelperContract.names(prefix: "").count >= 15)
        #expect(HelperContract.errorCodes.count >= 12)
    }

    @Test func everyInfoFileDecodes() throws {
        let names = HelperContract.names(prefix: "info-")
        #expect(names.count >= 3)
        for name in names {
            let info = try HelperFixtures.decode(try HelperContract.text(name), as: HelperInfo.self)
            #expect(info.apiVersion == 1, "\(name)")
            #expect(!info.hostname.isEmpty, "\(name)")
        }
        let full = try HelperFixtures.decode(try HelperContract.text("info-full.json"), as: HelperInfo.self)
        #expect(full.canWake && full.wake?.mac == "04:0e:3c:2a:36:94")
        #expect(full.desktopReady == true)
        #expect(full.can(.library) && full.can(.sleep) && full.can(.lock))
        let noWake = try HelperFixtures.decode(try HelperContract.text("info-nowake.json"), as: HelperInfo.self)
        #expect(noWake.wake == nil && !noWake.canWake)
        let noDesktop = try HelperFixtures.decode(try HelperContract.text("info-nodesktop.json"), as: HelperInfo.self)
        #expect(noDesktop.desktopReady == false)
        #expect(PCControl.unavailableNote(for: .present(noDesktop))?.contains("desktop") == true)
    }

    @Test func libraryAndDownloadsDecode() async throws {
        let games = try await client(200, try HelperContract.text("library.json")).library()
        #expect(games.count == 3)
        let pending = try #require(games.first { $0.appID == 730 })
        #expect(pending.state == .installed && pending.updatePending)
        #expect(pending.statusText == "Update ready")
        #expect(games.filter { $0.state != .unknown }.count == games.count)
        #expect(games.allSatisfy { !$0.artURLs.isEmpty })
        let downloads = try await client(200, try HelperContract.text("downloads.json")).downloads()
        #expect(downloads.map(\.appID) == [570])
        #expect(downloads[0].state == .downloading)
    }

    @Test func acceptedRepliesDecode() async throws {
        let install = try await client(202, try HelperContract.text("accepted-install.json")).install(appID: 5)
        #expect(install.accepted && install.confirmOnPC == true)
        let play = try await client(202, try HelperContract.text("accepted-play.json")).play(appID: 5)
        #expect(play.accepted)
    }

    @Test func everyErrorCodeReachesThePhoneAsAPlainMessage() async throws {
        let generic = HelperError.refused(code: "failed", status: 0).message
        for code in HelperContract.errorCodes {
            let body = try HelperContract.text("error-\(code).json")
            let c = client(409, body)
            do {
                _ = try await c.library()
                Issue.record("\(code) should have thrown")
            } catch let error as HelperError {
                #expect(error == .refused(code: code, status: 409), "\(code)")
                if code != "failed" { #expect(error.message != generic, "\(code) falls through to the generic message") }
                #expect(!error.message.isEmpty)
            }
        }
    }
}
