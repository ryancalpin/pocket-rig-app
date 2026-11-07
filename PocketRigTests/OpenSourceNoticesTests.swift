import Foundation
import Testing
@testable import PocketRig

@Suite struct OpenSourceNoticesTests {
    @Test func pocketRigItselfIsListedFirstUnderTheGPL() throws {
        let first = try #require(OpenSourceNoticesData.components.first)
        #expect(first.name == "Pocket Rig")
        #expect(first.license == "GNU GPL version 3")
        #expect(first.attribution == "\u{00A9} 2026 Ryan Calpin.")
        #expect(first.source?.absoluteString == "https://github.com/ryancalpin/pocket-rig-app")
        #expect(first.licenseFile == "License-PocketRig")
        #expect(OpenSourceNoticesData.components.map(\.name)
                == ["Pocket Rig", "moonlight-common-c", "ENet", "nanors", "OpenSSL"])
    }

    @Test func everyListedLicenseFileLoads() {
        for component in OpenSourceNoticesData.components {
            #expect(!LicenseTextView.text(resource: component.licenseFile).hasPrefix("The license text couldn't"),
                    "\(component.licenseFile)")
        }
    }

    @Test func privacyLinkPointsAtThePublicPolicyAndSupportStaysOnNotion() {
        #expect(AboutScreen.privacyURL.absoluteString == "https://github.com/ryancalpin/pocket-rig-app/blob/main/PRIVACY.md")
        #expect(AboutScreen.supportURL.absoluteString == "https://ryancalpin.notion.site/calpinlabs")
    }
}
