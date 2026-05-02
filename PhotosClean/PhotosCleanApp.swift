import SwiftUI
import SwiftData
import Photos
import WidgetKit

@main
struct PhotosCleanApp: App {

    @Environment(\.scenePhase) private var scenePhase

    // 🌟 新增：创建 StoreManager 实例
    // 使用 @StateObject 确保 StoreManager 在 App 生命周期内唯一且常驻内存
    @StateObject private var storeManager = StoreManager()
    @StateObject private var paywallGate = PaywallGate()
    @StateObject private var storageStats = StorageStats()

    // 初始化共享 ModelContainer（三级 fallback，确保 app 至少能打开）
    var sharedModelContainer: ModelContainer = {
        let schema = Schema([PhotoTag.self])

        // 1) 优先：CloudKit + App Group
        let cloudConfig = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: false,
            groupContainer: .identifier("group.com.claire.TastyTidy"),
            cloudKitDatabase: .private("iCloud.com.claire.tastytidy")
        )
        do {
            return try ModelContainer(for: schema, configurations: [cloudConfig])
        } catch {
            print("⚠️ CloudKit ModelContainer failed, falling back to local:", error)
        }

        // 2) Fallback：纯本地存储
        let localConfig = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false, cloudKitDatabase: .none)
        do {
            return try ModelContainer(for: schema, configurations: [localConfig])
        } catch {
            print("⚠️ Local ModelContainer failed, falling back to in-memory:", error)
        }

        // 3) 最后兜底：内存存储（app 能打开，但数据不持久）
        let memConfig = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        do {
            return try ModelContainer(for: schema, configurations: [memConfig])
        } catch {
            fatalError("All ModelContainer strategies failed: \(error)")
        }
    }()

    init() {
        // 启动相册监听器
        _ = PhotoLibraryObserver.shared
        // 首次启动主动请求 .readWrite 权限；否则系统默认只授予 .addOnly，
        // 之后 PHAssetChangeRequest.deleteAssets 会静默失败。
        PhotoLibraryAuth.requestWriteAccess { _ in }
    }

    var body: some Scene {
        WindowGroup {
            MainTabView()
                .environmentObject(storeManager)
                .environmentObject(paywallGate)
                .environmentObject(storageStats)
        }
        .modelContainer(sharedModelContainer)
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .background {
                // Save pending SwiftData changes before entering background
                // to release SQLite file locks and prevent 0xdead10cc termination.
                try? sharedModelContainer.mainContext.save()
            }
        }
    }
}

// 相册监听器部分保持不变...
class PhotoLibraryObserver: NSObject, PHPhotoLibraryChangeObserver {
    static let shared = PhotoLibraryObserver()

    override init() {
        super.init()
        PHPhotoLibrary.shared().register(self)
    }

    func photoLibraryDidChange(_ changeInstance: PHChange) {
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: NSNotification.Name("ReloadPhotos"),
                object: nil
            )
            WidgetCenter.shared.reloadAllTimelines()
        }
    }
}
