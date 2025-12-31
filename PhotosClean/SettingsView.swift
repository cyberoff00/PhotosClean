import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var storeManager: StoreManager
    @EnvironmentObject var paywallGate: PaywallGate
    @Environment(\.openURL) private var openURL

    private let appStoreAppID = "6757628907"
    private let legalURL = URL(string: "https://seasoned-author-d9f.notion.site/TastyTidy-Privacy-Policy-Terms-of-Service-2db01b2ced5980e485e7ce0495e0b40e?pvs=143")!

    var body: some View {
        List {
            Section("settings.subscription.section".localized) {
                Button {
                    paywallGate.showPaywall = true
                } label: {
                    HStack {
                        Text("settings.subscription.title".localized)
                        Spacer()
                        Text(
                            storeManager.hasUnlockedPremium
                            ? "sub.premium.active".localized
                            : "sub.premium".localized
                        )
                        .foregroundColor(.secondary)
                    }
                }
            }

            Section("settings.general.section".localized) {
                Button {
                    openAppStore()
                } label: {
                    Label("settings.check_update".localized, systemImage: "arrow.triangle.2.circlepath")
                }

                Button {
                    openAppStoreReview()
                } label: {
                    Label("settings.rate_us".localized, systemImage: "star.bubble")
                }
            }

            Section("settings.legal.section".localized) {
                Link(destination: legalURL) {
                    Label("sub.privacy".localized, systemImage: "hand.raised")
                }

                Link(destination: legalURL) {
                    Label("sub.terms".localized, systemImage: "doc.text")
                }
            }
        }
        .navigationTitle("settings.title".localized)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func openAppStore() {
        guard let url = URL(string: "itms-apps://itunes.apple.com/app/id\(appStoreAppID)") else { return }
        openURL(url)
    }

    private func openAppStoreReview() {
        guard let url = URL(string: "itms-apps://itunes.apple.com/app/id\(appStoreAppID)?action=write-review") else { return }
        openURL(url)
    }
}
