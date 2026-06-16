import SwiftUI
import Photos
import UIKit

// MARK: - AI Clean Categories

enum AICleanCategory: String, CaseIterable, Identifiable {
    case blurry
    case screenshots
    case possibleDuplicates

    var id: String { rawValue }

    var title: String {
        switch self {
        case .blurry: return "ai.category.blurry".localized
        case .screenshots: return "ai.category.screenshots".localized
        case .possibleDuplicates: return "ai.category.duplicates".localized
        }
    }

    var icon: String {
        switch self {
        case .blurry: return "drop.triangle"
        case .screenshots: return "rectangle.on.rectangle"
        case .possibleDuplicates: return "square.stack.3d.up"
        }
    }

    var description: String {
        switch self {
        case .blurry:
            return "ai.category.blurry.desc".localized
        case .screenshots:
            return "ai.category.screenshots.desc".localized
        case .possibleDuplicates:
            return "ai.category.duplicates.desc".localized
        }
    }
}

// MARK: - Picker Sheet

struct AICleanPickerSheet: View {
    var body: some View {
        List {
            Section {
                ForEach(AICleanCategory.allCases) { cat in
                    NavigationLink {
                        AICleanResultsView(category: cat)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: cat.icon)
                                .frame(width: 24)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(cat.title)
                                Text(cat.description)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            } header: {
                Text("ai.picker.header".localized)
            } footer: {
                Text("ai.picker.footer".localized)
            }
        }
    }
}

// MARK: - Results View

struct AICleanResultsView: View {
    let category: AICleanCategory

    @State private var assets: [PHAsset] = []
    @State private var isLoading = true
    @State private var progressText: String? = nil
    @State private var selected: SelectedPhoto? = nil
    @State private var navigationSnapshot: [PHAsset] = []
    /// Loads only once per navigation push — re-appearing (e.g. popping back from
    /// LibraryCleanView) must not re-run the whole scan.
    @State private var hasLoaded = false
    /// The in-flight scan, kept so onDisappear can cancel it.
    @State private var loadTask: Task<Void, Never>? = nil

    private let blurCIContext = CIContext(options: nil)
    private let blurRenderColorSpace = CGColorSpaceCreateDeviceRGB()

    var body: some View {
        Group {
            if isLoading {
                VStack(spacing: 12) {
                    ProgressView()
                    if let progressText {
                        Text(progressText)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()

            } else if assets.isEmpty {
                ContentUnavailableView(
                    "ai.empty.title".localized,
                    systemImage: "sparkles",
                    description: Text("ai.empty.description".localized)
                )
                .padding(.top, 24)

            } else {
                GeometryReader { geo in
                    let metrics = Layout.gridMetrics(forWidth: geo.size.width)
                    ScrollView {
                        LazyVGrid(columns: metrics.columns, spacing: 2) {
                            ForEach(assets, id: \.localIdentifier) { asset in
                                let id = asset.localIdentifier
                                AssetThumbnailView(asset: asset, noteText: nil, isSearchMatched: false)
                                    .frame(width: metrics.side, height: metrics.side)
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        navigationSnapshot = assets
                                        selected = SelectedPhoto(id: id)
                                    }
                            }
                        }
                        .padding(.horizontal, 2)
                        .frame(maxWidth: .infinity, alignment: .center)
                    }
                    // Optional manual re-scan; the automatic scan only runs once
                    // per push (see onAppear guard below).
                    .refreshable { await refresh() }
                }
            }
        }
        .navigationTitle(category.title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            // First appearance kicks off the scan. If a previous scan was
            // cancelled mid-flight (user left while loading), restart it;
            // otherwise returning from a detail push reuses the results.
            if loadTask == nil && (!hasLoaded || isLoading) {
                hasLoaded = true
                startLoad()
            }
        }
        .onDisappear {
            loadTask?.cancel()
            loadTask = nil
        }
        .navigationDestination(item: $selected) { sel in
            let list = navigationSnapshot
            let idx = list.firstIndex(where: { $0.localIdentifier == sel.id }) ?? 0
            LibraryCleanView(assets: list, initialIndex: idx)
        }
    }

    private func startLoad() {
        loadTask?.cancel()
        isLoading = true
        progressText = nil

        loadTask = Task { @MainActor in
            defer { loadTask = nil }

            let result: [PHAsset]
            switch category {
            case .screenshots:
                result = await fetchScreenshots()
            case .possibleDuplicates:
                progressText = "ai.progress.scan800".localized
                result = await findPossibleDuplicates(limit: 800)
            case .blurry:
                progressText = "ai.progress.scan500".localized
                result = await findBlurryPhotos(limit: 500)
            }

            guard !Task.isCancelled else { return }
            assets = result
            isLoading = false
            progressText = nil
        }
    }

    /// Manual pull-to-refresh re-scan.
    @MainActor
    private func refresh() async {
        startLoad()
        await loadTask?.value
    }

    // MARK: - Screenshot (robust)
    // PHAsset fetch/enumerate over the whole library is slow — keep it off the
    // main thread (PHAsset fetching is thread-safe) and publish on return.
    private func fetchScreenshots() async -> [PHAsset] {
        await withCheckedContinuation { (cont: CheckedContinuation<[PHAsset], Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let options = PHFetchOptions()
                options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
                // mediaSubtype bitmask contains screenshot
                let mask = PHAssetMediaSubtype.photoScreenshot.rawValue
                options.predicate = NSPredicate(format: "(mediaSubtype & %d) != 0", mask)
                let fetch = PHAsset.fetchAssets(with: .image, options: options)
                var arr: [PHAsset] = []
                arr.reserveCapacity(fetch.count)
                fetch.enumerateObjects { asset, _, _ in
                    arr.append(asset)
                }
                cont.resume(returning: arr)
            }
        }
    }

    // MARK: - Possible duplicates (cheap heuristic)
    // Strategy: recent N images -> key by (creationDate rounded to minute, pixelWidth, pixelHeight)
    // If a key has 2+ photos, mark them as possible duplicates.
    private func findPossibleDuplicates(limit: Int) async -> [PHAsset] {
        let fetched = await fetchRecentImages(limit: limit)
        let calendar = Calendar.current

        // Build buckets
        var buckets: [String: [PHAsset]] = [:]
        buckets.reserveCapacity(fetched.count)

        for asset in fetched {
            let date = asset.creationDate ?? Date.distantPast
            let comps = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
            let minuteKey = String(format: "%04d%02d%02d-%02d%02d",
                                   comps.year ?? 0,
                                   comps.month ?? 0,
                                   comps.day ?? 0,
                                   comps.hour ?? 0,
                                   comps.minute ?? 0)
            let dimKey = "\(asset.pixelWidth)x\(asset.pixelHeight)"
            let key = "\(minuteKey)|\(dimKey)"
            buckets[key, default: []].append(asset)
        }

        // Flatten only duplicate buckets
        var results: [PHAsset] = []
        for (_, group) in buckets where group.count >= 2 {
            results.append(contentsOf: group)
        }
        // Keep newest first
        results.sort { ($0.creationDate ?? .distantPast) > ($1.creationDate ?? .distantPast) }
        return results
    }

    // MARK: - Blurry (lightweight, heuristic)
    // Strategy: request small thumbnail -> run CIEdges -> compute mean intensity.
    // Lower mean => fewer edges => likely blur.
    private func findBlurryPhotos(limit: Int) async -> [PHAsset] {
        let fetched = await fetchRecentImages(limit: limit)
        var results: [PHAsset] = []

        let manager = PHImageManager.default()
        let options = PHImageRequestOptions()
        options.isSynchronous = false
        // 用 highQualityFormat 确保只回调一次，避免 continuation 被 resume 两次 crash
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = false

        let targetSize = CGSize(width: 240, height: 240)
        let context = blurCIContext
        let colorSpace = blurRenderColorSpace

        for (idx, asset) in fetched.enumerated() {
            // Bail out early when the scan task is cancelled (view dismissed).
            if Task.isCancelled { break }

            await MainActor.run {
                // Update progress every 40 items
                if idx % 40 == 0 {
                    self.progressText = "ai.progress.analyzing".localized(with: idx, fetched.count)
                }
            }

            // The PHImageManager result handler runs on the main thread — only
            // grab the image there; the Core Image work happens off-main below.
            let image: UIImage? = await withCheckedContinuation { (cont: CheckedContinuation<UIImage?, Never>) in
                manager.requestImage(
                    for: asset,
                    targetSize: targetSize,
                    contentMode: .aspectFill,
                    options: options
                ) { image, _ in
                    cont.resume(returning: image)
                }
            }

            guard let image else { continue }

            // CIContext is thread-safe; run the edge analysis off the main thread.
            let maybeBlurry = await Task.detached(priority: .utility) {
                Self.isLikelyBlurry(image, context: context, colorSpace: colorSpace)
            }.value

            if maybeBlurry {
                results.append(asset)
            }
        }

        results.sort { ($0.creationDate ?? .distantPast) > ($1.creationDate ?? .distantPast) }
        return results
    }

    // nonisolated: View statics inherit @MainActor, which would silently hop this
    // CPU-bound Core Image work back onto the main thread from the detached task.
    nonisolated private static func isLikelyBlurry(_ uiImage: UIImage, context: CIContext, colorSpace: CGColorSpace) -> Bool {
        guard let cg = uiImage.cgImage else { return false }
        let ci = CIImage(cgImage: cg)
        let edges = ci.applyingFilter("CIEdges", parameters: [kCIInputIntensityKey: 1.0])
        let extent = edges.extent.integral
        guard !extent.isEmpty else { return false }
        guard let avg = CIFilter(
            name: "CIAreaAverage",
            parameters: [
                kCIInputImageKey: edges,
                kCIInputExtentKey: CIVector(cgRect: extent)
            ]
        )?.outputImage else { return false }

        var pixel = [UInt8](repeating: 0, count: 4)
        context.render(
            avg,
            toBitmap: &pixel,
            rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: colorSpace
        )
        let mean = (Double(pixel[0]) + Double(pixel[1]) + Double(pixel[2])) / (3.0 * 255.0)

        // Threshold: lower edges mean -> more likely blurry
        // Tuned to be conservative: only mark obvious blur.
        return mean < 0.035
    }

    // MARK: - Helpers
    // Off-main for the same reason as fetchScreenshots: enumerating hundreds of
    // assets on the main thread causes a visible hitch.
    private func fetchRecentImages(limit: Int) async -> [PHAsset] {
        await withCheckedContinuation { (cont: CheckedContinuation<[PHAsset], Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let options = PHFetchOptions()
                options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
                options.fetchLimit = limit
                let fetch = PHAsset.fetchAssets(with: .image, options: options)
                var arr: [PHAsset] = []
                arr.reserveCapacity(fetch.count)
                fetch.enumerateObjects { asset, _, _ in
                    arr.append(asset)
                }
                cont.resume(returning: arr)
            }
        }
    }
}
