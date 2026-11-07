import Foundation

/// Sends one request to Pocket Rig Helper and hands back the body and HTTP status.
protocol HelperRequesting: Sendable {
    func send(method: String, path: String, timeout: TimeInterval) async throws -> (Data, Int)
}

/// HTTPS to the Helper on port 47800, pinned to the PC's Sunshine certificate and presenting this
/// phone's paired identity, exactly like `HostHTTPClient` does for Sunshine.
///
/// Each request gets its own short-lived session and `TLSDelegate`. URLSession reports a failed pin check
/// to the session, not to the request, so a shared session could hand one request's mismatch to another.
final class HelperHTTPClient: HelperRequesting, @unchecked Sendable {
    static let port = 47800
    /// No request may take longer than this in total, whatever its own timeout says.
    static let overallTimeout: TimeInterval = 20

    private let address: String
    private let port: Int
    private let identity: ClientIdentity
    private let pinnedDER: Data
    private let configuration: URLSessionConfiguration

    /// `configuration` is for tests (a stub URLProtocol); the app uses the default.
    init?(address: String, port: Int = HelperHTTPClient.port, identity: ClientIdentity, pinnedServerCertDER: Data,
          configuration: URLSessionConfiguration = .ephemeral) {
        guard !address.isEmpty else { return nil }
        self.address = address
        self.port = port
        self.identity = identity
        pinnedDER = pinnedServerCertDER
        // URLSession copies its configuration, but tests hand us a shared one: copy before changing it.
        let config = (configuration.copy() as? URLSessionConfiguration) ?? configuration
        config.waitsForConnectivity = false
        config.timeoutIntervalForResource = Self.overallTimeout
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        self.configuration = config
    }

    func send(method: String, path: String, timeout: TimeInterval) async throws -> (Data, Int) {
        var comps = URLComponents()
        comps.scheme = "https"
        comps.host = address
        comps.port = port
        comps.path = path
        guard let url = comps.url else { throw HelperError.unreachable }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let delegate = TLSDelegate(identity: identity, pinnedDER: pinnedDER)
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw HelperError.badReply }
            return (data, http.statusCode)
        } catch let error as URLError {
            throw Self.mapped(error, pinMismatch: delegate.consumePinMismatch(), taskCancelled: Task.isCancelled)
        }
    }

    /// What a failed request means for the screen. Measured against a real Go Helper (TLS 1.3,
    /// `RequireAnyClientCert`): when the Helper refuses our certificate, URLSession reports
    /// `networkConnectionLost` (-1005), exactly like a connection dropped mid-request, so that can't be
    /// told apart and counts as unreachable. Only a failed pin check or an explicit client-certificate
    /// error is "not paired".
    static func mapped(_ error: URLError, pinMismatch: Bool, taskCancelled: Bool) -> any Error {
        if pinMismatch { return HelperError.notPaired }
        switch error.code {
        case .clientCertificateRejected, .clientCertificateRequired: return HelperError.notPaired
        case .cancelled where taskCancelled: return CancellationError()
        default: return HelperError.unreachable
        }
    }
}

/// The Helper's API v1 (see `docs/plans/2026-11-05-phase4-helper.md`, "Helper API v1").
struct HelperClient: Sendable {
    let requester: any HelperRequesting

    func info(timeout: TimeInterval = 5) async throws -> HelperInfo {
        try await call("GET", "/v1/info", timeout: timeout)
    }

    func library() async throws -> [HelperGame] {
        let reply: GamesReply = try await call("GET", "/v1/library", timeout: 10)
        return reply.games.items
    }

    func downloads() async throws -> [HelperDownload] {
        let reply: DownloadsReply = try await call("GET", "/v1/downloads", timeout: 10)
        return reply.downloads.items
    }

    func install(appID: Int) async throws -> HelperAccepted {
        let id = try Self.checked(appID)
        return try await call("POST", "/v1/install/\(id)", timeout: 15)
    }

    func play(appID: Int) async throws -> HelperAccepted {
        let id = try Self.checked(appID)
        return try await call("POST", "/v1/play/\(id)", timeout: 15)
    }

    func perform(_ control: PCControl) async throws {
        let _: HelperAccepted = try await call("POST", "/v1/actions/\(control.rawValue)", timeout: 10)
    }

    private struct GamesReply: Decodable { let games: LossyList<HelperGame> }
    private struct DownloadsReply: Decodable { let downloads: LossyList<HelperDownload> }
    private struct ErrorReply: Decodable { let error: String }

    /// Steam app IDs are 1…4294967295. Anything else never leaves the phone.
    private static func checked(_ appID: Int) throws -> Int {
        guard appID > 0, appID <= Int(UInt32.max) else { throw HelperError.refused(code: "bad_appid", status: 0) }
        return appID
    }

    private func call<T: Decodable>(_ method: String, _ path: String, timeout: TimeInterval) async throws -> T {
        let (data, status) = try await requester.send(method: method, path: path, timeout: timeout)
        guard (200..<300).contains(status) else {
            let code = (try? JSONDecoder().decode(ErrorReply.self, from: data))?.error ?? "failed"
            throw HelperError.refused(code: code, status: status)
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw HelperError.badReply
        }
    }
}

/// A JSON list where one malformed element is skipped instead of failing the whole list.
struct LossyList<Element: Decodable>: Decodable {
    let items: [Element]

    private struct Skip: Decodable {}

    init(from decoder: any Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var items: [Element] = []
        while !container.isAtEnd {
            if let item = try? container.decode(Element.self) {
                items.append(item)
            } else {
                _ = try? container.decode(Skip.self)
            }
        }
        self.items = items
    }
}
