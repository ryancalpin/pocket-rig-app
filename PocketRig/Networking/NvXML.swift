import Foundation

struct HostApp: Sendable, Hashable, Identifiable {
    let id: Int
    let title: String
    let hdrSupported: Bool
}

enum HostError: Error, Equatable {
    case status(Int, String)
    case malformed
    case notPaired
    case unreachable
    case certificatePinMismatch
}

struct NvXMLDocument: Sendable {
    let statusCode: Int
    let statusMessage: String
    let values: [String: String]
    let apps: [HostApp]
}

enum NvXML {
    static func parse(_ data: Data) throws -> NvXMLDocument {
        let handler = Handler()
        let parser = XMLParser(data: data)
        parser.delegate = handler
        guard parser.parse(), handler.sawRoot else { throw HostError.malformed }
        return NvXMLDocument(statusCode: handler.statusCode, statusMessage: handler.statusMessage,
                             values: handler.values, apps: handler.apps)
    }

    private final class Handler: NSObject, XMLParserDelegate {
        var sawRoot = false
        var statusCode = 0
        var statusMessage = ""
        var values: [String: String] = [:]
        var apps: [HostApp] = []

        private var depth = 0
        private var text = ""
        private var inApp = false
        private var appFields: [String: String] = [:]

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            depth += 1
            if depth == 1 {
                sawRoot = true
                statusCode = Int(attributeDict["status_code"] ?? "") ?? 0
                statusMessage = attributeDict["status_message"] ?? ""
            } else if depth == 2 {
                if elementName == "App" { inApp = true; appFields = [:] }
                text = ""
            } else if depth == 3 && inApp {
                text = ""
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?) {
            defer { depth -= 1 }
            if depth == 3 && inApp {
                appFields[elementName] = text.trimmingCharacters(in: .whitespacesAndNewlines)
            } else if depth == 2 {
                if elementName == "App" {
                    inApp = false
                    if let id = Int(appFields["ID"] ?? ""), let title = appFields["AppTitle"] {
                        apps.append(HostApp(id: id, title: title, hdrSupported: appFields["IsHdrSupported"] == "1"))
                    }
                } else if values[elementName] == nil {
                    values[elementName] = text.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        }
    }
}

extension NvXMLDocument {
    @discardableResult
    func requireOK() throws -> NvXMLDocument {
        guard statusCode == 200 else { throw HostError.status(statusCode, statusMessage) }
        return self
    }
}

struct ServerInfo: Sendable, Equatable {
    let hostname: String; let appVersion: String; let gfeVersion: String; let uniqueID: String
    let httpsPort: Int; let macAddress: String; let localIP: String
    let codecModeSupport: Int32; let isPaired: Bool; let currentGameID: Int; let isBusy: Bool
    /// The biggest picture (width × height) the PC's HEVC encoder takes. 0 when Sunshine doesn't say.
    let maxLumaPixelsHEVC: Int
}

extension ServerInfo {
    init(_ doc: NvXMLDocument) throws {
        let v = doc.values
        guard let hostname = v["hostname"] else { throw HostError.malformed }
        self.init(hostname: hostname, appVersion: v["appversion"] ?? "", gfeVersion: v["GfeVersion"] ?? "",
                  uniqueID: v["uniqueid"] ?? "", httpsPort: Int(v["HttpsPort"] ?? "") ?? 47984,
                  macAddress: v["mac"] ?? "", localIP: v["LocalIP"] ?? "",
                  codecModeSupport: Int32(v["ServerCodecModeSupport"] ?? "") ?? 1,
                  isPaired: v["PairStatus"] == "1", currentGameID: Int(v["currentgame"] ?? "") ?? 0,
                  isBusy: (v["state"] ?? "").hasSuffix("_BUSY"),
                  maxLumaPixelsHEVC: Int(v["MaxLumaPixelsHEVC"] ?? "") ?? 0)
    }
}
