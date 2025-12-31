//
//  SubscriptionView.swift
//  PhotosClean
//
//  Updated: Yearly + Best Value, removed Lifetime
//

import SwiftUI
import StoreKit

struct SubscriptionView: View {
    @EnvironmentObject var storeManager: StoreManager
    @Environment(\.dismiss) var dismiss

    @State private var isRestoring = false
    @State private var selectedProductID: String?
    @State private var hasInitialized = false

    // MARK: - Product sorting
    private func sortProducts(_ products: [Product]) -> [Product] {
        func rank(_ p: Product) -> Int {
            guard let period = p.subscription?.subscriptionPeriod else { return 99 }
            if period.unit == .year && period.value == 1 { return 0 }   // Yearly first
            if period.unit == .month && period.value == 3 { return 1 }  // Quarterly
            if period.unit == .month && period.value == 1 { return 2 }  // Monthly
            return 99
        }
        return products.sorted { rank($0) < rank($1) }
    }

    private var products: [Product] {
        sortProducts(storeManager.products)
    }

    private var selectedProduct: Product? {
        if let id = selectedProductID, let p = products.first(where: { $0.id == id }) {
            return p
        }

        // Default select: Yearly (best value)
        if let yearly = products.first(where: {
            $0.subscription?.subscriptionPeriod.unit == .year &&
            $0.subscription?.subscriptionPeriod.value == 1
        }) {
            return yearly
        }

        // fallback quarterly -> monthly
        if let quarterly = products.first(where: {
            $0.subscription?.subscriptionPeriod.unit == .month &&
            $0.subscription?.subscriptionPeriod.value == 3
        }) {
            return quarterly
        }

        if let monthly = products.first(where: {
            $0.subscription?.subscriptionPeriod.unit == .month &&
            $0.subscription?.subscriptionPeriod.value == 1
        }) {
            return monthly
        }

        return products.first
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

            if storeManager.hasUnlockedPremium {
                subscribedContent
            } else {
                unsubscribedContent
            }
        }
        .onAppear {
            guard !hasInitialized else { return }
            hasInitialized = true
            Task { await storeManager.updatePurchasedProducts() }
        }
    }

    // MARK: - Subscribed content
    private var subscribedContent: some View {
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
                FeatureRow(icon: "checkmark.circle.fill", textKey: "sub.feature.history")
                FeatureRow(icon: "nosign", textKey: "sub.feature.privacy")
            }
            .padding(.vertical, 6)

            if let current = storeManager.currentSubscription {
                Text("sub.current.plan".localized(with: current.displayName, current.displayPrice))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            // Manage subscription
            Button {
                Task {
                    await openManageSubscriptions()
                }
            } label: {
                Text("sub.manage.subscription")
                    .bold()
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color(.secondarySystemBackground))
                    .foregroundColor(.orange)
                    .cornerRadius(16)
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
                FeatureRow(icon: "sparkles", textKey: "sub.feature.unlimited")
                FeatureRow(icon: "clock.arrow.circlepath", textKey: "sub.feature.history")
                FeatureRow(icon: "nosign", textKey: "sub.feature.privacy")
            }
            .padding(.vertical, 6)

            Spacer()

            // Plans
            if products.isEmpty {
                ProgressView()
            } else {
                VStack(spacing: 12) {
                    ForEach(products, id: \.id) { product in
                        PlanRow(
                            product: product,
                            isSelected: selectedProductID == nil
                                ? (product.id == selectedProduct?.id)
                                : (product.id == selectedProductID),
                            title: planTitleKey(for: product),
                            subtitle: planSubtitle(for: product),
                            badgeText: badgeText(for: product)
                        ) {
                            selectedProductID = product.id
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        }
                    }
                }
            }

            // CTA
            if let product = selectedProduct {
                Button {
                    Task {
                        do {
                            try await storeManager.buy(product)
                            if storeManager.hasUnlockedPremium { dismiss() }
                        } catch {
                            print("Purchase failed: \(error)")
                        }
                    }
                } label: {
                    VStack(spacing: 4) {
                        Text(primaryCTA(for: product)).bold()
                        Text(secondaryCTA(for: product))
                            .font(.caption2)
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.orange)
                    .foregroundColor(.white)
                    .cornerRadius(16)
                    .shadow(color: .orange.opacity(0.3), radius: 10, y: 5)
                }
                .disabled(storeManager.isLoadingPurchase)
            }

            bottomLegalLinks
        }
        .padding(30)
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

                    do {
                        try await AppStore.sync()
                    } catch {
                        print("AppStore.sync failed: \(error)")
                    }

                    try? await Task.sleep(for: .milliseconds(500))
                    await storeManager.updatePurchasedProducts()

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
                Link("sub.privacy", destination: URL(string: "https://seasoned-author-d9f.notion.site/TastyTidy-Privacy-Policy-Terms-of-Service-2db01b2ced5980e485e7ce0495e0b40e?pvs=143")!)
                Text("•").foregroundColor(.gray.opacity(0.5))
                Link("sub.terms", destination: URL(string: "https://seasoned-author-d9f.notion.site/TastyTidy-Privacy-Policy-Terms-of-Service-2db01b2ced5980e485e7ce0495e0b40e?pvs=143")!)
            }
            .font(.caption2)
            .foregroundColor(.secondary)
        }
        .padding(.bottom, 10)
    }

    private func openManageSubscriptions() async {
        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
            do { try await AppStore.showManageSubscriptions(in: scene) }
            catch { print("Failed to open manage subscriptions: \(error)") }
        }
    }

    // MARK: - Copy helpers
    private func planTitleKey(for product: Product) -> LocalizedStringKey {
        if let period = product.subscription?.subscriptionPeriod,
           period.unit == .year, period.value == 1 {
            return "sub.plan.yearly.title"
        }
        if let period = product.subscription?.subscriptionPeriod,
           period.unit == .month, period.value == 3 {
            return "sub.plan.quarterly.title"
        }
        if let period = product.subscription?.subscriptionPeriod,
           period.unit == .month, period.value == 1 {
            return "sub.plan.monthly.title"
        }
        return "sub.plan.default.title"
    }

    private func planSubtitle(for product: Product) -> String {
        if let period = product.subscription?.subscriptionPeriod {
            if period.unit == .year && period.value == 1 {
                return String(localized: "sub.plan.yearly.subtitle", defaultValue: "%@ / year")
                    .replacingOccurrences(of: "%@", with: product.displayPrice)
            }
            if period.unit == .month && period.value == 3 {
                return String(localized: "sub.plan.quarterly.subtitle", defaultValue: "%@ / 3 months")
                    .replacingOccurrences(of: "%@", with: product.displayPrice)
            }
            if period.unit == .month && period.value == 1 {
                return String(localized: "sub.plan.monthly.subtitle", defaultValue: "%@ / month")
                    .replacingOccurrences(of: "%@", with: product.displayPrice)
            }
        }
        return product.displayPrice
    }

    /// Badge priority: Best Value (yearly) > Trial
    private func badgeText(for product: Product) -> String? {
        if let period = product.subscription?.subscriptionPeriod,
           period.unit == .year, period.value == 1 {
            return String(localized: "sub.badge.bestvalue", defaultValue: "Best Value")
        }

        guard let sub = product.subscription else { return nil }
        if let intro = sub.introductoryOffer, intro.paymentMode == .freeTrial {
            return String(localized: "sub.badge.trial7", defaultValue: "7-day free trial")
        }
        return nil
    }

    private func primaryCTA(for product: Product) -> String {
        if badgeText(for: product) == String(localized: "sub.badge.trial7", defaultValue: "7-day free trial") {
            return String(localized: "sub.cta.trial7", defaultValue: "Start free trial")
        }
        return String(localized: "sub.cta.subscribe", defaultValue: "Continue")
    }

    private func secondaryCTA(for product: Product) -> String {
        if let period = product.subscription?.subscriptionPeriod {
            if period.unit == .year && period.value == 1 {
                return String(localized: "sub.cta.then.yearly", defaultValue: "Then %@ / year")
                    .replacingOccurrences(of: "%@", with: product.displayPrice)
            }
            if period.unit == .month && period.value == 3 {
                return String(localized: "sub.cta.then.quarterly", defaultValue: "Then %@ / 3 months")
                    .replacingOccurrences(of: "%@", with: product.displayPrice)
            }
            if period.unit == .month && period.value == 1 {
                return String(localized: "sub.cta.then.monthly", defaultValue: "Then %@ / month")
                    .replacingOccurrences(of: "%@", with: product.displayPrice)
            }
        }
        return product.displayPrice
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
    let product: Product
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
