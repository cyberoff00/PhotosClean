//
//  StoreManager.swift
//  PhotosClean
//
//  Updated: Yearly subscription, removed Lifetime
//

import SwiftUI
import StoreKit
import Combine

enum TimeoutError: Error {
    case operationTimeout
}

@MainActor
final class StoreManager: ObservableObject {

    // Products (monthly, quarterly, yearly)
    @Published var products: [Product] = []
    @Published private(set) var subscriptions: [Product] = []

    // Entitlements
    @Published private(set) var purchasedIDs: Set<String> = []

    // Subscription info
    @Published private(set) var nextRenewalDate: Date?
    @Published private(set) var currentSubscriptionType: SubscriptionType = .none

    // Display status for UI
    @Published private(set) var displayStatus: SubscriptionDisplayStatus = .none

    // UI loading state
    @Published var isLoadingPurchase: Bool = false

    // ✅ Product IDs
    private let productIDs: [String] = [
        "com.claire.tastytidy.month",
        "com.claire.tastytidy.quarter",
        "com.claire.tastytidy.year"
    ]

    // Convenience
    var hasUnlockedPremium: Bool { displayStatus.isPremium }

    var currentSubscription: Product? {
        // If multiple entitlements exist, prefer longer duration
        subscriptions.sorted { rankSubscription($0) < rankSubscription($1) }
            .first(where: { purchasedIDs.contains($0.id) })
    }

    var formattedRenewalDate: String {
        guard let date = nextRenewalDate else { return "" }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    func getProduct(byID id: String) -> Product? {
        products.first { $0.id == id }
    }

    func isPurchased(_ product: Product) -> Bool {
        purchasedIDs.contains(product.id)
    }

    init() {
        Task {
            await fetchProducts()
            await updatePurchasedProducts()
            await monitorTransactions()
        }
    }

    // MARK: - Fetch products
    func fetchProducts() async {
        do {
            let fetched = try await Product.products(for: productIDs)
            self.products = fetched

            self.subscriptions = fetched
                .filter { $0.type == .autoRenewable }
                .sorted { rankSubscription($0) < rankSubscription($1) }
        } catch {
            print("Fetch products failed: \(error)")
            self.products = []
            self.subscriptions = []
        }
    }

    private func rankSubscription(_ p: Product) -> Int {
        guard let period = p.subscription?.subscriptionPeriod else { return 99 }
        if period.unit == .year && period.value == 1 { return 0 }
        if period.unit == .month && period.value == 3 { return 1 }
        if period.unit == .month && period.value == 1 { return 2 }
        return 99
    }

    // MARK: - Purchase
    func buy(_ product: Product) async throws {
        isLoadingPurchase = true
        defer { isLoadingPurchase = false }

        let result = try await product.purchase()

        switch result {
        case .success(let verification):
            let transaction = try checkVerified(verification)
            await updatePurchasedProducts()
            await transaction.finish()

        case .userCancelled, .pending:
            break

        @unknown default:
            break
        }
    }

    // MARK: - Restore / Entitlements
    func updatePurchasedProducts() async {
        do {
            try await withTimeout(seconds: 30) {
                await self._updatePurchasedProducts()
            }
        } catch {
            print("updatePurchasedProducts timeout or error: \(error)")
        }
    }

    private func _updatePurchasedProducts() async {
        var newPurchased: Set<String> = []
        var latestExpirationDate: Date? = nil
        var subscriptionType: SubscriptionType = .none

        var foundIntroTrial = false
        var trialDaysLeft: Int? = nil

        for await result in Transaction.currentEntitlements {
            guard let transaction = try? checkVerified(result) else { continue }
            guard productIDs.contains(transaction.productID) else { continue }

            newPurchased.insert(transaction.productID)

            // Type
            if transaction.productID == "com.claire.tastytidy.year" {
                subscriptionType = .yearly
            } else if transaction.productID == "com.claire.tastytidy.quarter" {
                subscriptionType = .quarterly
            } else if transaction.productID == "com.claire.tastytidy.month" {
                subscriptionType = .monthly
            }

            // Expiration date
            if let exp = transaction.expirationDate {
                if latestExpirationDate == nil || exp > latestExpirationDate! {
                    latestExpirationDate = exp
                }

                // Trial
                if transaction.offerType == .introductory {
                    foundIntroTrial = true
                    let now = Date()
                    let seconds = exp.timeIntervalSince(now)
                    let days = Int(ceil(seconds / 86400.0))
                    trialDaysLeft = max(days, 0)
                }
            }
        }

        purchasedIDs = newPurchased
        nextRenewalDate = latestExpirationDate
        currentSubscriptionType = subscriptionType

        // Display status
        if let exp = latestExpirationDate {
            if foundIntroTrial {
                displayStatus = .trial(daysLeft: trialDaysLeft ?? 0, renewDate: exp)
            } else {
                displayStatus = .active(renewDate: exp)
            }
        } else {
            displayStatus = .none
        }
    }

    // MARK: - Monitor Transactions
    private func monitorTransactions() async {
        for await result in Transaction.updates {
            if let transaction = try? checkVerified(result),
               productIDs.contains(transaction.productID) {
                await updatePurchasedProducts()
                _ = try? await transaction.finish()
            }
        }
    }

    // MARK: - Verification
    func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .unverified:
            throw StoreError.failedVerification
        case .verified(let safe):
            return safe
        }
    }

    // MARK: - Timeout Helper
    private func withTimeout<T>(
        seconds: TimeInterval = 30,
        operation: @escaping () async -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { await operation() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw TimeoutError.operationTimeout
            }

            guard let result = try await group.next() else {
                throw TimeoutError.operationTimeout
            }

            group.cancelAll()
            return result
        }
    }
}

// MARK: - Subscription Type
enum SubscriptionType {
    case none
    case monthly
    case quarterly
    case yearly

    var displayName: String {
        switch self {
        case .none: return ""
        case .monthly: return String(localized: "sub.type.monthly", defaultValue: "Monthly")
        case .quarterly: return String(localized: "sub.type.quarterly", defaultValue: "Quarterly")
        case .yearly: return String(localized: "sub.type.yearly", defaultValue: "Yearly")
        }
    }
}

// MARK: - Display Status (UI)
enum SubscriptionDisplayStatus: Equatable {
    case none
    case trial(daysLeft: Int, renewDate: Date?)
    case active(renewDate: Date?)

    var isPremium: Bool {
        switch self {
        case .none: return false
        default: return true
        }
    }

    var titleKey: LocalizedStringKey {
        switch self {
        case .trial: return "sub.info.trial"
        case .active: return "sub.info.active"
        case .none: return "sub.info.inactive"
        }
    }

    var subtitleText: String {
        switch self {
        case .trial(let daysLeft, _):
            return "Start 7 days trial · \(max(daysLeft, 0)) days left"
        case .active:
            return ""
        case .none:
            return ""
        }
    }

    var color: Color {
        switch self {
        case .trial: return .orange
        case .active: return .green
        case .none: return .secondary
        }
    }

    var icon: String {
        switch self {
        case .trial: return "clock.badge.checkmark"
        case .active: return "checkmark.seal.fill"
        case .none: return "xmark.seal"
        }
    }
}

enum StoreError: Error {
    case failedVerification
}
