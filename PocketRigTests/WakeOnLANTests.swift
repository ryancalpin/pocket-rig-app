import Foundation
import Testing
@testable import PocketRig

@Suite struct WakeOnLANTests {
    @Test func readsCommonMACSpellings() {
        #expect(WakeOnLAN.macBytes("04:0e:3c:2a:36:94") == [0x04, 0x0e, 0x3c, 0x2a, 0x36, 0x94])
        #expect(WakeOnLAN.macBytes("04-0E-3C-2A-36-94") == [0x04, 0x0e, 0x3c, 0x2a, 0x36, 0x94])
    }

    @Test func rejectsNonsense() {
        for bad in ["", "04:0e:3c:2a:36", "04:0e:3c:2a:36:94:00", "zz:0e:3c:2a:36:94", "4:e:3c:2a:36:94",
                    "00:00:00:00:00:00", "ff:ff:ff:ff:ff:ff", "+4:0e:3c:2a:36:94", "04:0e:3c:2a:36:+4",
                    "01:0e:3c:2a:36:94", "33:33:00:00:00:01"] {
            #expect(!WakeOnLAN.isValidMAC(bad), "\(bad)")
        }
    }

    @Test func magicPacketIsSixFFsThenTheMACSixteenTimes() throws {
        let packet = try #require(WakeOnLAN.magicPacket(mac: "04:0e:3c:2a:36:94"))
        #expect(packet.count == 102)
        #expect(Array(packet.prefix(6)) == Array(repeating: 0xff, count: 6))
        let mac: [UInt8] = [0x04, 0x0e, 0x3c, 0x2a, 0x36, 0x94]
        for copy in 0..<16 {
            let start = 6 + copy * 6
            #expect(Array(packet[start..<start + 6]) == mac)
        }
        #expect(WakeOnLAN.magicPacket(mac: "nope") == nil)
    }

    @Test func targetsSkipTailscaleAndAlwaysBroadcast() {
        #expect(WakeOnLAN.targets(lanAddress: "192.168.1.50", broadcast: "192.168.1.255")
                == ["192.168.1.50", "192.168.1.255", "255.255.255.255"])
        #expect(WakeOnLAN.targets(lanAddress: "100.101.102.103", broadcast: nil) == ["255.255.255.255"])
        #expect(WakeOnLAN.targets(lanAddress: nil, broadcast: "255.255.255.255") == ["255.255.255.255"])
        #expect(WakeOnLAN.targets(lanAddress: "my-pc.local", broadcast: "") == ["255.255.255.255"])
    }

    @Test func onlyRealIPv4BroadcastsAreWorthSaving() {
        #expect(WakeOnLAN.isUsableBroadcast("192.168.1.255"))
        for bad in ["", "0.0.0.0", "100.77.56.255", "my-pc.local", "fe80::1", "192.168.1.256"] {
            #expect(!WakeOnLAN.isUsableBroadcast(bad), "\(bad)")
        }
    }

    @Test func aBadMACSendsNothing() async {
        #expect(await WakeOnLAN.send(mac: "nope", lanAddress: "192.168.1.50", broadcast: nil) == false)
    }

    @Test func sendingToTheSimulatorsOwnNetworkWorks() async {
        // 127.0.0.1 always exists; this proves the packet leaves the app without needing a PC.
        #expect(await WakeOnLAN.send(mac: "04:0e:3c:2a:36:94", lanAddress: "127.0.0.1", broadcast: nil))
    }
}
