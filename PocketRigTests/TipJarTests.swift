import Foundation
import StoreKitTest
import Testing
@testable import PocketRig

/// A scripted `TipStore`. `gate` (when set) holds `buy` open so a test can try a second tap.
private final class FakeTipStore: TipStore, @unchecked Sendable {
    var result: Result<[TipOption], Error> = .success([])
    var outcome: TipPurchaseOutcome = .thanked
    var gate: AsyncStream<Void>?
    private let lock = NSLock()
    private var _bought: [String] = []
    var bought: [String] { lock.withLock { _bought } }

    struct Boom: Error {}

    func options() async throws -> [TipOption] { try result.get() }

    func buy(_ id: String, using runner: TipPurchaseRunner?) async -> TipPurchaseOutcome {
        lock.withLock { _bought.append(id) }
        if let gate { for await _ in gate { break } }
        return outcome
    }
}

private let small = TipOption(id: "s", title: "Small tip", price: "$0.99")
private let medium = TipOption(id: "m", title: "Medium tip", price: "$2.99")

@MainActor
struct TipJarTests {
    @Test func loadsOptions() async {
        let store = FakeTipStore()
        store.result = .success([small, medium])
        let model = TipJarModel(store: store)
        #expect(model.phase == .loading)
        await model.load()
        #expect(model.phase == .ready([small, medium]))
    }

    @Test func unavailableWhenTheStoreThrows() async {
        let store = FakeTipStore()
        store.result = .failure(FakeTipStore.Boom())
        let model = TipJarModel(store: store)
        await model.load()
        #expect(model.phase == .unavailable)
    }

    @Test func unavailableWhenThereAreNoProducts() async {
        let model = TipJarModel(store: FakeTipStore())
        await model.load()
        #expect(model.phase == .unavailable)
    }

    @Test func thankYouAfterASuccessfulTip() async {
        let store = FakeTipStore()
        store.outcome = .thanked
        let model = TipJarModel(store: store)
        await model.buy(small)
        #expect(model.notice == "Thank you! Your tip keeps Pocket Rig going.")
        #expect(model.buying == nil)
        #expect(store.bought == ["s"])
    }

    @Test func cancelledTipSaysNothing() async {
        let store = FakeTipStore()
        store.outcome = .cancelled
        let model = TipJarModel(store: store)
        await model.buy(small)
        #expect(model.notice == nil)
        #expect(model.buying == nil)
    }

    @Test func pendingTipWaitsForApproval() async {
        let store = FakeTipStore()
        store.outcome = .pending
        let model = TipJarModel(store: store)
        await model.buy(small)
        #expect(model.notice == "Waiting for approval.")
    }

    @Test func failedTipSaysItDidNotGoThrough() async {
        let store = FakeTipStore()
        store.outcome = .failed
        let model = TipJarModel(store: store)
        await model.buy(small)
        #expect(model.notice == "The tip didn't go through.")
    }

    @Test func aSecondTipWhileOneRunsIsIgnored() async {
        let store = FakeTipStore()
        let (gate, release) = AsyncStream<Void>.makeStream()
        store.gate = gate
        let model = TipJarModel(store: store)
        let first = Task { await model.buy(small) }
        while model.buying == nil { await Task.yield() }
        #expect(model.buying == "s")
        while store.bought.isEmpty { await Task.yield() }
        await model.buy(medium)
        #expect(store.bought == ["s"])
        release.yield()
        await first.value
        #expect(model.buying == nil)
        #expect(store.bought == ["s"])
    }

    @Test func aNewTipClearsTheOldNotice() async {
        let store = FakeTipStore()
        store.outcome = .failed
        let model = TipJarModel(store: store)
        await model.buy(small)
        store.outcome = .cancelled
        await model.buy(small)
        #expect(model.notice == nil)
    }

    @Test func productIdsMatchTheLocalStoreKitFile() {
        #expect(TipProduct.allCases.map(\.rawValue) == [
            "com.ryancalpin.pocketrig.tip.small",
            "com.ryancalpin.pocketrig.tip.medium",
            "com.ryancalpin.pocketrig.tip.large",
        ])
    }

    /// The live store against the local `.storekit` file. Skipped (not failed) if the host can't run a session.
    @Test func liveStoreLoadsThreeTipsAndAPurchaseFinishes() async throws {
        // The file stays out of the app; read it straight from the source tree.
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("PocketRig/Store/PocketRig.storekit")
        guard FileManager.default.fileExists(atPath: url.path) else {
            // Environment limit (file not reachable from this host), not a product failure: skip quietly.
            return
        }
        let session: SKTestSession
        do {
            session = try SKTestSession(contentsOf: url)
        } catch {
            // Environment limit (host can't run a StoreKit test session), not a product failure: skip quietly.
            _ = error
            return
        }
        session.resetToDefaultState()
        session.disableDialogs = true
        session.clearTransactions()
        let live = LiveTipStore(timeout: .seconds(30))
        let options = try await live.options()
        #expect(options.map(\.title) == ["Small tip", "Medium tip", "Large tip"])
        #expect(options.allSatisfy { !$0.price.isEmpty })
        // `Product.purchase()` needs an on-screen scene, so the test host buys through the session instead.
        let transaction = try await session.buyProduct(identifier: TipProduct.small.rawValue)
        #expect(TipProduct(rawValue: transaction.productID) == .small)
        await transaction.finish()
        #expect(session.allTransactions().count == 1)
    }

    @Test func loadingGivesUpEvenWhenStoreKitIgnoresCancellation() async {
        // A loader that never returns and never notices cancellation.
        let live = LiveTipStore(timeout: .milliseconds(200)) { _ in
            await withUnsafeContinuation { (_: UnsafeContinuation<Void, Never>) in }
            return []
        }
        let start = ContinuousClock.now
        await #expect(throws: TipLoadTimedOut.self) { _ = try await live.options() }
        #expect(ContinuousClock.now - start < .seconds(5))
    }

    @Test func buyingAnUnloadedTipFailsFast() async {
        let live = LiveTipStore(timeout: .milliseconds(200)) { _ in [] }
        let outcome = await live.buy(TipProduct.small.rawValue, using: nil)
        #expect(outcome == .failed)
    }
}
