import SwiftUI
import SwiftData
import Photos
import PhotosUI
import UIKit

struct LibraryView: View {
    @EnvironmentObject var storeManager: StoreManager
    @EnvironmentObject var paywallGate: PaywallGate

    @Query private var allTags: [PhotoTag]
    @State private var folderCounts: [String: Int] = [:]
    /// Guards against a slower earlier count finishing after a newer one and
    /// overwriting it with stale numbers on rapid tab switches.
    @State private var countsToken = 0
    /// True when Photos access is `.limited` — counts only cover the selection,
    /// so surface a hint plus a "manage selection" entry point.
    @State private var isLimitedAccess = false

    @AppStorage("hint_library_category_dismissed") private var categoryHintDismissed = false
    @AppStorage("hint_library_todelete_dismissed") private var toDeleteHintDismissed = false

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
                if isLimitedAccess {
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            Label {
                                Text("library.limited.notice".localized)
                                    .font(.footnote)
                                    .foregroundColor(.secondary)
                            } icon: {
                                Image(systemName: "exclamationmark.triangle")
                                    .foregroundColor(.orange)
                            }
                            Button("library.limited.manage".localized) {
                                presentLimitedLibraryPicker()
                            }
                            .font(.footnote.weight(.semibold))
                        }
                        .padding(.vertical, 2)
                    }
                }

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

                Section {
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

                    if !toDeleteHintDismissed {
                        HStack(alignment: .top, spacing: 6) {
                            Text("library.hint.toDelete".localized)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            Spacer(minLength: 4)
                            Button {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    toDeleteHintDismissed = true
                                }
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundColor(.secondary)
                                    .padding(4)
                                    .background(Color(.tertiarySystemBackground))
                                    .clipShape(Circle())
                            }
                            .buttonStyle(.plain)
                        }
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 4, leading: 20, bottom: 4, trailing: 16))
                    }
                } header: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("library.category".localized)
                        if !categoryHintDismissed {
                            Text("library.hint.category".localized)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .textCase(nil)
                            Spacer(minLength: 4)
                            Button {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    categoryHintDismissed = true
                                }
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundColor(.secondary)
                                    .padding(4)
                                    .background(Color(.tertiarySystemBackground))
                                    .clipShape(Circle())
                            }
                            .buttonStyle(.plain)
                            .textCase(nil)
                        }
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
            .onAppear {
                refreshAuthorizationState()
                calculateCounts()
            }
            // PhotoLibraryObserver (PhotosCleanApp) already debounces
            // photoLibraryDidChange into this app-wide notification — reuse it so
            // counts stay fresh after deletes / iCloud sync / limited-selection edits.
            .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("ReloadPhotos"))) { _ in
                refreshAuthorizationState()
                calculateCounts()
            }

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

    private func refreshAuthorizationState() {
        isLimitedAccess = PHPhotoLibrary.authorizationStatus(for: .readWrite) == .limited
    }

    private func presentLimitedLibraryPicker() {
        guard let root = UIApplication.shared.connectedScenes
            .compactMap({ ($0 as? UIWindowScene)?.windows.first?.rootViewController })
            .first else { return }
        PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: root)
    }

    func calculateCounts() {
        countsToken += 1
        let token = countsToken
        // Snapshot the newest status per asset on the main thread — SwiftData
        // models (allTags) aren't safe to touch off the main context. This is a
        // cheap in-memory pass; the expensive Photos work happens below.
        var latestStatusByID: [String: String] = [:]
        var latestDateByID: [String: Date] = [:]
        latestStatusByID.reserveCapacity(allTags.count)
        for tag in allTags {
            if let d = latestDateByID[tag.assetID], tag.createdAt <= d { continue }
            latestDateByID[tag.assetID] = tag.createdAt
            latestStatusByID[tag.assetID] = tag.status
        }

        // Fetching + enumerating the whole photo library is the ~1s hitch when
        // switching to this tab. Run it off the main thread and count in a single
        // pass (no intermediate ID array), then publish back on the main thread.
        DispatchQueue.global(qos: .userInitiated).async {
            // 不限定媒体类型：PhotoGridView 抓的是全部资产（含视频），
            // 这里必须一致，否则行计数和网格内"全部删除 (N)"对不上。
            let fetched = PHAsset.fetchAssets(with: PHFetchOptions())
            var all = 0, keep = 0, maybe = 0, delete = 0, pending = 0
            fetched.enumerateObjects { asset, _, _ in
                all += 1
                switch latestStatusByID[asset.localIdentifier] {
                case "keep":   keep += 1
                case "maybe":  maybe += 1
                case "delete": delete += 1
                default:       pending += 1   // nil/pending/unknown -> pending bucket
                }
            }
            DispatchQueue.main.async {
                guard token == self.countsToken else { return }
                self.folderCounts = [
                    "all": all, "keep": keep, "maybe": maybe,
                    "delete": delete, "pending": pending
                ]
            }
        }
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
        }
        .contentShape(Rectangle())
    }
}
