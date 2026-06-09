//
//  SubscriptionView.swift
//  PhotosClean
//
//  RevenueCat-backed paywall. Displays packages from the current Offering and
//  purchases / restores through RevenueCat instead of raw StoreKit.
//

import SwiftUI
import RevenueCat

struct SubscriptionView: View {
    @EnvironmentObject var storeManager: StoreManager
    @Environment(\.dismiss) var dismiss

    @State private var isRestoring = false
    /// Selected package identifier (Package.identifier).
    @State private var selectedPackageID: String?
    @State private var hasInitialized = false
    @State private var showCancelSubAlert = false

    // MARK: - Package sorting
    private func sortPackages(_ packages: [Package]) -> [Package] {
        func rank(_ p: Package) -> Int {
            if isLifetime(p) { return 0 }                               // Lifetime first
            guard let period = p.storeProduct.subscriptionPeriod else { return 99 }
            if period.unit == .year && period.value == 1 { return 1 }   // Yearly
            if period.unit == .month && period.value == 3 { return 2 }  // Quarterly
            if period.unit == .month && period.value == 1 { return 3 }  // Monthly
            return 99
        }
        return packages.sorted { rank($0) < rank($1) }
    }

    /// Lifetime = non-consumable (no subscription period), or a Lifetime package.
    private func isLifetime(_ package: Package) -> Bool {
        package.packageType == .lifetime || package.storeProduct.subscriptionPeriod == nil
    }

    private func price(_ package: Package) -> String {
        package.storeProduct.localizedPriceString
    }

    private var packages: [Package] {
        sortPackages(storeManager.packages)
    }

    private var selectedPackage: Package? {
        if let id = selectedPackageID, let p = packages.first(where: { $0.identifier == id }) {
            return p
        }

        // Default select: Yearly (best value)
        if let yearly = packages.first(where: {
            $0.storeProduct.subscriptionPeriod?.unit == .year &&
            $0.storeProduct.subscriptionPeriod?.value == 1
        }) {
            return yearly
        }

        // fallback quarterly -> monthly
        if let quarterly = packages.first(where: {
            $0.storeProduct.subscriptionPeriod?.unit == .month &&
            $0.storeProduct.subscriptionPeriod?.value == 3
        }) {
            return quarterly
        }

        if let monthly = packages.first(where: {
            $0.storeProduct.subscriptionPeriod?.unit == .month &&
            $0.storeProduct.subscriptionPeriod?.value == 1
        }) {
            return monthly
        }

        return packages.first
    }

    var body: some View {
        VStack(spacing: 0) {
            // Close
            HStack {
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundColor(.gray.opacity(0.5))
                }
                Spacer()
            }
            .padding(30)
            .padding(.bottom, 10)

            if storeManager.hasLifetime {
                lifetimeOwnerContent
            } else if storeManager.hasActiveSubscription {
                subscriberContent
            } else {
                unsubscribedContent
            }
        }
        .onAppear {
            guard !hasInitialized else { return }
            hasInitialized = true
            Task {
                if storeManager.packages.isEmpty {
                    await storeManager.loadOfferings()
                }
                await storeManager.refreshCustomerInfo()
            }
        }
        .alert("sub.lifetime.cancelsub.title", isPresented: $showCancelSubAlert) {
            Button("sub.lifetime.cancelsub.action") {
                Task {
                    await openManageSubscriptions()
                    dismiss()
                }
            }
            Button("sub.lifetime.cancelsub.later", role: .cancel) {
                dismiss()
            }
        } message: {
            Text("sub.lifetime.cancelsub.message")
        }
    }

    // MARK: - Lifetime owner (top tier — nothing left to purchase)
    private var lifetimeOwnerContent: some View {
        VStack(spacing: 22) {
            Text("🎉").font(.system(size: 70))

            VStack(spacing: 8) {
                Text("sub.title.subscribed")
                    .font(.title2.bold())
                Text("sub.subtitle.subscribed")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            // Features
            VStack(alignment: .leading, spacing: 15) {
                FeatureRow(icon: "checkmark.circle.fill", textKey: "sub.feature.unlimited")
                FeatureRow(icon: "checkmark.circle.fill", textKey: "sub.feature.privacy")
                FeatureRow(icon: "checkmark.circle.fill", textKey: "sub.feature.indie")
            }
            .padding(.vertical, 6)

            Text("sub.type.lifetime")
                .font(.caption.bold())
                .foregroundColor(.orange)

            Spacer()

            bottomLegalLinks
        }
        .padding(30)
    }

    // MARK: - Active subscriber (can switch plan or upgrade to lifetime)
    private var subscriberContent: some View {
        VStack(spacing: 18) {
            Text("🎉").font(.system(size: 60))

            VStack(spacing: 8) {
                Text("sub.title.subscribed")
                    .font(.title2.bold())
                Text("sub.manage.subtitle")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }

            if let current = storeManager.currentSubscription {
                Text("sub.current.plan".localized(with: current.storeProduct.localizedTitle, price(current)))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            // Full plan picker so a subscriber can crossgrade (month/quarter/
            // year) or upgrade to lifetime at any time. RevenueCat / StoreKit
            // handle proration for same-group subscription changes.
            planSelector

            // Manage / cancel the active auto-renewable subscription.
            Button {
                Task { await openManageSubscriptions() }
            } label: {
                Text("sub.manage.subscription")
                    .font(.subheadline)
                    .foregroundColor(.orange)
            }

            bottomLegalLinks
        }
        .padding(30)
    }

    // MARK: - Unsubscribed content
    private var unsubscribedContent: some View {
        VStack(spacing: 22) {
            Text("🍪").font(.system(size: 70))

            VStack(spacing: 8) {
                Text("sub.title")
                    .font(.title2.bold())
                Text("sub.subtitle")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            // Features
            VStack(alignment: .leading, spacing: 15) {
                FeatureRow(icon: "infinity", textKey: "sub.feature.unlimited")
                FeatureRow(icon: "lock.shield", textKey: "sub.feature.privacy")
                FeatureRow(icon: "heart.fill", textKey: "sub.feature.indie")
            }
            .padding(.vertical, 6)

            Spacer()

            planSelector

            bottomLegalLinks
        }
        .padding(30)
    }

    // MARK: - Shared plan picker + purchase CTA
    // Used by both the free-user paywall and the active-subscriber screen, so a
    // member can switch plan / upgrade to lifetime from the same UI.
    private var planSelector: some View {
        VStack(spacing: 12) {
            if packages.isEmpty && storeManager.productLoadFailed {
                loadFailedHint
            } else if packages.isEmpty {
                ProgressView()
            } else {
                VStack(spacing: 12) {
                    ForEach(packages, id: \.identifier) { package in
                        let isCurrent = !isLifetime(package)
                            && storeManager.purchasedProductIDs.contains(package.storeProduct.productIdentifier)
                        PlanRow(
                            package: package,
                            isSelected: selectedPackageID == nil
                                ? (package.identifier == selectedPackage?.identifier)
                                : (package.identifier == selectedPackageID),
                            title: planTitleKey(for: package),
                            subtitle: planSubtitle(for: package),
                            badgeText: planBadge(for: package, isCurrent: isCurrent)
                        ) {
                            selectedPackageID = package.identifier
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        }
                    }
                }
            }

            if let package = selectedPackage {
                purchaseCTA(for: package)
            }
        }
    }

    @ViewBuilder
    private func purchaseCTA(for package: Package) -> some View {
        // Buying the plan you're already on is a no-op — disable it instead.
        let isCurrentPlan = !isLifetime(package)
            && storeManager.purchasedProductIDs.contains(package.storeProduct.productIdentifier)

        Button {
            Task {
                do {
                    try await storeManager.purchase(package)
                    guard storeManager.hasUnlockedPremium else { return }
                    // If the user just bought lifetime but still has an active
                    // auto-renewable subscription, prompt them to cancel it so
                    // they aren't charged twice.
                    if isLifetime(package) && storeManager.hasActiveSubscription {
                        showCancelSubAlert = true
                    } else {
                        dismiss()
                    }
                } catch {
                    print("Purchase failed: \(error)")
                }
            }
        } label: {
            VStack(spacing: 4) {
                Text(isCurrentPlan
                     ? String(localized: "sub.cta.current", defaultValue: "Current plan")
                     : primaryCTA(for: package))
                    .bold()
                if !isCurrentPlan {
                    Text(secondaryCTA(for: package))
                        .font(.caption2)
                }
            }
            .frame(maxWidth: .infinity)
            .padding()
            .background(isCurrentPlan ? Color.gray.opacity(0.4) : Color.orange)
            .foregroundColor(.white)
            .cornerRadius(16)
            .shadow(color: isCurrentPlan ? .clear : .orange.opacity(0.3), radius: 10, y: 5)
        }
        .disabled(storeManager.isLoadingPurchase || isCurrentPlan)
    }

    private var loadFailedHint: some View {
        VStack(spacing: 14) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 32))
                .foregroundColor(.secondary)

            Text("sub.load.failed.title")
                .font(.subheadline.bold())
                .multilineTextAlignment(.center)

            Text("sub.load.failed.hint")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            Button {
                Task { await storeManager.loadOfferings() }
            } label: {
                Label("sub.load.failed.retry", systemImage: "arrow.clockwise")
                    .font(.subheadline.bold())
                    .padding(.horizontal, 24)
                    .padding(.vertical, 10)
                    .background(Color.orange)
                    .foregroundColor(.white)
                    .cornerRadius(12)
            }
        }
        .padding(.vertical, 8)
    }

    // MARK: - Bottom links (restore + legal)
    private var bottomLegalLinks: some View {
        VStack(spacing: 12) {
            let restoreDisabled = isRestoring || storeManager.isLoadingPurchase

            Button {
                guard !restoreDisabled else { return }
                isRestoring = true

                Task {
                    defer { isRestoring = false }
                    await storeManager.restore()
                    if storeManager.hasUnlockedPremium { dismiss() }
                }
            } label: {
                if isRestoring {
                    ProgressView().controlSize(.small)
                } else {
                    Text("sub.restore")
                        .font(.caption)
                        .foregroundColor(restoreDisabled ? .gray.opacity(0.6) : .orange)
                }
            }
            .disabled(restoreDisabled)

            HStack(spacing: 15) {
                if let url = URL(string: "https://seasoned-author-d9f.notion.site/TastyTidy-Privacy-Policy-Terms-of-Service-2db01b2ced5980e485e7ce0495e0b40e?pvs=143") {
                    Link("sub.privacy", destination: url)
                    Text("•").foregroundColor(.gray.opacity(0.5))
                    Link("sub.terms", destination: url)
                }
            }
            .font(.caption2)
            .foregroundColor(.secondary)
        }
        .padding(.bottom, 10)
    }

    private func openManageSubscriptions() async {
        do { try await Purchases.shared.showManageSubscriptions() }
        catch { print("Failed to open manage subscriptions: \(error)") }
    }

    // MARK: - Copy helpers
    private func planTitleKey(for package: Package) -> LocalizedStringKey {
        if isLifetime(package) {
            return "sub.plan.lifetime.title"
        }
        if let period = package.storeProduct.subscriptionPeriod,
           period.unit == .year, period.value == 1 {
            return "sub.plan.yearly.title"
        }
        if let period = package.storeProduct.subscriptionPeriod,
           period.unit == .month, period.value == 3 {
            return "sub.plan.quarterly.title"
        }
        if let period = package.storeProduct.subscriptionPeriod,
           period.unit == .month, period.value == 1 {
            return "sub.plan.monthly.title"
        }
        return "sub.plan.default.title"
    }

    private func planSubtitle(for package: Package) -> String {
        if isLifetime(package) {
            return String(localized: "sub.plan.lifetime.subtitle", defaultValue: "%@ · one-time")
                .replacingOccurrences(of: "%@", with: price(package))
        }
        if let period = package.storeProduct.subscriptionPeriod {
            if period.unit == .year && period.value == 1 {
                return String(localized: "sub.plan.yearly.subtitle", defaultValue: "%@ / year")
                    .replacingOccurrences(of: "%@", with: price(package))
            }
            if period.unit == .month && period.value == 3 {
                return String(localized: "sub.plan.quarterly.subtitle", defaultValue: "%@ / 3 months")
                    .replacingOccurrences(of: "%@", with: price(package))
            }
            if period.unit == .month && period.value == 1 {
                return String(localized: "sub.plan.monthly.subtitle", defaultValue: "%@ / month")
                    .replacingOccurrences(of: "%@", with: price(package))
            }
        }
        return price(package)
    }

    /// Lifetime is the headline "Best Value"; any subscription carrying a
    /// free-trial intro offer (the yearly plan) shows the trial badge.
    private func badgeText(for package: Package) -> String? {
        if isLifetime(package) {
            return String(localized: "sub.badge.bestvalue", defaultValue: "Best Value")
        }
        if let intro = package.storeProduct.introductoryDiscount, intro.paymentMode == .freeTrial {
            return String(localized: "sub.badge.trial7", defaultValue: "7-day free trial")
        }
        return nil
    }

    /// Badge for a plan row. Marks the user's current subscription, keeps the
    /// "Best Value" badge on lifetime, and suppresses the free-trial badge once
    /// the user already has a subscription (they're no longer trial-eligible).
    private func planBadge(for package: Package, isCurrent: Bool) -> String? {
        if isCurrent {
            return String(localized: "sub.badge.current", defaultValue: "Current")
        }
        if isLifetime(package) {
            return String(localized: "sub.badge.bestvalue", defaultValue: "Best Value")
        }
        if storeManager.hasActiveSubscription {
            return nil
        }
        return badgeText(for: package)
    }

    private func primaryCTA(for package: Package) -> String {
        if isLifetime(package) {
            return storeManager.hasActiveSubscription
                ? String(localized: "sub.cta.lifetime.upgrade", defaultValue: "Upgrade to Lifetime")
                : String(localized: "sub.cta.lifetime", defaultValue: "Buy Lifetime")
        }
        // Switching between subscription tiers — no new free trial is granted.
        if storeManager.hasActiveSubscription {
            return String(localized: "sub.cta.switch", defaultValue: "Switch to this plan")
        }
        if badgeText(for: package) == String(localized: "sub.badge.trial7", defaultValue: "7-day free trial") {
            return String(localized: "sub.cta.trial7", defaultValue: "Start free trial")
        }
        return String(localized: "sub.cta.subscribe", defaultValue: "Continue")
    }

    private func secondaryCTA(for package: Package) -> String {
        if isLifetime(package) {
            return String(localized: "sub.cta.lifetime.detail", defaultValue: "Pay once, keep forever")
        }
        if let period = package.storeProduct.subscriptionPeriod {
            if period.unit == .year && period.value == 1 {
                return String(localized: "sub.cta.then.yearly", defaultValue: "Then %@ / year")
                    .replacingOccurrences(of: "%@", with: price(package))
            }
            if period.unit == .month && period.value == 3 {
                return String(localized: "sub.cta.then.quarterly", defaultValue: "Then %@ / 3 months")
                    .replacingOccurrences(of: "%@", with: price(package))
            }
            if period.unit == .month && period.value == 1 {
                return String(localized: "sub.cta.then.monthly", defaultValue: "Then %@ / month")
                    .replacingOccurrences(of: "%@", with: price(package))
            }
        }
        return price(package)
    }
}

// MARK: - FeatureRow
struct FeatureRow: View {
    let icon: String
    let textKey: LocalizedStringKey

    var body: some View {
        HStack {
            Image(systemName: icon)
                .foregroundColor(.orange)
                .frame(width: 30)
            Text(textKey)
                .font(.subheadline)
        }
    }
}

// MARK: - PlanRow UI
private struct PlanRow: View {
    let package: Package
    let isSelected: Bool
    let title: LocalizedStringKey
    let subtitle: String
    let badgeText: String?
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(isSelected ? .orange : .secondary)
                    .font(.title3)

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(title)
                            .font(.headline)

                        if let badgeText {
                            Text(badgeText)
                                .font(.caption2.bold())
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.orange.opacity(0.18))
                                .foregroundColor(.orange)
                                .clipShape(Capsule())
                        }
                    }

                    Text(subtitle)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .monospacedDigit()
                }

                Spacer()
            }
            .padding(12)
            .background(isSelected ? Color.orange.opacity(0.10) : Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }
}
