import Foundation
import Security

protocol HostRequesting: Sendable {
    func get(_ path: String, query: [URLQueryItem], secure: Bool, timeout: TimeInterval) async throws -> Data
}

final class HostHTTPClient: HostRequesting, @unchecked Sendable {
    private let address: String
    private let httpPort: Int
    private let httpsPort: Int
    private let identity: ClientIdentity
    private let session: URLSession
    private let delegate: TLSDelegate

    init(address: String, httpPort: Int = 47989, httpsPort: Int = 47984,
         identity: ClientIdentity, pinnedServerCertDER: Data?) {
        self.address = address
        self.httpPort = httpPort
        self.httpsPort = httpsPort
        self.identity = identity
        self.delegate = TLSDelegate(identity: identity, pinnedDER: pinnedServerCertDER)
        let config = URLSessionConfiguration.ephemeral
        config.waitsForConnectivity = false
        self.session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    func get(_ path: String, query: [URLQueryItem], secure: Bool, timeout: TimeInterval) async throws -> Data {
        var comps = URLComponents()
        comps.scheme = secure ? "https" : "http"
        comps.host = address
        comps.port = secure ? httpsPort : httpPort
        comps.path = path
        // HostAPI may already supply uniqueid; avoid sending it twice.
        var items = query.contains { $0.name == "uniqueid" } ? [] : [URLQueryItem(name: "uniqueid", value: identity.uniqueID)]
        items.append(URLQueryItem(name: "uuid", value: UUID().uuidString))
        comps.queryItems = items + query
        guard let url = comps.url else { throw HostError.malformed }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        do {
            let (data, _) = try await session.data(for: request)
            return data
        } catch let error as URLError {
            if delegate.consumePinMismatch() { throw HostError.certificatePinMismatch }
            switch error.code {
            case .cannotConnectToHost, .timedOut, .notConnectedToInternet, .networkConnectionLost,
                 .cannotFindHost, .secureConnectionFailed, .dnsLookupFailed, .serverCertificateUntrusted,
                 .clientCertificateRejected, .cancelled:
                throw HostError.unreachable
            default:
                throw HostError.unreachable
            }
        }
    }
}

final class TLSDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    private let identity: ClientIdentity
    private let pinnedDER: Data?
    private let lock = NSLock()
    private var pinMismatch = false

    init(identity: ClientIdentity, pinnedDER: Data?) {
        self.identity = identity
        self.pinnedDER = pinnedDER
    }

    func consumePinMismatch() -> Bool {
        lock.lock(); defer { lock.unlock() }
        let v = pinMismatch; pinMismatch = false; return v
    }

    private func markMismatch() { lock.lock(); pinMismatch = true; lock.unlock() }

    /// True only when the server's leaf certificate is byte-for-byte the pinned one. No pin, or an empty
    /// chain, never matches.
    static func matches(trust: SecTrust, pinnedDER: Data?) -> Bool {
        guard let pinnedDER,
              let leaf = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first else { return false }
        return SecCertificateCopyData(leaf) as Data == pinnedDER
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        switch challenge.protectionSpace.authenticationMethod {
        case NSURLAuthenticationMethodClientCertificate:
            guard let secIdentity = try? identity.secIdentity() else {
                completionHandler(.cancelAuthenticationChallenge, nil); return
            }
            completionHandler(.useCredential, URLCredential(identity: secIdentity, certificates: nil, persistence: .forSession))
        case NSURLAuthenticationMethodServerTrust:
            guard let trust = challenge.protectionSpace.serverTrust,
                  Self.matches(trust: trust, pinnedDER: pinnedDER) else {
                markMismatch()
                completionHandler(.cancelAuthenticationChallenge, nil); return
            }
            completionHandler(.useCredential, URLCredential(trust: trust))
        default:
            completionHandler(.performDefaultHandling, nil)
        }
    }
}
