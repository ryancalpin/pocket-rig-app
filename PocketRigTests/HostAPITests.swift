import Testing
import Foundation
@testable import PocketRig

final class StubRequester: HostRequesting, @unchecked Sendable {
    var responses: [String: String] = [:]          // path -> xml
    private(set) var calls: [(path: String, query: [URLQueryItem], secure: Bool)] = []
    func get(_ path: String, query: [URLQueryItem], secure: Bool, timeout: TimeInterval) async throws -> Data {
        calls.append((path, query, secure))
        guard let xml = responses[path] else { throw HostError.unreachable }
        return Data(xml.utf8)
    }
}

@Suite struct HostAPITests {
    @Test func launchSendsMoonlightParameters() async throws {
        let stub = StubRequester()
        stub.responses["/launch"] = #"<root status_code="200"><sessionUrl0>rtsp://10.0.0.2:48010</sessionUrl0><gamesession>1</gamesession></root>"#
        let api = HostAPI(requester: stub, uniqueID: "0123456789ABCDEF")
        let result = try await api.launch(appID: 881448767, mode: "1920x1080x60",
                                          riKey: Data(repeating: 0xAB, count: 16), riKeyID: 42,
                                          surroundAudioInfo: 196610, extraQuery: "&corever=1")
        #expect(result.sessionURL == "rtsp://10.0.0.2:48010")
        let call = try #require(stub.calls.last)
        #expect(call.secure)
        let q = Dictionary(uniqueKeysWithValues: call.query.map { ($0.name, $0.value ?? "") })
        #expect(q["appid"] == "881448767")
        #expect(q["mode"] == "1920x1080x60")
        #expect(q["rikey"] == String(repeating: "ab", count: 16))
        #expect(q["rikeyid"] == "42")
        #expect(q["sops"] == "0")
        #expect(q["localAudioPlayMode"] == "0")
        #expect(q["surroundAudioInfo"] == "196610")
        #expect(q["remoteControllersBitmap"] == "1")
        #expect(q["gcmap"] == "1")
        #expect(q["corever"] == "1")
        #expect(q["uniqueid"] == "0123456789ABCDEF")
    }

    @Test func appListUsesHTTPS() async throws {
        let stub = StubRequester()
        stub.responses["/applist"] = #"<root status_code="200"><App><AppTitle>Desktop</AppTitle><ID>1</ID><IsHdrSupported>0</IsHdrSupported></App></root>"#
        let apps = try await HostAPI(requester: stub, uniqueID: "U").appList()
        #expect(apps.map(\.title) == ["Desktop"])
        #expect(stub.calls.last?.secure == true)
    }
}
