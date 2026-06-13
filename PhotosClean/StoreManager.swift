//
//  StoreManager.swift
//  PhotosClean
//
//  Backed by RevenueCat. Offerings (prices) and entitlements are cached by the
//  RevenueCat SDK, so the paywall no longer hangs on slow App Store Connect
//  catalog / network responses the way raw StoreKit `Product.products(for:)` did.
//
//  Public surface kept stable for the rest of the app: every other screen only
//  reads `hasUnlockedPremium`. The paywall additionally uses `packages`,
//  `purchase`, `restore`, `hasActiveSubscription`, `hasLifetime`,
//  `currentSubscription`, `isLoadingPurchase`, `productLoadFailed`.
//

import SwiftUI
import RevenueCat
import Combine

@MainActor
final class StoreManager: ObservableObject {

    /// Entitlement identifier configured in the RevenueCat dashboard.
    /// MUST match the Entitlement identifier exactly.
    static let entitlementID = "TastyTidy: Cleanup and Note Pro"

    // Product identifiers — must match App Store Connect AND RevenueCat.
    private let lifetimeID = "com.claire.tastytidy.forever"
    private let subscriptionIDs: Set<String> = [
        "com.claire.tastytidy.month",
        "com.claire.tastytidy.quarter",
        "com.claire.tastytidy.year"
    ]

    // MARK: - Published state

    /// Packages from the current RevenueCat Offering (drives the paywall).
    @Published private(set) var packages: [Package] = []

    /// Latest entitlement snapshot from RevenueCat.
    @Published private(set) var customerInfo: CustomerInfo?

    @Published private(set) var nextRenewalDate: Date?
    @Published private(set) var currentSubscriptionType: SubscriptionType = .none

    // UI state
    @Published var isLoadingPurchase: Bool = false
    @Published var productLoadFailed: Bool = false

    // MARK: - Derived entitlement helpers

    /// The active "premium" entitlement, or nil if the user isn't premium.
    private var activeEntitlement: EntitlementInfo? {
        guard let e = customerInfo?.entitlements[Self.entitlementID], e.isActive else { return nil }
        return e
    }

    /// Single source of truth used everywhere else in the app.
    var hasUnlockedPremium: Bool { activeEntitlement != nil }

    /// Lifetime (non-consumable) entitlement has no expiration date.
    var hasLifetime: Bool {
        guard let e = activeEntitlement else { return false }
        return e.expirationDate == nil
    }

    /// An auto-renewable subscription is currently active (includes grace
    /// period). Derived from `activeSubscriptions` rather than the entitlement:
    /// once a lifetime purchase takes over the entitlement, the entitlement no
    /// longer reflects a still-renewing subscription, but `activeSubscriptions`
    /// does — which is what the "cancel your subscription" prompt needs.
    var hasActiveSubscription: Bool {
        guard let info = customerInfo else { return false }
        return !info.activeSubscriptions.isEmpty
    }

    /// IDs the user currently owns (for "Current plan" badges): the union of
    /// active auto-renewable subscriptions and entitlement-granting products
    /// (lifetime), so a subscription row keeps its "Current" badge even after
    /// the entitlement is backed by a lifetime purchase.
    var purchasedProductIDs: Set<String> {
        guard let info = customerInfo else { return [] }
        return info.activeSubscriptions
            .union(info.entitlements.active.values.map { $0.productIdentifier })
    }

    /// The package matching the user's active subscription, if any.
    var currentSubscription: Package? {
        guard let pid = activeEntitlement?.productIdentifier else { return nil }
        return packages.first { $0.storeProduct.productIdentifier == pid }
    }

    var formattedRenewalDate: String {
        guard let date = nextRenewalDate else { return "" }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    func isPurchased(_ package: Package) -> Bool {
        purchasedProductIDs.contains(package.storeProduct.productIdentifier)
    }

    // MARK: - Lifecycle

    /// Handle for the initial-load + customerInfoStream task so it can be
    /// cancelled when the manager goes away (the stream never finishes on its
    /// own, which would otherwise keep the Task alive forever).
    private var customerInfoTask: Task<Void, Never>?

    init() {
        customerInfoTask = Task { [weak self] in
            // Initial parallel load. The strong reference is scoped so it isn't
            // held across the never-finishing stream loop below.
            if let self {
                async let offerings: Void = self.loadOfferings()
                async let info: Void = self.refreshCustomerInfo()
                _ = await (offerings, info)
            }
            for await info in Purchases.shared.customerInfoStream {
                guard !Task.isCancelled, let self else { return }
                self.customerInfo = info
                self.recomputeStatus()
            }
        }
    }

    deinit {
        customerInfoTask?.cancel()
    }

    // MARK: - Offerings (prices)

    /// Loads the current Offering's packages. RevenueCat returns cached
    /// offerings instantly after the first fetch and retries network failures
    /// internally, so this resolves fast and rarely fails outright.
    func loadOfferings() async {
        do {
            let offerings = try await Purchases.shared.offerings()
            guard let current = offerings.current else {
                // No current offering configured in the dashboard.
                productLoadFailed = packages.isEmpty
                return
            }
            packages = sortPackages(current.availablePackages)
            productLoadFailed = false
        } catch {
            print("Offerings load failed: \(error)")
            // Only surface failure if we have nothing cached to show.
            productLoadFailed = packages.isEmpty
        }
    }

    private func sortPackages(_ pkgs: [Package]) -> [Package] {
        pkgs.sorted { rank($0) < rank($1) }
    }

    /// Yearly first, then quarterly, monthly, lifetime last.
    private func rank(_ p: Package) -> Int {
        if p.storeProduct.productType == .nonConsumable { return 3 }
        guard let period = p.storeProduct.subscriptionPeriod else { return 99 }
        if period.unit == .year && period.value == 1 { return 0 }
        if period.unit == .month && period.value == 3 { return 1 }
        if period.unit == .month && period.value == 1 { return 2 }
        return 99
    }

    // MARK: - Purchase / Restore

    func purchase(_ package: Package) async throws {
        isLoadingPurchase = true
        defer { isLoadingPurchase = false }

        let result = try await Purchases.shared.purchase(package: package)
        if result.userCancelled { return }
        customerInfo = result.customerInfo
        recomputeStatus()
    }

    /// Outcome of a restore attempt that reached RevenueCat successfully.
    /// Network / store errors are thrown instead.
    enum RestoreOutcome {
        /// The premium entitlement is active after restoring.
        case restored
        /// Restore succeeded but this Apple ID has nothing that grants premium.
        case nothingToRestore
    }

    func restore() async throws -> RestoreOutcome {
        let info = try await Purchases.shared.restorePurchases()
        customerInfo = info
        recomputeStatus()
        return hasUnlockedPremium ? .restored : .nothingToRestore
    }

    // MARK: - Entitlements

    /// Pulls the latest entitlement snapshot from RevenueCat (cached + fast).
    func refreshCustomerInfo() async {
        do {
            let info = try await Purchases.shared.customerInfo()
            customerInfo = info
            recomputeStatus()
        } catch {
            print("customerInfo failed: \(error)")
        }
    }

    private func recomputeStatus() {
        guard let e = activeEntitlement else {
            nextRenewalDate = nil
            currentSubscriptionType = .none
            return
        }

        nextRenewalDate = e.expirationDate
        currentSubscriptionType = subscriptionType(for: e.productIdentifier)
    }

    private func subscriptionType(for productID: String) -> SubscriptionType {
        if productID == lifetimeID { return .lifetime }
        if subscriptionIDs.contains(productID) {
            if productID.hasSuffix(".year") { return .yearly }
            if productID.hasSuffix(".quarter") { return .quarterly }
            if productID.hasSuffix(".month") { return .monthly }
        }
        return .none
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
