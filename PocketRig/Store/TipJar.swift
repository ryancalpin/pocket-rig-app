import Foundation
import Observation
import StoreKit
import UIKit
import os

private let storeLog = Logger(subsystem: "com.ryancalpin.pocketrig", category: "store")

/// The three tips. Each is a consumable that unlocks nothing.
enum TipProduct: String, CaseIterable, Sendable {
    case small = "com.ryancalpin.pocketrig.tip.small"
    case medium = "com.ryancalpin.pocketrig.tip.medium"
    case large = "com.ryancalpin.pocketrig.tip.large"
}

/// One tip as the screen shows it. Title and price both come from the store.
struct TipOption: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let price: String
}

enum TipPurchaseOutcome: Equatable, Sendable { case thanked, cancelled, pending, failed }

/// Runs a purchase in the window the user is looking at. The About screen supplies SwiftUI's `PurchaseAction`.
typealias TipPurchaseRunner = @MainActor @Sendable (Product) async throws -> Product.PurchaseResult

protocol TipStore: Sendable {
    /// The tips, sorted small to large.
    func options() async throws -> [TipOption]
    /// Buys one tip; a verified purchase is finished before this returns `.thanked`.
    /// `runner` presents the purchase in the right window; without one the store buys directly.
    func buy(_ id: String, using runner: TipPurchaseRunner?) async -> TipPurchaseOutcome
}

/// What the About screen's "Leave a tip" section shows and does.
@MainActor @Observable
final class TipJarModel {
    enum Phase: Equatable { case loading, ready([TipOption]), unavailable }

    private(set) var phase: Phase = .loading
    private(set) var buying: String?
    private(set) var notice: String?

    private let store: any TipStore

    init(store: any TipStore) { self.store = store }

    func load() async {
        do {
            let options = try await store.options()
            phase = options.isEmpty ? .unavailable : .ready(options)
        } catch {
            storeLog.error("Loading tips failed: \(error.localizedDescription, privacy: .public)")
            phase = .unavailable
        }
    }

    func buy(_ option: TipOption, using runner: TipPurchaseRunner? = nil) async {
        guard buying == nil else { return }
        buying = option.id
        notice = nil
        defer { buying = nil }
        switch await store.buy(option.id, using: runner) {
        case .thanked:
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            notice = "Thank you! Your tip keeps Pocket Rig going."
        case .cancelled:
            break
        case .pending:
            notice = "Waiting for approval."
        case .failed:
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            notice = "The tip didn't go through."
        }
    }
}

struct TipLoadTimedOut: Error {}

private final class OnceResume<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    init(_ continuation: CheckedContinuation<T, Error>) { self.continuation = continuation }
    func finish(_ result: Result<T, Error>) {
        let taken = lock.withLock { () -> CheckedContinuation<T, Error>? in
            defer { continuation = nil }
            return continuation
        }
        taken?.resume(with: result)
    }
}

/// Runs `operation` and returns its result, or throws `TipLoadTimedOut` after `timeout`, even if
/// `operation` ignores cancellation and never finishes (a task group would wait for it forever).
func withHardTimeout<T: Sendable>(
    _ timeout: Duration, _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    return try await withCheckedThrowingContinuation { continuation in
        let once = OnceResume<T>(continuation)
        let work = Task {
            do { once.finish(.success(try await operation())) } catch { once.finish(.failure(error)) }
        }
        Task {
            try? await Task.sleep(for: timeout)
            once.finish(.failure(TipLoadTimedOut()))
            work.cancel()
        }
    }
}

/// The real store: StoreKit 2.
final class LiveTipStore: TipStore, @unchecked Sendable {
    private let timeout: Duration
    private let loadProducts: @Sendable ([String]) async throws -> [Product]
    private let lock = NSLock()
    private var cache: [String: Product] = [:]

    init(
        timeout: Duration = .seconds(8),
        loadProducts: @escaping @Sendable ([String]) async throws -> [Product] = { try await Product.products(for: $0) }
    ) {
        self.timeout = timeout
        self.loadProducts = loadProducts
    }

    func options() async throws -> [TipOption] {
        // With no store reachable, StoreKit can wait a long time; give up so the screen shows its empty state.
        let ids = TipProduct.allCases.map(\.rawValue)
        let load = loadProducts
        let products = try await withHardTimeout(timeout) { try await load(ids) }
        lock.withLock { for product in products { cache[product.id] = product } }
        return products.sorted { $0.price < $1.price }
            .map { TipOption(id: $0.id, title: $0.displayName, price: $0.displayPrice) }
    }

    func buy(_ id: String, using runner: TipPurchaseRunner?) async -> TipPurchaseOutcome {
        // Buys what the screen already loaded; no second network fetch that could hang.
        guard let product = lock.withLock({ cache[id] }) else {
            storeLog.error("Tip product not loaded: \(id, privacy: .public)")
            return .failed
        }
        do {
            let result: Product.PurchaseResult
            if let runner { result = try await runner(product) } else { result = try await product.purchase() }
            switch result {
            case .success(let verification):
                guard case .verified(let transaction) = verification else {
                    storeLog.error("Tip purchase failed verification: \(id, privacy: .public)")
                    return .failed
                }
                await transaction.finish()
                return .thanked
            case .userCancelled:
                return .cancelled
            case .pending:
                return .pending
            @unknown default:
                return .failed
            }
        } catch {
            storeLog.error("Tip purchase failed: \(error.localizedDescription, privacy: .public)")
            return .failed
        }
    }
}
