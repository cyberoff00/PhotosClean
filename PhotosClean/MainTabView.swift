import SwiftUI

struct MainTabView: View {
    @EnvironmentObject var storeManager: StoreManager
    @EnvironmentObject var paywallGate: PaywallGate
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
        }.sheet(isPresented: $paywallGate.showPaywall) {
            SubscriptionView()
                .environmentObject(storeManager)
        }}
}
