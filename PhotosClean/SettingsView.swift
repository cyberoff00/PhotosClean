import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var storeManager: StoreManager
    @EnvironmentObject var paywallGate: PaywallGate
    @EnvironmentObject var storageStats: StorageStats
    @Environment(\.openURL) private var openURL

    @State private var showFreedExplanation = false
    @State private var showFeedback = false
    @AppStorage("prewarm_use_cellular") private var prewarmUseCellular: Bool = true
    @AppStorage(SwipeSoundStyle.storageKey) private var swipeSoundRaw: String = SwipeSoundStyle.off.rawValue
    #if DEBUG
    @AppStorage("debug_simulate_delete_drop") private var debugSimulateDeleteDrop: Bool = false
    #endif

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
                        Text("\(String(format: "settings.cleanup.today.count".localized, storageStats.dailyMarkedCount)) · \(storageStats.dailyMarkedBytes.byteCountShort) / \(StorageStats.goalLabel(storageStats.dailyGoalBytes))")
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

            Section {
                Toggle(isOn: $prewarmUseCellular) {
                    Label("settings.prewarm.cellular".localized, systemImage: "antenna.radiowaves.left.and.right")
                }
            } header: {
                Text("settings.download.section".localized)
            } footer: {
                Text("settings.prewarm.cellular.footer".localized)
            }

            Section {
                Picker(selection: swipeSoundBinding) {
                    ForEach(SwipeSoundStyle.allCases) { style in
                        Text(style.label).tag(style)
                    }
                } label: {
                    Label("settings.sound.title".localized, systemImage: "speaker.wave.2")
                }
            } header: {
                Text("settings.sound.section".localized)
            } footer: {
                Text("settings.sound.footer".localized)
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

                Button {
                    showFeedback = true
                } label: {
                    Label("feedback.title".localized, systemImage: "envelope")
                }
            }

            #if DEBUG
            Section {
                Toggle(isOn: $debugSimulateDeleteDrop) {
                    Label("模拟删除框被丢弃(测重试)", systemImage: "ladybug")
                }
            } header: {
                Text("DEBUG")
            } footer: {
                Text("开启后，一键清理的第一次会假装删除框被系统丢弃，约 4 秒后自动重试把删除框弹出来——用几张照片就能验证重试逻辑。")
            }
            #endif

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
        .sheet(isPresented: $showFeedback) {
            FeedbackView()
        }
    }

    private var swipeSoundBinding: Binding<SwipeSoundStyle> {
        Binding(
            get: { SwipeSoundStyle.current() },
            set: { style in
                swipeSoundRaw = style.rawValue
                SwipeFeedback.shared.preview(style: style)
            }
        )
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
