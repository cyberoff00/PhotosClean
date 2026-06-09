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
    @Published private(set) var displayStatus: SubscriptionDisplayStatus = .none

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

    /// An auto-renewable subscription is active (has an expiration date).
    var hasActiveSubscription: Bool {
        guard let e = activeEntitlement else { return false }
        return e.expirationDate != nil
    }

    /// IDs the user currently has entitlement to (for "Current plan" badges).
    var purchasedProductIDs: Set<String> {
        guard let info = customerInfo else { return [] }
        return Set(info.entitlements.active.values.map { $0.productIdentifier })
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

    init() {
        Task {
            async let offerings: Void = loadOfferings()
            async let info: Void = refreshCustomerInfo()
            _ = await (offerings, info)
            await observeCustomerInfo()
        }
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

    func restore() async {
        do {
            let info = try await Purchases.shared.restorePurchases()
            customerInfo = info
            recomputeStatus()
        } catch {
            print("Restore failed: \(error)")
        }
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

    /// Live entitlement updates (renewals, refunds, Ask-to-Buy approvals,
    /// purchases made on other devices) without polling.
    private func observeCustomerInfo() async {
        for await info in Purchases.shared.customerInfoStream {
            customerInfo = info
            recomputeStatus()
        }
    }

    private func recomputeStatus() {
        guard let e = activeEntitlement else {
            nextRenewalDate = nil
            currentSubscriptionType = .none
            displayStatus = .none
            return
        }

        nextRenewalDate = e.expirationDate
        currentSubscriptionType = subscriptionType(for: e.productIdentifier)

        if let exp = e.expirationDate {
            if e.periodType == .trial {
                let days = Int(ceil(exp.timeIntervalSinceNow / 86_400.0))
                displayStatus = .trial(daysLeft: max(days, 0), renewDate: exp)
            } else {
                displayStatus = .active(renewDate: exp)
            }
        } else {
            // Lifetime — no renewal date.
            displayStatus = .active(renewDate: nil)
        }
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
