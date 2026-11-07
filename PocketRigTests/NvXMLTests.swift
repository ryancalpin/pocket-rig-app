import Testing
import Foundation
@testable import PocketRig

@Suite struct NvXMLTests {
    @Test func parsesServerInfo() throws {
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <root status_code="200"><hostname>Omen</hostname><appversion>7.1.431.-1</appversion>
        <GfeVersion>3.23.0.74</GfeVersion><uniqueid>ABC</uniqueid><HttpsPort>47984</HttpsPort>
        <mac>00:11:22:33:44:55</mac><LocalIP>192.168.1.20</LocalIP>
        <ServerCodecModeSupport>259</ServerCodecModeSupport><PairStatus>1</PairStatus>
        <currentgame>0</currentgame><state>SUNSHINE_SERVER_FREE</state></root>
        """
        let doc = try NvXML.parse(Data(xml.utf8))
        #expect(doc.statusCode == 200)
        let info = try ServerInfo(doc)
        #expect(info.hostname == "Omen")
        #expect(info.codecModeSupport == 259)
        #expect(info.isPaired)
        #expect(!info.isBusy)
    }

    @Test func parsesAppList() throws {
        let xml = """
        <root status_code="200"><App><IsHdrSupported>0</IsHdrSupported><AppTitle>Desktop</AppTitle><ID>881448767</ID></App>
        <App><IsHdrSupported>1</IsHdrSupported><AppTitle>Steam Big Picture</AppTitle><ID>1093255277</ID></App></root>
        """
        let apps = try NvXML.parse(Data(xml.utf8)).apps
        #expect(apps == [HostApp(id: 881448767, title: "Desktop", hdrSupported: false),
                         HostApp(id: 1093255277, title: "Steam Big Picture", hdrSupported: true)])
    }

    @Test func errorStatusThrows() throws {
        let xml = #"<root status_code="401" status_message="The client is not authorized. Certificate verification failed."/>"#
        #expect(throws: HostError.status(401, "The client is not authorized. Certificate verification failed.")) {
            try NvXML.parse(Data(xml.utf8)).requireOK()
        }
    }
}
