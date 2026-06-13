import SwiftUI
import StoreKit

struct MainTabView: View {
    @EnvironmentObject var storeManager: StoreManager
    @EnvironmentObject var paywallGate: PaywallGate
    @EnvironmentObject var ratingPrompt: RatingPrompt
    @Environment(\.requestReview) private var requestReview
    var body: some View {
        TabView {

            // Today：只负责"今天的 asset 来源"
            ContentView()
                .tabItem {
                    Label("tab.today".localized, systemImage: "sparkles")
                }

            // Archive：Grid + Folder + 搜索
            LibraryView()
                .tabItem {
                    Label("tab.library".localized, systemImage: "rectangle.stack")
                }
        }
        .sheet(isPresented: $paywallGate.showPaywall) {
            SubscriptionView()
                .environmentObject(storeManager)
        }
        // Rating gate: "Enjoying TastyTidy?" → happy users to the App Store
        // review prompt, unhappy users to the in-app feedback page.
        .alert("rating.ask.title".localized, isPresented: $ratingPrompt.showAsk) {
            Button("rating.ask.like".localized) {
                ratingPrompt.userLikes(requestReview)
            }
            Button("rating.ask.dislike".localized) {
                ratingPrompt.userDislikes()
            }
            Button("rating.ask.later".localized, role: .cancel) {
                ratingPrompt.userDismissed()
            }
        } message: {
            Text("rating.ask.message".localized)
        }
        .sheet(isPresented: $ratingPrompt.showFeedback) {
            FeedbackView()
        }
    }
}
