import StoreKit
import os

private let observerLog = Logger(subsystem: "com.ryancalpin.pocketrig", category: "store")

/// Finishes tip purchases that complete outside the About screen (approved Ask to Buy, an interrupted
/// purchase, a quit mid-purchase). Consumables stay in the queue until finished.
final class TipTransactionObserver: Sendable {
    private let task: Task<Void, Never>

    init() {
        task = Task.detached(priority: .utility) {
            // Tips left unfinished from an earlier launch.
            for await unfinished in Transaction.unfinished { await Self.handle(unfinished) }
        }
        updatesTask = Task.detached(priority: .utility) {
            for await update in Transaction.updates { await Self.handle(update) }
        }
    }

    private let updatesTask: Task<Void, Never>

    private static func handle(_ result: VerificationResult<Transaction>) async {
        switch result {
        case .verified(let transaction):
            if TipProduct(rawValue: transaction.productID) != nil {
                await transaction.finish()
            } else {
                observerLog.info("Skipped a non-tip transaction: \(transaction.productID, privacy: .public)")
            }
        case .unverified(let transaction, let error):
            observerLog.error("Ignored an unverified transaction: \(transaction.productID, privacy: .public) (\(error.localizedDescription, privacy: .public))")
        }
    }

    deinit {
        task.cancel()
        updatesTask.cancel()
    }
}
