import SwiftUI
import SwiftData
import Photos

struct LibraryView: View {
    @EnvironmentObject var storeManager: StoreManager
    @EnvironmentObject var paywallGate: PaywallGate

    @Query private var allTags: [PhotoTag]
    @State private var folderCounts: [String: Int] = [:]

//    // ✅ 你现在的 Notion 页面同时包含 Privacy + Terms，就先复用同一个 URL
//    //    如果你之后拆成两个页面，把 termsURL 换成新的即可
//    private let privacyURL = URL(
//        string: "https://seasoned-author-d9f.notion.site/TastyTidy-Privacy-Policy-Terms-of-Service-2db01b2ced5980e485e7ce0495e0b40e?pvs=143"
//    )!
//
//    private let termsURL = URL(
//        string: "https://seasoned-author-d9f.notion.site/TastyTidy-Privacy-Policy-Terms-of-Service-2db01b2ced5980e485e7ce0495e0b40e?pvs=143"
//    )!

    var body: some View {
        NavigationStack {
            List {
                NavigationLink(
                    destination: PhotoGridView(
                        title: "library.title".localized,
                        filterStatus: nil
                    )
                ) {
                    FolderRow(
                        title: "library.title".localized,
                        titleFont: .subheadline,
                        icon: "photo.on.rectangle",
                        color: .blue,
                        count: folderCounts["all"] ?? 0
                    )
                }

                // ✅ Move “Unmarked” right below “All Photos” for clarity
                NavigationLink(
                    destination: PhotoGridView(
                        title: "library.unmarked".localized,
                        filterStatus: "pending"
                    )
                ) {
                    FolderRow(
                        title: "library.unmarked".localized,
                        titleFont: .subheadline,
                        icon: "clock.badge.checkmark",
                        color: .orange,
                        count: folderCounts["pending"] ?? 0
                    )
                }

                Section("library.category".localized) {
                    NavigationLink(
                        destination: PhotoGridView(
                            title: "library.favorites".localized,
                            filterStatus: "keep"
                        )
                    ) {
                        FolderRow(
                            title: "library.favorites".localized,
                            icon: "heart.fill",
                            color: .green,
                            count: folderCounts["keep"] ?? 0
                        )
                    }

                    NavigationLink(
                        destination: PhotoGridView(
                            title: "library.maybe".localized,
                            filterStatus: "maybe"
                        )
                    ) {
                        FolderRow(
                            title: "library.maybe".localized,
                            icon: "questionmark.circle.fill",
                            color: .yellow,
                            count: folderCounts["maybe"] ?? 0
                        )
                    }

                    NavigationLink(
                        destination: PhotoGridView(
                            title: "library.toDelete".localized,
                            filterStatus: "delete"
                        )
                    ) {
                        FolderRow(
                            title: "library.toDelete".localized,
                            icon: "trash.fill",
                            color: .red,
                            count: folderCounts["delete"] ?? 0
                        )
                    }
                }
            }
            .navigationTitle("library.retroView".localized)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        SettingsView()
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("settings.title".localized)
                }
            }
            .onAppear(perform: calculateCounts)

            // ✅ 放在 TabBar 上方：透明、不带背景、不像 tab 的一部分
            .safeAreaInset(edge: .bottom, spacing: 0) {
                footerLinks
                    .padding(.bottom, 8)
            }
        }
        // ✅ paywall sheet 已经挂在 MainTabView 了，这里不要再挂
    }

    private var footerLinks: some View {
        HStack(spacing: 10) {
            // ✅ Terms
//            Link(String(localized: "sub.terms"), destination: termsURL)
//
//            Text("|")
//                .foregroundColor(.secondary.opacity(0.55))
//
//            // ✅ Privacy
//            Link(String(localized: "sub.privacy"), destination: privacyURL)
//
//            Text("|")
//                .foregroundColor(.secondary.opacity(0.55))

            // ✅ Premium：无论是否已解锁，都能打开订阅入口（让用户查看/恢复/换方案）
            Button {
                paywallGate.showPaywall = true
            } label: {
                Text(
                    storeManager.hasUnlockedPremium
                    ? String(localized: "sub.premium.active")
                    : String(localized: "sub.premium")
                )
            }
            .buttonStyle(.plain)
        }
        .font(.caption2)
        .foregroundColor(.secondary)
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 6)
        .background(Color.clear)
    }

    func calculateCounts() {
        let fetchedAssets = PHAsset.fetchAssets(with: .image, options: nil)
        var assetIDs: [String] = []
        assetIDs.reserveCapacity(fetchedAssets.count)
        fetchedAssets.enumerateObjects { asset, _, _ in
            assetIDs.append(asset.localIdentifier)
        }

        // Keep only the newest tag for each assetID to avoid duplicated historical records
        // affecting folder counts.
        var latestTagByID: [String: PhotoTag] = [:]
        latestTagByID.reserveCapacity(allTags.count)
        for tag in allTags {
            if let existing = latestTagByID[tag.assetID] {
                if tag.createdAt > existing.createdAt {
                    latestTagByID[tag.assetID] = tag
                }
            } else {
                latestTagByID[tag.assetID] = tag
            }
        }

        var keepCount = 0
        var maybeCount = 0
        var deleteCount = 0
        var pendingCount = 0

        for assetID in assetIDs {
            let status = latestTagByID[assetID]?.status
            switch status {
            case "keep":
                keepCount += 1
            case "maybe":
                maybeCount += 1
            case "delete":
                deleteCount += 1
            default:
                // Keep in sync with PhotoGrid pending filter (nil/pending/unknown -> pending bucket).
                pendingCount += 1
            }
        }

        folderCounts["all"] = assetIDs.count
        folderCounts["keep"] = keepCount
        folderCounts["maybe"] = maybeCount
        folderCounts["delete"] = deleteCount
        folderCounts["pending"] = pendingCount
    }
}

struct FolderRow: View {
    let title: String
    let titleFont: Font
    let icon: String
    let color: Color
    let count: Int

    init(title: String, titleFont: Font = .body, icon: String, color: Color, count: Int) {
        self.title = title
        self.titleFont = titleFont
        self.icon = icon
        self.color = color
        self.count = count
    }

    var body: some View {
        HStack {
            Image(systemName: icon)
                .foregroundColor(color)
                .frame(width: 30)

            Text(title)
                .font(titleFont)

            Spacer()

            Text("\(count)")
                .foregroundColor(.secondary)

            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundColor(.gray)
        }
        .contentShape(Rectangle())
    }
}
