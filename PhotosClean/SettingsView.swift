import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var storeManager: StoreManager
    @EnvironmentObject var paywallGate: PaywallGate
    @EnvironmentObject var storageStats: StorageStats
    @Environment(\.openURL) private var openURL

    @State private var showFreedExplanation = false

    private let appStoreAppID = "6757628907"
    private let legalURL = URL(string: "https://seasoned-author-d9f.notion.site/TastyTidy-Privacy-Policy-Terms-of-Service-2db01b2ced5980e485e7ce0495e0b40e?pvs=143") ?? URL(string: "https://apple.com")!

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

            Section("settings.cleanup.section".localized) {
                Picker(selection: goalBinding) {
                    ForEach(StorageStats.goalOptions, id: \.self) { bytes in
                        Text(goalLabel(bytes)).tag(bytes)
                    }
                } label: {
                    Label("settings.cleanup.daily_goal".localized, systemImage: "target")
                }

                if storageStats.goalEnabled {
                    HStack {
                        Label("settings.cleanup.today".localized, systemImage: "chart.bar.fill")
                        Spacer()
                        Text("\(storageStats.dailyPendingPeak.byteCountShort) / \(StorageStats.goalLabel(storageStats.dailyGoalBytes))")
                            .foregroundColor(storageStats.goalAchievedToday ? .green : .secondary)
                            .font(.caption.monospacedDigit())
                    }
                }

                if storageStats.totalBytesCleaned > 0 {
                    HStack(spacing: 6) {
                        Label("settings.cleanup.total".localized, systemImage: "tray.full")
                        Button { showFreedExplanation = true } label: {
                            Image(systemName: "questionmark.circle")
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                        Spacer()
                        Text(storageStats.totalBytesCleaned.byteCountShort)
                            .foregroundColor(.secondary)
                            .font(.caption.monospacedDigit())
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
        .alert("settings.cleanup.total".localized, isPresented: $showFreedExplanation) {
            Button("common.ok".localized, role: .cancel) {}
        } message: {
            Text("settings.cleanup.total.explain".localized)
        }
    }

    private var goalBinding: Binding<Int64> {
        Binding(
            get: { storageStats.dailyGoalBytes },
            set: { storageStats.setDailyGoal($0) }
        )
    }

    private func goalLabel(_ bytes: Int64) -> String {
        bytes == 0 ? "settings.cleanup.goal_off".localized : StorageStats.goalLabel(bytes)
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
