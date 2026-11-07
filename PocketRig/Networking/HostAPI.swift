import Foundation

struct LaunchResult: Sendable, Equatable { let sessionURL: String? }

struct HostAPI: Sendable {
    private let requester: HostRequesting
    private let uniqueID: String

    init(requester: HostRequesting, uniqueID: String) {
        self.requester = requester
        self.uniqueID = uniqueID
    }

    func serverInfo(secure: Bool) async throws -> ServerInfo {
        let data = try await requester.get("/serverinfo", query: [], secure: secure, timeout: 5)
        return try ServerInfo(NvXML.parse(data).requireOK())
    }

    func appList() async throws -> [HostApp] {
        let data = try await requester.get("/applist", query: [], secure: true, timeout: 10)
        return try NvXML.parse(data).requireOK().apps
    }

    func appArtURL(appID: Int) -> (path: String, query: [URLQueryItem]) {
        ("/appasset", [URLQueryItem(name: "appid", value: String(appID)),
                       URLQueryItem(name: "AssetType", value: "2"),
                       URLQueryItem(name: "AssetIdx", value: "0")])
    }

    func appArt(appID: Int) async throws -> Data {
        let u = appArtURL(appID: appID)
        return try await requester.get(u.path, query: u.query, secure: true, timeout: 10)
    }

    func launch(appID: Int, mode: String, riKey: Data, riKeyID: Int32, surroundAudioInfo: Int32,
                extraQuery: String) async throws -> LaunchResult {
        var q = [URLQueryItem(name: "appid", value: String(appID)),
                 URLQueryItem(name: "mode", value: mode),
                 URLQueryItem(name: "additionalStates", value: "1"),
                 URLQueryItem(name: "sops", value: "0")]
        q += sessionItems(riKey: riKey, riKeyID: riKeyID, surroundAudioInfo: surroundAudioInfo, extraQuery: extraQuery)
        return try await send("/launch", q)
    }

    /// `mode` (e.g. "1552x1080x60") tells Sunshine the new size when rejoining after a resize. Sunshine
    /// sizes the encoder from the stream setup either way; this keeps its records in step.
    func resume(riKey: Data, riKeyID: Int32, surroundAudioInfo: Int32, extraQuery: String,
                mode: String? = nil) async throws -> LaunchResult {
        var q = sessionItems(riKey: riKey, riKeyID: riKeyID, surroundAudioInfo: surroundAudioInfo, extraQuery: extraQuery)
        if let mode { q.append(URLQueryItem(name: "mode", value: mode)) }
        return try await send("/resume", q)
    }

    func cancel() async throws {
        let data = try await requester.get("/cancel", query: [], secure: true, timeout: 10)
        try NvXML.parse(data).requireOK()
    }

    private func sessionItems(riKey: Data, riKeyID: Int32, surroundAudioInfo: Int32, extraQuery: String) -> [URLQueryItem] {
        var q = [URLQueryItem(name: "uniqueid", value: uniqueID),
                 URLQueryItem(name: "rikey", value: riKey.hexString),
                 URLQueryItem(name: "rikeyid", value: String(riKeyID)),
                 URLQueryItem(name: "localAudioPlayMode", value: "0"),
                 URLQueryItem(name: "surroundAudioInfo", value: String(surroundAudioInfo)),
                 URLQueryItem(name: "remoteControllersBitmap", value: "1"),
                 URLQueryItem(name: "gcmap", value: "1")]
        for pair in extraQuery.split(separator: "&") where !pair.isEmpty {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            q.append(URLQueryItem(name: String(parts[0]), value: parts.count > 1 ? String(parts[1]) : ""))
        }
        return q
    }

    private func send(_ path: String, _ query: [URLQueryItem]) async throws -> LaunchResult {
        let data = try await requester.get(path, query: query, secure: true, timeout: 30)
        let doc = try NvXML.parse(data).requireOK()
        if doc.values["gamesession"] == "0" { throw HostError.status(0, "Launch failed") }
        return LaunchResult(sessionURL: doc.values["sessionUrl0"])
    }
}
