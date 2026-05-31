//
//  StoreManager.swift
//  PhotosClean
//
//  Updated: Yearly subscription, removed Lifetime
//

import SwiftUI
import StoreKit
import Combine
import Security

enum TimeoutError: Error {
    case operationTimeout
}

// MARK: - Lifetime cache (Keychain, device-bound)
/// Caches the lifetime (non-consumable) unlock in the device Keychain so the
/// membership survives an Apple ID switch on the SAME device. The flag is
/// cleared automatically when StoreKit reports the purchase was refunded
/// (revocationDate != nil). Keychain is used (not UserDefaults) so the flag
/// persists across app reinstalls but never syncs to a different device.
enum LifetimeCache {
    private static let service = "com.claire.tastytidy.iap"
    private static let account = "lifetime_unlocked"

    static var isUnlocked: Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return false
        }
        return value == "1"
    }

    static func set(_ unlocked: Bool) {
        if unlocked {
            let data = Data("1".utf8)
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account
            ]
            // Delete any existing item, then add fresh.
            SecItemDelete(query as CFDictionary)
            var attributes = query
            attributes[kSecValueData as String] = data
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(attributes as CFDictionary, nil)
        } else {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account
            ]
            SecItemDelete(query as CFDictionary)
        }
    }
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
    @Published var productLoadFailed: Bool = false

    // ✅ Product IDs
    private let lifetimeID = "com.claire.tastytidy.forever"
    private let subscriptionIDs: [String] = [
        "com.claire.tastytidy.month",
        "com.claire.tastytidy.quarter",
        "com.claire.tastytidy.year"
    ]
    private var productIDs: [String] { subscriptionIDs + [lifetimeID] }

    /// Whether the user owns the lifetime unlock — true if StoreKit reports the
    /// non-consumable on the current Apple ID, OR the device Keychain cached it
    /// (covers the case where the user switched to a different Apple ID).
    @Published private(set) var hasLifetime: Bool = false

    // Convenience
    var hasUnlockedPremium: Bool { hasLifetime || displayStatus.isPremium }

    /// Whether an auto-renewable subscription is currently active. Used to warn
    /// the user to cancel it after buying lifetime (avoids double charging).
    var hasActiveSubscription: Bool {
        subscriptionIDs.contains { purchasedIDs.contains($0) }
    }

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
            async let fetch: Void = fetchProducts()
            async let update: Void = updatePurchasedProducts()
            _ = await (fetch, update)
            await monitorTransactions()
        }
    }

    // MARK: - Fetch products
    func fetchProducts() async {
        productLoadFailed = false
        let maxRetries = 3
        for attempt in 1...maxRetries {
            do {
                let fetched = try await withTimeout(seconds: 15) {
                    try await Product.products(for: self.productIDs)
                }
                self.products = fetched
                self.subscriptions = fetched
                    .filter { $0.type == .autoRenewable }
                    .sorted { rankSubscription($0) < rankSubscription($1) }
                self.productLoadFailed = false
                return // success, exit
            } catch {
                print("Fetch products attempt \(attempt)/\(maxRetries) failed: \(error)")
                if attempt < maxRetries {
                    try? await Task.sleep(for: .seconds(Double(attempt) * 2))
                }
            }
        }
        // All retries exhausted
        self.products = []
        self.subscriptions = []
        self.productLoadFailed = true
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
            if transaction.productID == lifetimeID {
                subscriptionType = .lifetime
            } else if transaction.productID == "com.claire.tastytidy.year" {
                subscriptionType = .yearly
            } else if transaction.productID == "com.claire.tastytidy.quarter" {
                subscriptionType = .quarterly
            } else if transaction.productID == "com.claire.tastytidy.month" {
                subscriptionType = .monthly
            }

            // Expiration date (subscriptions only — lifetime has none)
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

        // MARK: Lifetime resolution (StoreKit truth + Keychain fallback)
        //
        // `Transaction.latest(for:)` returns the latest transaction for THIS
        // Apple ID, including refunded ones. Three cases:
        //   • valid (revocationDate == nil)  → owns it, refresh Keychain cache
        //   • refunded (revocationDate != nil) → clear cache, lose access
        //   • nil (this Apple ID never bought) → trust the Keychain cache
        //     (this is the "switched Apple ID" case we want to survive)
        var ownsLifetime = false
        if let latest = await Transaction.latest(for: lifetimeID),
           let txn = try? checkVerified(latest) {
            if txn.revocationDate == nil {
                ownsLifetime = true
                LifetimeCache.set(true)        // refresh device cache
            } else {
                ownsLifetime = false
                LifetimeCache.set(false)       // refunded → revoke locally too
                newPurchased.remove(lifetimeID)
            }
        } else {
            // Current Apple ID has no record — fall back to the device cache.
            ownsLifetime = LifetimeCache.isUnlocked
        }

        if ownsLifetime {
            newPurchased.insert(lifetimeID)
            if subscriptionType == .none { subscriptionType = .lifetime }
        }

        hasLifetime = ownsLifetime
        purchasedIDs = newPurchased
        nextRenewalDate = latestExpirationDate
        currentSubscriptionType = subscriptionType

        // Display status — lifetime takes precedence (no renewal date).
        if ownsLifetime {
            displayStatus = .active(renewDate: nil)
        } else if let exp = latestExpirationDate {
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
                await transaction.finish()
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

    // MARK: - Timeout Helpers
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

    private func withTimeout<T>(
        seconds: TimeInterval = 30,
        operation: @escaping () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
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
    case lifetime

    var displayName: String {
        switch self {
        case .none: return ""
        case .monthly: return String(localized: "sub.type.monthly", defaultValue: "Monthly")
        case .quarterly: return String(localized: "sub.type.quarterly", defaultValue: "Quarterly")
        case .yearly: return String(localized: "sub.type.yearly", defaultValue: "Yearly")
        case .lifetime: return String(localized: "sub.type.lifetime", defaultValue: "Lifetime")
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
