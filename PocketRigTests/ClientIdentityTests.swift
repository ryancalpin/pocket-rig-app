import Testing
import Foundation
import Security
@testable import PocketRig

@Suite(.serialized) struct ClientIdentityTests {
    let store = KeychainStore(service: "com.ryancalpin.pocketrig.tests.\(UUID().uuidString)")

    private func cleanup() {
        for account in ["cert", "key", "p12", "uniqueid"] { store.delete(account) }
    }

    @Test func identityIsCreatedOnceAndReused() throws {
        defer { cleanup() }
        let first = try ClientIdentity.loadOrCreate(store: store)
        let second = try ClientIdentity.loadOrCreate(store: store)
        #expect(first.certPEM == second.certPEM)
        #expect(first.uniqueID == second.uniqueID)
        #expect(first.uniqueID.count == 16)
    }

    @Test func p12ImportsAsSecIdentity() throws {
        defer { cleanup() }
        let id = try ClientIdentity.loadOrCreate(store: store)
        _ = try id.secIdentity()
    }

    @Test func partialStateRegeneratesCompleteIdentity() throws {
        defer { cleanup() }
        try store.write(Data("stale".utf8), account: "cert")
        let id = try ClientIdentity.loadOrCreate(store: store)
        #expect(String(decoding: id.certPEM, as: UTF8.self).hasPrefix("-----BEGIN CERTIFICATE-----"))
        #expect(try store.readThrowing("cert") == id.certPEM)
        #expect(try store.readThrowing("key") == id.keyPEM)
        #expect(try store.readThrowing("p12") == id.p12)
        #expect(try store.readThrowing("uniqueid") != nil)
        _ = try id.secIdentity()
    }

    @Test func keyMatchCheckDetectsMismatch() throws {
        let a = try PairingCrypto.generateIdentity(p12Password: "x")
        let b = try PairingCrypto.generateIdentity(p12Password: "x")
        #expect(ClientIdentity.keyMatchesCert(keyPEM: a.keyPEM, certPEM: a.certPEM))
        #expect(!ClientIdentity.keyMatchesCert(keyPEM: a.keyPEM, certPEM: b.certPEM))
    }

    @Test func mismatchedStoredSetIsRegenerated() throws {
        defer { cleanup() }
        let first = try ClientIdentity.loadOrCreate(store: store)
        let other = try PairingCrypto.generateIdentity(p12Password: ClientIdentity.p12Password)
        // Simulate a mixed generation: cert from another identity, key and p12 from the first.
        try store.write(other.certPEM, account: "cert")
        let repaired = try ClientIdentity.loadOrCreate(store: store)
        #expect(repaired.certPEM != other.certPEM)
        #expect(repaired.certPEM != first.certPEM)
        #expect(ClientIdentity.keyMatchesCert(keyPEM: repaired.keyPEM, certPEM: repaired.certPEM))
        #expect(try store.readThrowing("cert") == repaired.certPEM)
        #expect(try store.readThrowing("key") == repaired.keyPEM)
    }
}
