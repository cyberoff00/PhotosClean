import SwiftUI

import Photos

import UIKit

import SwiftData

import WidgetKit

import Combine

struct SelectedPhoto: Identifiable, Hashable {
    let id: String // asset.localIdentifier
}

// MARK: - Multi-select frame tracking
private struct CellFramePreferenceKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String : CGRect], nextValue: () -> [String : CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

/// Reference-type holder for cell frames. Writing frames into an @State dict
/// would invalidate the body on every scroll frame while in selection mode;
/// the drag-select hit testing only ever reads imperatively, so a plain class
/// avoids that re-render churn entirely.
private final class CellFrameStore {
    var frames: [String: CGRect] = [:]
}

struct PhotoGridView: View {
    let title: String
    let filterStatus: String?

    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject var storageStats: StorageStats
    @EnvironmentObject var ratingPrompt: RatingPrompt
    @Query private var allTags: [PhotoTag]

    @State private var assets: [PHAsset] = []
    @State private var allAssetsSnapshot: [PHAsset] = []
    @State private var filteredAssetsCache: [PHAsset] = []
    @State private var filteredAssetIDs: [String] = []
    @State private var noteByAssetID: [String: String] = [:]
    @State private var statusByAssetID: [String: String] = [:]
    @State private var isLoading = true
    // 首次加载后 pop 回来不再全库重抓；保留 30 秒节流以防外部相册变更长期不刷新。
    @State private var hasLoadedOnce = false
    @State private var lastLoadAt: Date? = nil
    private static let reloadThrottleInterval: TimeInterval = 30
    // 权限被拒/受限时显示“去设置”空状态
    @State private var photoAccessDenied = false
    @State private var searchText = ""
    // searchText 经过 ~250ms debounce 后写入这里；过滤热路径只跟它走。
    @State private var debouncedSearchText = ""
    @State private var showingPhotoAuthAlert = false
    /// True while a library delete is in flight. Blocks repeated taps from
    /// enqueuing multiple PHPhotoLibrary delete requests whose system
    /// confirmation dialogs would otherwise stack up and flush on next launch.
    @State private var isDeletingPhotos = false
    /// True once performChanges actually fires (system delete dialog incoming).
    /// Lets the watchdog tell "stuck waiting to present" from "user deciding in
    /// the system dialog" and only unstick the former. See startDeleteWatchdog().
    @State private var deleteChangesStarted = false
    @State private var cachedYearsMonths: [String] = []
    // 预计算 assetID → (year, month)。loadPhotos 时一次构建，避免在 filter 热路径里
    // 反复调 Calendar.dateComponents（ICU 很慢）。
    @State private var yearMonthByID: [String: (Int, Int)] = [:]

    // 日期过滤
    @State private var selectedYear: Int?
    @State private var selectedMonth: Int?
    @State private var showDatePicker = false

    // ✅ AI 识别（轻量：像日期筛选一样作为过滤器）
    @State private var selectedAICategory: AICleanCategory? = nil
    @State private var aiIsScanning: Bool = false
    @State private var aiProgressText: String? = nil
    @State private var aiBlurryIDs: Set<String> = []
    @State private var aiDuplicatesIDs: Set<String> = []
    @State private var aiScreenshotsIDs: Set<String> = []

    // ✅ 分批扫描：默认只扫最近 500；手动“追加 +500”继续往更早的照片扫
    @State private var aiBlurryOffset: Int = 0
    @State private var aiDuplicatesOffset: Int = 0
    @State private var aiDupBuckets: [String: [String]] = [:]
    private let aiBatchSize: Int = 500

    // ✅ 关键：导航快照，避免 filteredAssets 变化导致进错图
    @State private var selected: SelectedPhoto?
    @State private var navigationSnapshot: [PHAsset] = []

    // ✅ 多选（像相册一样顺次一滑多选）
    @State private var isSelectionMode = false
    @State private var selectedIDs: Set<String> = []

    // ✅ Batch add note (append with semicolons; keep existing notes)
    @State private var showingBatchNoteSheet = false
    @State private var batchNoteText = ""
    @State private var cellFrameStore = CellFrameStore()
    @State private var isDragSelecting = false
    @State private var dragAdds = true
    @State private var lastHitID: String?
    @State private var dragStartIndex: Int?
    @State private var dragBaseSelection: Set<String> = []
    // ✅ 相册手感：在多选模式下无需“按压/长按再拖”也能拖选；但仍要允许正常上下滚动
    private enum DragMode { case undecided, selecting, scrolling }
    @State private var dragMode: DragMode = .undecided
    @State private var dragStartPoint: CGPoint? = nil
    // ✅ 修复：长按选中的第一张，继续拖动时不要把自己当作“取消模式”
    @State private var pendingDragAddsOverride: Bool? = nil

    // ✅ 自动滚动（更像系统相册：滑动选中时“往下滑=继续选下面的并自动翻页”）
    @State private var scrollViewHeight: CGFloat = 0
    @State private var autoScrollDirection: Int = 0 // -1 上，1 下，0 停止
    private let autoScrollEdge: CGFloat = 70
    private let autoScrollStep: Int = 2
    private let autoScrollTimer = Timer.publish(every: 0.05, on: .main, in: .common).autoconnect()
    private let blurCIContext = CIContext(options: nil)
    private let blurRenderColorSpace = CGColorSpaceCreateDeviceRGB()

    // ✅ 待删除资产/体积缓存：只在 allTags / allAssetsSnapshot 变化时重算一次，
    // body 渲染只读缓存（之前每次 body 都全库 O(N) 过滤 + 体积统计）。
    @State private var pendingDeleteAssetsCache: [PHAsset] = []
    @State private var pendingDeleteBytes: Int64 = 0
    @State private var pendingDeleteAllPrecise = true

    // ✅ 与 startPrefetching 配对的 stop：记录上一批已 start 的 assets
    @State private var prefetchedAssets: [PHAsset] = []

    private var filteredAssets: [PHAsset] { filteredAssetsCache }

    private var isLibraryView: Bool {
        let libraryTitle = "library.title".localized
        return title == libraryTitle
    }

    // 待删除页不提供搜索/筛选：列表与"全部删除 (N)"始终一一对应，
    // 避免"筛选后只见一部分、删除却是全部"的误解。
    // filterStatus 在视图生命周期内不变，分支不会引起结构身份切换。
    @ViewBuilder
    private var searchableContentRoot: some View {
        if filterStatus == "delete" {
            contentRoot
        } else {
            contentRoot
                .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always))
        }
    }

    var body: some View {
        searchableContentRoot
            .trackFrameHitches("grid")
            .navigationTitle(title)
            .toolbar { trailingToolbar }
            .alert("grid.photoAuth.title".localized, isPresented: $showingPhotoAuthAlert) {
                Button("grid.cancel".localized, role: .cancel) {}
                Button("grid.photoAuth.openSettings".localized) { PhotoLibraryAuth.openSettings() }
            } message: {
                Text("grid.photoAuth.message".localized)
            }
            .sheet(isPresented: $showingBatchNoteSheet) { batchNoteSheet }
            .onAppear {
                rebuildTagMaps()
                loadPhotos()
            }
            .onDisappear {
                stopPrefetchingThumbnails()
            }
            .onChange(of: allTags) { _, _ in
                measureMain("grid.onChange(allTags)") {
                    rebuildTagMaps()
                    // applyStatusFilterFromSnapshot updates `assets` AND calls recomputeFilteredAssets
                    // in one shot, so we do NOT need a separate onChange(of: assets) listener.
                    applyStatusFilterFromSnapshot()
                    recomputePendingDeleteCache()
                    storageStats.precacheSizes(for: pendingDeleteAssetsCache)
                }
            }
            // 精确体积是后台异步算出来的；节流刷新一次缓存的字节数即可。
            .onReceive(storageStats.$preciseSizes.dropFirst().throttle(for: .milliseconds(300), scheduler: RunLoop.main, latest: true)) { _ in
                guard filterStatus == "delete", !pendingDeleteAssetsCache.isEmpty else { return }
                pendingDeleteBytes = storageStats.totalBestSize(for: pendingDeleteAssetsCache)
                pendingDeleteAllPrecise = storageStats.allPrecise(for: pendingDeleteAssetsCache)
            }
            // Removed: onChange(of: assets) → was causing a second cascade since
            // applyStatusFilterFromSnapshot already mutates assets AND recomputes.
            // searchText debounce: 250ms 没新输入再触发一次过滤，避免每个 keystroke 全表过滤。
            .task(id: searchText) {
                do {
                    try await Task.sleep(for: .milliseconds(250))
                    debouncedSearchText = searchText
                } catch { /* cancelled by next keystroke */ }
            }
            .onChange(of: debouncedSearchText) { _, _ in recomputeFilteredAssets() }
            .onChange(of: selectedYear) { _, _ in recomputeFilteredAssets() }
            .onChange(of: selectedMonth) { _, _ in recomputeFilteredAssets() }
            .onChange(of: selectedAICategory) { _, _ in recomputeFilteredAssets() }
            .onChange(of: aiBlurryIDs) { _, _ in recomputeFilteredAssets() }
            .onChange(of: aiDuplicatesIDs) { _, _ in recomputeFilteredAssets() }
            .onChange(of: aiScreenshotsIDs) { _, _ in recomputeFilteredAssets() }
            .navigationDestination(item: $selected) { sel in
                let list = navigationSnapshot.isEmpty ? filteredAssets : navigationSnapshot
                let idx = list.firstIndex(where: { $0.localIdentifier == sel.id }) ?? 0
                let _ = cleanLog("[Nav] building detail view isLibrary=\(isLibraryView) listCount=\(list.count) idx=\(idx)")
                if isLibraryView {
                    LibraryCleanView(assets: list, initialIndex: idx)
                } else {
                    RetroCleanView(assets: list, initialIndex: idx)
                }
            }
    }

    private var contentRoot: some View {
        GeometryReader { outerGeo in
            ScrollViewReader { proxy in
                ZStack {
                    gridBodyWithOptionalSelectionGesture(outerGeo: outerGeo, proxy: proxy)
                    if aiIsScanning {
                        aiProgressOverlay
                    }
                }
            }
        }
    }

    private func gridScrollBody(containerWidth: CGFloat) -> some View {
        let metrics = Layout.gridMetrics(forWidth: containerWidth)
        return ScrollView {
            if isLoading {
                ProgressView().padding(.top, 50)
            } else if photoAccessDenied {
                ContentUnavailableView {
                    Label("grid.photoAccess.deniedTitle".localized, systemImage: "lock.shield")
                } description: {
                    Text("grid.photoAccess.deniedMessage".localized)
                } actions: {
                    Button("grid.photoAuth.openSettings".localized) {
                        PhotoLibraryAuth.openSettings()
                    }
                }
                .padding(.top, 50)
            } else if filteredAssets.isEmpty {
                ContentUnavailableView(
                    "grid.noPhotos".localized,
                    systemImage: "photo.on.rectangle"
                )
                .padding(.top, 50)
            } else {
                LazyVGrid(columns: metrics.columns, spacing: 2) {
                    ForEach(filteredAssets, id: \.localIdentifier) { asset in
                        gridCell(for: asset, side: metrics.side)
                    }
                }
                .padding(.horizontal, 2)
                .frame(maxWidth: .infinity, alignment: .center)
            }
        }
    }

    @ViewBuilder
    private func gridBodyWithOptionalSelectionGesture(
        outerGeo: GeometryProxy,
        proxy: ScrollViewProxy
    ) -> some View {
        if isSelectionMode {
            gridScrollBody(containerWidth: outerGeo.size.width)
                .scrollDisabled(isDragSelecting)
                .coordinateSpace(name: "gridSpace")
                // 写入引用类型 holder，不触发 body 重算（滚动时 frame 每帧都在变）。
                .onPreferenceChange(CellFramePreferenceKey.self) { [cellFrameStore] frames in
                    cellFrameStore.frames = frames
                }
                .simultaneousGesture(dragSelectGesture(outerGeo: outerGeo))
                .onReceive(autoScrollTimer) { _ in
                    guard isDragSelecting, autoScrollDirection != 0 else { return }
                    autoScrollTick(with: proxy)
                }
        } else {
            // ✅ Non-selection: plain ScrollView, NO scrollDisabled, NO gestures.
            // This fixes older iOS where SwiftUI gesture arbitration blocks scrolling.
            gridScrollBody(containerWidth: outerGeo.size.width)
        }
    }

    private func dragSelectGesture(outerGeo: GeometryProxy) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard isSelectionMode else { return }
                scrollViewHeight = outerGeo.size.height
                if dragStartPoint == nil {
                    dragStartPoint = value.startLocation
                    dragMode = .undecided
                }

                let start = dragStartPoint ?? value.startLocation
                let dx = value.location.x - start.x
                let dy = value.location.y - start.y
                let adx = abs(dx)
                let ady = abs(dy)
                let threshold: CGFloat = 8

                if dragMode == .undecided {
                    if hitTestID(at: value.startLocation) == nil {
                        dragMode = .scrolling
                    } else if adx > threshold && adx > ady * 1.2 {
                        dragMode = .selecting
                    } else if ady > threshold && ady > adx * 1.2 {
                        dragMode = .scrolling
                    } else {
                        return
                    }
                }

                if dragMode == .selecting {
                    handleDragSelect(at: value.location)
                    updateAutoScrollDirection(for: value.location)
                } else {
                    autoScrollDirection = 0
                }
            }
            .onEnded { _ in
                isDragSelecting = false
                lastHitID = nil
                dragStartIndex = nil
                dragBaseSelection = []
                pendingDragAddsOverride = nil
                dragMode = .undecided
                dragStartPoint = nil
                autoScrollDirection = 0
            }
    }

    private var aiProgressOverlay: some View {
        VStack {
            HStack(spacing: 10) {
                ProgressView()
                Text(aiProgressText ?? "ai.progress.identifying".localized)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial)
            .clipShape(Capsule())
            .padding(.top, 8)
            Spacer()
        }
        .transition(.opacity)
    }

    @ToolbarContentBuilder
    private var trailingToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigationBarTrailing) {
            if isSelectionMode {
                Button("grid.selection.cancel".localized) {
                    exitSelectionMode()
                }
                Menu {
                    Button {
                        showingBatchNoteSheet = true
                    } label: {
                        Label("grid.batchNote".localized, systemImage: "text.badge.plus")
                    }
                    .disabled(selectedIDs.isEmpty)
                    Button(role: .destructive) {
                        // iOS's own delete confirmation is the gate here; no
                        // redundant app-level alert.
                        deleteSelectedPhotos()
                    } label: {
                        Label("grid.deleteSelected".localized + " (\(selectedIDs.count))", systemImage: "trash.fill")
                    }
                    .disabled(selectedIDs.isEmpty)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            } else {
                if filterStatus != "delete" {
                    aiFilterMenu
                    dateFilterMenu
                }
                if filterStatus == "delete" {
                    deleteMenuButton
                }
            }
        }
    }

    private var aiFilterMenu: some View {
        Menu {
            Button {
                selectedAICategory = nil
            } label: {
                HStack {
                    Text("grid.filter.all".localized)
                    if selectedAICategory == nil { Image(systemName: "checkmark") }
                }
            }
            Divider()
            ForEach(AICleanCategory.allCases) { cat in
                Button {
                    selectAIFilter(cat)
                } label: {
                    HStack {
                        Text(cat.title)
                        if selectedAICategory == cat { Image(systemName: "checkmark") }
                    }
                }
            }
            Divider()
            Button {
                appendAIScan()
            } label: {
                Label("grid.ai.append500".localized, systemImage: "arrow.clockwise")
            }
            .disabled(aiIsScanning)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "line.3.horizontal.decrease.circle")
                if let selectedAICategory {
                    Text(selectedAICategory.title).font(.caption)
                } else {
                    Text("grid.filter.ai".localized).font(.caption)
                }
            }
        }
    }

    private var dateFilterMenu: some View {
        Menu {
            Button(action: { selectedYear = nil; selectedMonth = nil }) {
                HStack {
                    Text("grid.allDates".localized)
                    if selectedYear == nil && selectedMonth == nil {
                        Image(systemName: "checkmark")
                    }
                }
            }
            Divider()
            ForEach(cachedYearsMonths, id: \.self) { dateStr in
                Button(action: {
                    let parts = dateStr.split(separator: "-").map { Int($0) ?? 0 }
                    guard let first = parts.first else { return }
                    selectedYear = first
                    selectedMonth = parts.count > 1 ? parts[1] : nil
                }) {
                    HStack {
                        Text(dateStr)
                        if "\(selectedYear ?? 0)-\(String(format: "%02d", selectedMonth ?? 0))" == dateStr ||
                            (selectedMonth == nil && dateStr == "\(selectedYear ?? 0)") {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "calendar")
                if selectedYear != nil || selectedMonth != nil {
                    Text("\(selectedYear ?? 0)-\(String(format: "%02d", selectedMonth ?? 1))")
                        .font(.caption)
                }
            }
        }
    }

    private var deleteMenuButton: some View {
        // 只读缓存：pendingDeleteAssetsCache 在 allTags / allAssetsSnapshot 变化时
        // 重算一次，体积随 preciseSizes 节流刷新，避免每次 body 全库过滤+统计。
        let deleteCount = pendingDeleteAssetsCache.count
        let approxPrefix = pendingDeleteAllPrecise ? "" : "~"
        let sizeLabel = deleteCount > 0 ? " · \(approxPrefix)\(pendingDeleteBytes.byteCountShort)" : ""
        return Menu {
            Button(role: .destructive) {
                // No app-level confirm: iOS presents its own "Delete N Photos?"
                // confirmation (which we can't suppress), so a second one would
                // just be a redundant tap. ForegroundGate waits for this menu to
                // finish collapsing before the system dialog is presented.
                deleteMarkedPhotos()
            } label: {
                Label("grid.deleteAll".localized + " (\(deleteCount))" + sizeLabel, systemImage: "trash.fill")
            }
            .disabled(deleteCount == 0)
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .disabled(deleteCount == 0)
    }

    /// Recompute the pending-delete cache (intersection of tags and known assets).
    /// Called when `allTags` changes or after a fresh `loadPhotos` snapshot —
    /// never from `body`.
    private func recomputePendingDeleteCache() {
        // 用"每个资产最新一条标签"判定，而不是任意一条 delete 记录——
        // 否则用户已改回保留的照片会被算进（并被"全部删除"误删）。
        var latestDate: [String: Date] = [:]
        var latestStatus: [String: String] = [:]
        for tag in allTags {
            if let d = latestDate[tag.assetID], tag.createdAt <= d { continue }
            latestDate[tag.assetID] = tag.createdAt
            latestStatus[tag.assetID] = tag.status
        }
        let deleteIDs = Set(latestStatus.lazy.filter { $0.value == "delete" }.map { $0.key })
        let deleteAssets = deleteIDs.isEmpty
            ? []
            : allAssetsSnapshot.filter { deleteIDs.contains($0.localIdentifier) }
        pendingDeleteAssetsCache = deleteAssets
        pendingDeleteBytes = storageStats.totalBestSize(for: deleteAssets)
        pendingDeleteAllPrecise = storageStats.allPrecise(for: deleteAssets)
    }

    private var batchNoteSheet: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("grid.batchNote.placeholder".localized, text: $batchNoteText, axis: .vertical)
                        .lineLimit(3...8)
                } header: {
                    Text("grid.batchNote.title".localized)
                } footer: {
                    Text("grid.batchNote.footer".localized)
                }
            }
            .navigationTitle("grid.batchNote".localized)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("grid.cancel".localized) {
                        batchNoteText = ""
                        showingBatchNoteSheet = false
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("grid.batchNote.add".localized) {
                        applyBatchNote()
                        batchNoteText = ""
                        showingBatchNoteSheet = false
                    }
                    .disabled(batchNoteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    @ViewBuilder
    private func gridCell(for asset: PHAsset, side: CGFloat) -> some View {
        let id = asset.localIdentifier
        let note = noteByAssetID[id]
        // 高亮与过滤统一走 debouncedSearchText，避免输入瞬间两者不同步。
        let matchesSearch = !debouncedSearchText.isEmpty && (note?.localizedCaseInsensitiveContains(debouncedSearchText) ?? false)

        if isSelectionMode {
            // Selection mode: show border, checkmark, geometry tracking
            let isSelected = selectedIDs.contains(id)
            ZStack(alignment: .topTrailing) {
                AssetThumbnailView(asset: asset, noteText: note, isSearchMatched: matchesSearch)
                    .frame(width: side, height: side)
                    .overlay(
                        Rectangle()
                            .strokeBorder(isSelected ? Color.accentColor : Color.clear, lineWidth: 3)
                    )
                    .contentShape(Rectangle())
                    .background(selectionTrackingBackground(for: id))

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundColor(isSelected ? .accentColor : .white.opacity(0.85))
                    .padding(6)
            }
            .id(id)
            .onTapGesture { toggleSelection(id) }
        } else {
            // Normal mode: lightweight, no overlays, no geometry tracking
            AssetThumbnailView(asset: asset, noteText: note, isSearchMatched: matchesSearch)
                .frame(width: side, height: side)
                .contentShape(Rectangle())
                .id(id)
                .onTapGesture {
                    cleanLog("[Nav] grid cell tapped → snapshot=\(filteredAssets.count) opening detail id=\(id)")
                    navigationSnapshot = filteredAssets
                    selected = SelectedPhoto(id: id)
                }
                .onLongPressGesture(minimumDuration: 0.25) {
                    isSelectionMode = true
                    selectedIDs.insert(id)
                    pendingDragAddsOverride = true
                }
        }
    }

    @ViewBuilder
    private func selectionTrackingBackground(for id: String) -> some View {
        if isSelectionMode {
            GeometryReader { geo in
                Color.clear.preference(
                    key: CellFramePreferenceKey.self,
                    value: [id: geo.frame(in: .named("gridSpace"))]
                )
            }
        } else {
            Color.clear
        }
    }

    private func toggleSelection(_ id: String) {
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
        } else {
            selectedIDs.insert(id)
        }
        if selectedIDs.isEmpty {
            // 选空了就自动退出，体验更像相册
            exitSelectionMode()
        }
    }

    private func exitSelectionMode() {
        isSelectionMode = false
        selectedIDs.removeAll()
        isDragSelecting = false
        lastHitID = nil
        autoScrollDirection = 0
        pendingDragAddsOverride = nil
        dragMode = .undecided
        dragStartPoint = nil
        cellFrameStore.frames = [:]
    }

    private func applyBatchNote() {
        let addition = batchNoteText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !addition.isEmpty else { return }

        // Map existing tags for quick lookup
        var tagByID: [String: PhotoTag] = [:]
        tagByID.reserveCapacity(allTags.count)
        for tag in allTags where tagByID[tag.assetID] == nil {
            tagByID[tag.assetID] = tag
        }

        for id in selectedIDs {
            if let tag = tagByID[id] {
                let existing = (tag.note ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if existing.isEmpty {
                    tag.note = addition
                } else {
                    // Append with semicolon; keep original note
                    tag.note = existing + "; " + addition
                }
            } else {
                // No tag yet -> create one (default pending so it appears in “To Clean”)
                let newTag = PhotoTag(assetID: id, status: "pending", note: addition)
                modelContext.insert(newTag)
            }
        }

        try? modelContext.save()
    }

    private func handleDragSelect(at point: CGPoint) {
        guard let hit = hitTestID(at: point) else { return }
        // ✅ 只有在“已经在拖动中”且命中未变时才忽略；否则第一次拖动也要能正确初始化锚点
        if isDragSelecting && lastHitID == hit { return }
        lastHitID = hit

        let ordered = filteredAssetIDs
        guard let currentIndex = ordered.firstIndex(of: hit) else { return }

        beginDragIfNeeded(startIndex: currentIndex, startID: hit)
        updateRangeSelection(to: currentIndex, ordered: ordered)
    }

    private func hitTestID(at point: CGPoint) -> String? {
        // frames 是字典，不保证顺序；这里显式遍历即可（frame 不会重叠）
        for (id, rect) in cellFrameStore.frames {
            if rect.contains(point) { return id }
        }
        return nil
    }

    private func beginDragIfNeeded(startIndex: Int, startID: String) {
        if !isDragSelecting {
            isDragSelecting = true
            dragStartIndex = startIndex
            dragBaseSelection = selectedIDs
            // ✅ 长按进入多选后，第一段拖选默认应当是“批量添加”
            if let override = pendingDragAddsOverride {
                dragAdds = override
                pendingDragAddsOverride = nil
            } else {
                // 起点没选中：本次拖动为“批量添加”；起点已选中：本次拖动为“批量取消”
                dragAdds = !dragBaseSelection.contains(startID)
            }
        }
    }

    private func updateRangeSelection(to currentIndex: Int, ordered: [String]) {
        guard let startIndex = dragStartIndex, !ordered.isEmpty else { return }
        let low = max(0, min(startIndex, currentIndex))
        let high = min(ordered.count - 1, max(startIndex, currentIndex))
        let rangeIDs = Set(ordered[low...high])

        if dragAdds {
            selectedIDs = dragBaseSelection.union(rangeIDs)
        } else {
            selectedIDs = dragBaseSelection.subtracting(rangeIDs)
            if selectedIDs.isEmpty {
                exitSelectionMode()
            }
        }
    }

    private func updateAutoScrollDirection(for point: CGPoint) {
        // 系统相册的感觉：手指靠近顶部/底部就自动翻页（并继续范围选择）
        guard scrollViewHeight > 0 else {
            autoScrollDirection = 0
            return
        }
        if point.y < autoScrollEdge {
            autoScrollDirection = -1
        } else if point.y > scrollViewHeight - autoScrollEdge {
            autoScrollDirection = 1
        } else {
            autoScrollDirection = 0
        }
    }

    private func autoScrollTick(with proxy: ScrollViewProxy) {
        let ordered = filteredAssetIDs
        guard !ordered.isEmpty else { return }

        // 以“当前范围的末端”为基准推进（没有末端就用起点）
        let baseID = lastHitID ?? (dragStartIndex.flatMap { ordered.indices.contains($0) ? ordered[$0] : nil })
        guard let id = baseID, let idx = ordered.firstIndex(of: id) else { return }

        let next = min(max(0, idx + autoScrollDirection * autoScrollStep), ordered.count - 1)
        guard next != idx else { return }

        let targetID = ordered[next]
        lastHitID = targetID

        // ✅ 让界面“往下选就继续往下翻”（这里 scrollTo 会让 content 方向符合系统相册）
        withAnimation(.linear(duration: 0.05)) {
            proxy.scrollTo(targetID, anchor: .center)
        }

        let start = dragStartIndex ?? next
        if ordered.indices.contains(start) {
            beginDragIfNeeded(startIndex: start, startID: ordered[start])
        }
        updateRangeSelection(to: next, ordered: ordered)
    }


    private func prefetchInitialThumbnails() {
        // 先和上一批配对 stop，避免 caching manager 里残留的 start 请求只增不减。
        stopPrefetchingThumbnails()
        let batch = Array(filteredAssets.prefix(60))
        guard !batch.isEmpty else { return }
        let targetSize = gridThumbnailTargetSize()
        PHAssetThumbnailLoader.shared.startPrefetching(batch, targetSize: targetSize)
        prefetchedAssets = batch
    }

    private func stopPrefetchingThumbnails() {
        guard !prefetchedAssets.isEmpty else { return }
        PHAssetThumbnailLoader.shared.stopPrefetching(prefetchedAssets, targetSize: gridThumbnailTargetSize())
        prefetchedAssets = []
    }

    private func gridThumbnailTargetSize() -> CGSize {
        let scale = UIScreen.main.scale
        let gridSide = Layout.gridCellSide(spacing: 2)
        let pixelSide = max(gridSide * scale, 180)
        return CGSize(width: pixelSide, height: pixelSide)
    }

    // 通过预计算的 yearMonthByID 派生年月列表，避免重新调 Calendar。
    private func yearsMonthsForAssets(_ source: [PHAsset]) -> [String] {
        var dateStrings: Set<String> = []
        dateStrings.reserveCapacity(source.count / 8)
        for asset in source {
            if let ym = yearMonthByID[asset.localIdentifier] {
                dateStrings.insert("\(ym.0)-\(String(format: "%02d", ym.1))")
            }
        }
        return dateStrings.sorted().reversed()
    }

    /// 后台一次性构建 assetID → (year, month) 字典。Calendar 缓存一次复用。
    // An asset's (year, month) never changes, so cache it across reloads. On the
    // second+ load only brand-new asset IDs pay the ICU dateComponents cost.
    private static var yearMonthCache: [String: (Int, Int)] = [:]
    private static let yearMonthCacheLock = NSLock()

    private static func computeYearMonthMap(for assets: [PHAsset]) -> [String: (Int, Int)] {
        var map: [String: (Int, Int)] = [:]
        map.reserveCapacity(assets.count)
        let calendar = Calendar.current
        let comps: Set<Calendar.Component> = [.year, .month]

        yearMonthCacheLock.lock()
        let cache = yearMonthCache
        yearMonthCacheLock.unlock()

        var freshlyComputed: [String: (Int, Int)] = [:]
        for asset in assets {
            let id = asset.localIdentifier
            if let cached = cache[id] {
                map[id] = cached
                continue
            }
            guard let date = asset.creationDate else { continue }
            let c = calendar.dateComponents(comps, from: date)
            if let y = c.year, let m = c.month {
                map[id] = (y, m)
                freshlyComputed[id] = (y, m)
            }
        }

        if !freshlyComputed.isEmpty {
            yearMonthCacheLock.lock()
            for (id, ym) in freshlyComputed { yearMonthCache[id] = ym }
            yearMonthCacheLock.unlock()
        }
        return map
    }

    private func rebuildTagMaps() {
        var noteMap: [String: String] = [:]
        var statusMap: [String: String] = [:]
        var latestDate: [String: Date] = [:]
        noteMap.reserveCapacity(allTags.count)
        statusMap.reserveCapacity(allTags.count)

        // @Query 无排序保证；按 createdAt 取每个资产的最新标签，
        // 与 LibraryView.calculateCounts 的判定保持一致。
        for tag in allTags {
            if let d = latestDate[tag.assetID], tag.createdAt <= d { continue }
            latestDate[tag.assetID] = tag.createdAt
            noteMap[tag.assetID] = tag.note ?? ""
            statusMap[tag.assetID] = tag.status
        }
        noteByAssetID = noteMap
        statusByAssetID = statusMap
    }

    private func applyStatusFilterFromSnapshot() {
        assets = applyStatusFilter(to: allAssetsSnapshot, statusByAssetID: statusByAssetID)
        cachedYearsMonths = yearsMonthsForAssets(assets)
        recomputeFilteredAssets()
    }

    private func applyStatusFilter(to source: [PHAsset], statusByAssetID: [String: String]) -> [PHAsset] {
        source.filter { asset in
            let status = statusByAssetID[asset.localIdentifier]
            switch filterStatus {
            case "pending":
                return status == nil || status == "pending"
            case "delete":
                return status == "delete"
            case "keep":
                return status == "keep"
            case "maybe":
                return status == "maybe"
            default:
                return true
            }
        }
    }

    private func recomputeFilteredAssets() {
        var result = assets

        if let year = selectedYear, let month = selectedMonth {
            // O(n) 字典查表，避免反复调 Calendar.dateComponents
            result = result.filter { asset in
                guard let ym = yearMonthByID[asset.localIdentifier] else { return false }
                return ym.0 == year && ym.1 == month
            }
        }

        if !debouncedSearchText.isEmpty {
            let query = debouncedSearchText.lowercased()
            let matchingIDs = Set(noteByAssetID.compactMap { id, note in
                note.lowercased().contains(query) ? id : nil
            })
            result = result.filter { matchingIDs.contains($0.localIdentifier) }
        }

        if let cat = selectedAICategory {
            let allow: Set<String>
            switch cat {
            case .blurry: allow = aiBlurryIDs
            case .screenshots: allow = aiScreenshotsIDs
            case .possibleDuplicates: allow = aiDuplicatesIDs
            }
            result = result.filter { allow.contains($0.localIdentifier) }
        }

        // Avoid SwiftUI diff if the identity list hasn't actually changed.
        let newIDs = result.map(\.localIdentifier)
        if newIDs != filteredAssetIDs {
            filteredAssetsCache = result
            filteredAssetIDs = newIDs
        }
    }

    func loadPhotos() {
        // 权限被拒/受限：给出“去设置”空状态，而不是静默空列表。
        let authStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if authStatus == .denied || authStatus == .restricted {
            photoAccessDenied = true
            isLoading = false
            return
        }
        photoAccessDenied = false

        // 首次加载完成后，pop 回来不再全库重抓（几万张时秒级）。
        // 保留 30 秒节流的重抓，照顾外部（系统相册/iCloud）变更。
        if hasLoadedOnce, let last = lastLoadAt,
           Date().timeIntervalSince(last) < Self.reloadThrottleInterval {
            // onDisappear 配对 stop 过 prefetch，回来时重新预热即可。
            prefetchInitialThumbnails()
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            let options = PHFetchOptions()
            options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            let fetched = PHAsset.fetchAssets(with: options)

            var snapshot: [PHAsset] = []
            snapshot.reserveCapacity(fetched.count)
            fetched.enumerateObjects { asset, _, _ in
                snapshot.append(asset)
            }

            // 同一个后台 pass 里把 (年, 月) 字典也建好，主线程不再做 Calendar 工作。
            let ymMap = Self.computeYearMonthMap(for: snapshot)

            DispatchQueue.main.async {
                self.yearMonthByID = ymMap
                self.allAssetsSnapshot = snapshot
                self.assets = self.applyStatusFilter(to: snapshot, statusByAssetID: self.statusByAssetID)
                self.isLoading = false
                self.hasLoadedOnce = true
                self.lastLoadAt = Date()
                self.cachedYearsMonths = self.yearsMonthsForAssets(self.assets)
                self.recomputeFilteredAssets()
                self.recomputePendingDeleteCache()
                // Pre-warm thumbnail cache for first batch of visible photos
                self.prefetchInitialThumbnails()
            }
        }
    }

    func deleteMarkedPhotos() {
        cleanLog("[Grid] tapped deleteAll — isDeletingPhotos=\(isDeletingPhotos) pending=\(pendingDeleteAssetsCache.count)")
        guard !isDeletingPhotos else { cleanLog("[Grid] abort: already deleting (button locked)"); return }
        // 与菜单上的 "(N)" 用同一份缓存，保证按钮数字 == 实际删除数。
        let deleteIDs = pendingDeleteAssetsCache.map(\.localIdentifier)
        guard !deleteIDs.isEmpty else { cleanLog("[Grid] abort: no ids"); return }
        isDeletingPhotos = true
        startDeleteWatchdog()
        cleanLog("[Grid] requesting write access… status=\(PHPhotoLibrary.authorizationStatus(for: .readWrite).rawValue)")
        PhotoLibraryAuth.requestWriteAccess { granted in
            cleanLog("[Grid] write access result granted=\(granted)")
            guard granted else {
                isDeletingPhotos = false
                showingPhotoAuthAlert = true
                return
            }
            performDelete(ids: deleteIDs, exitSelection: false)
        }
    }

    func deleteSelectedPhotos() {
        guard !isDeletingPhotos else { return }
        let ids = Array(selectedIDs)
        guard !ids.isEmpty else { return }
        isDeletingPhotos = true
        startDeleteWatchdog()
        PhotoLibraryAuth.requestWriteAccess { granted in
            guard granted else {
                isDeletingPhotos = false
                showingPhotoAuthAlert = true
                return
            }
            performDelete(ids: ids, exitSelection: true)
        }
    }

    /// Safety valve against the delete button getting stuck grey: if we never
    /// reach performChanges (UIKit dropped the presentation, scene state
    /// misreported, a permission callback never returned…) unstick the button a
    /// few seconds later — but only while still waiting to present. Once the
    /// system dialog is up (deleteChangesStarted) we leave the lock to the
    /// performChanges completion so we never release it mid-deletion.
    private func startDeleteWatchdog() {
        deleteChangesStarted = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
            if isDeletingPhotos && !deleteChangesStarted {
                isDeletingPhotos = false
            }
        }
        // Hard safety net: on iPad the system "Delete N Photos?" confirmation can
        // be dropped without ever calling performChanges' completion, leaving the
        // button disabled forever (the "一键清理卡死" report). Re-enable
        // unconditionally after a long delay so it can never get permanently stuck.
        DispatchQueue.main.asyncAfter(deadline: .now() + 25) {
            if isDeletingPhotos { cleanLog("[Grid] HARD watchdog (25s) fired — button still locked, unsticking. Dialog likely never completed."); isDeletingPhotos = false }
        }
    }

    private func performDelete(ids: [String], exitSelection: Bool) {
        cleanLog("[Grid] performDelete — fetching \(ids.count) assets off main…")
        // fetchAssets + enumerateObjects 是同步 Photos I/O，整段挪到后台。
        DispatchQueue.global(qos: .userInitiated).async {
            let result = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
            var array: [PHAsset] = []
            array.reserveCapacity(result.count)
            result.enumerateObjects { a, _, _ in array.append(a) }
            cleanLog("[Grid] fetched \(result.count) assets, hopping to main for runWhenReady")

            // StorageStats 是 @MainActor，size lookup 在主线程做（dict 查表，毫秒级）。
            DispatchQueue.main.async {
                // 删除确认是 iOS 弹的，只有「前台活跃 + 当前没有弹层在做出现/消失
                // 过渡」时才呈现得了。菜单收起、alert 消失、或场景非活跃的瞬间去调，
                // UIKit 会丢掉系统框（什么都不弹）或压栈到下次启动。等到可呈现再弹。
                ForegroundGate.runWhenReady {
                    deleteChangesStarted = true
                    let bytes = storageStats.totalBestSize(for: array)
                    cleanLog("[Grid] ▶︎ calling PHPhotoLibrary.performChanges (system Delete dialog should appear NOW)")
                    PHPhotoLibrary.shared().performChanges({
                        PHAssetChangeRequest.deleteAssets(result)
                    }) { success, error in
                        cleanLog("[Grid] ◀︎ performChanges COMPLETION success=\(success) error=\(error?.localizedDescription ?? "nil")")
                        DispatchQueue.main.async {
                            isDeletingPhotos = false
                            // success=false 一般意味着用户在系统弹窗里取消了删除确认。
                            guard success else { return }
                            let idSet = Set(ids)

                            // 1) 立刻把已删除的 asset 从 snapshot 移除，UI 立即反映；
                            //    避免再调一次 loadPhotos() 全库重抓 + 重建年月字典（几万张时秒级）。
                            allAssetsSnapshot.removeAll { idSet.contains($0.localIdentifier) }

                            // 2) 标签删除用 Set 一遍过，O(n+m) 替代 O(n×m) 线性扫描。
                            for tag in allTags where idSet.contains(tag.assetID) {
                                modelContext.delete(tag)
                            }
                            try? modelContext.save()
                            // save 触发 @Query 重发 → onChange(of: allTags) 会用最新的
                            // allAssetsSnapshot + statusByAssetID 重新过滤，结果正确。

                            storageStats.recordCleanup(bytes: bytes)
                            ratingPrompt.registerCleanup()
                            WidgetCenter.shared.reloadAllTimelines()
                            if exitSelection { exitSelectionMode() }
                        }
                    }
                }
            }
        }
    }

    // MARK: - AI filter (lightweight)

    private func selectAIFilter(_ cat: AICleanCategory) {
        selectedAICategory = cat
        // 截图：直接从当前 assets 快速计算（不需要额外扫描）
        if cat == .screenshots {
            aiScreenshotsIDs = Set(assets.filter {
                ($0.mediaSubtypes.contains(.photoScreenshot))
            }.map { $0.localIdentifier })
            return
        }

        // 模糊 / 可能重复：默认只扫描最近 500 张；首次选择时才扫描
        Task { @MainActor in
            await ensureAIScan(for: cat, mode: .initialIfNeeded)
        }
    }

    private func appendAIScan() {
        guard let selectedAICategory else { return }
        guard selectedAICategory == .blurry || selectedAICategory == .possibleDuplicates else { return }
        Task { @MainActor in
            await ensureAIScan(for: selectedAICategory, mode: .appendNextBatch)
        }
    }

    private enum AIScanMode { case initialIfNeeded, appendNextBatch }

    @MainActor
    private func ensureAIScan(for cat: AICleanCategory, mode: AIScanMode) async {
        guard cat == .blurry || cat == .possibleDuplicates else { return }
        guard !aiIsScanning else { return }

        // 初始扫描：如果已经扫过（offset>0），则不重复扫
        if mode == .initialIfNeeded {
            if cat == .blurry, aiBlurryOffset > 0 { return }
            if cat == .possibleDuplicates, aiDuplicatesOffset > 0 { return }
        }

        aiIsScanning = true

        let sorted = sortedAssetsByDateDesc()
        let (batch, start, end) = nextBatch(for: cat, sortedAssets: sorted)
        guard !batch.isEmpty else {
            aiIsScanning = false
            aiProgressText = nil
            return
        }

        aiProgressText = (cat == .blurry)
            ? "grid.ai.progress.blurry".localized(with: start + 1, end, sorted.count)
            : "grid.ai.progress.duplicates".localized(with: start + 1, end, sorted.count)

        if cat == .possibleDuplicates {
            // 增量更新 buckets -> 结果集合。bucket 计算（Calendar.dateComponents
            // x500）放到后台，主线程先把进度浮层渲染出来。
            let currentBuckets = aiDupBuckets
            let updatedBuckets = await Task.detached(priority: .userInitiated) {
                Self.mergeDuplicateBuckets(currentBuckets, adding: batch)
            }.value
            aiDupBuckets = updatedBuckets
            aiDuplicatesIDs = computeDuplicateIDsFromBuckets()
            aiDuplicatesOffset = end
        } else {
            let newIDs = await findBlurryIDs(in: batch)
            aiBlurryIDs.formUnion(newIDs)
            aiBlurryOffset = end
        }

        aiIsScanning = false
        aiProgressText = nil
    }

    private func sortedAssetsByDateDesc() -> [PHAsset] {
        // assets 本来就是按 creationDate desc 取出来的；这里再保险排序一次
        assets.sorted { ($0.creationDate ?? .distantPast) > ($1.creationDate ?? .distantPast) }
    }

    private func nextBatch(for cat: AICleanCategory, sortedAssets: [PHAsset]) -> ([PHAsset], Int, Int) {
        let start = (cat == .blurry) ? aiBlurryOffset : aiDuplicatesOffset
        let end = min(start + aiBatchSize, sortedAssets.count)
        guard start < end else { return ([], start, end) }
        return (Array(sortedAssets[start..<end]), start, end)
    }

    /// Pure bucket merge so it can run off the main thread (Task.detached).
    nonisolated private static func mergeDuplicateBuckets(
        _ buckets: [String: [String]],
        adding batch: [PHAsset]
    ) -> [String: [String]] {
        var buckets = buckets
        let calendar = Calendar.current
        for asset in batch {
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
            buckets[key, default: []].append(asset.localIdentifier)
        }
        return buckets
    }

    private func computeDuplicateIDsFromBuckets() -> Set<String> {
        var result: Set<String> = []
        for (_, ids) in aiDupBuckets where ids.count >= 2 {
            result.formUnion(ids)
        }
        return result
    }

    // MARK: possible duplicates (cheap heuristic)
    private func findPossibleDuplicateIDs(in list: [PHAsset]) -> Set<String> {
        let calendar = Calendar.current
        var buckets: [String: [String]] = [:]
        buckets.reserveCapacity(list.count)

        for asset in list {
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
            buckets[key, default: []].append(asset.localIdentifier)
        }

        var result: Set<String> = []
        for (_, ids) in buckets where ids.count >= 2 {
            result.formUnion(ids)
        }
        return result
    }

    // MARK: blurry (more conservative)
    private func findBlurryIDs(in list: [PHAsset]) async -> Set<String> {
        var result: Set<String> = []

        let manager = PHImageManager.default()
        let options = PHImageRequestOptions()
        options.isSynchronous = false
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = false

        let targetSize = CGSize(width: 240, height: 240)

        // Process in windows of up to `maxConcurrent` images at once instead of
        // one-at-a-time. Each image is an independent disk-load + CIFilter pass,
        // so ~4-wide concurrency turns a 5-10s serial scan into ~1/4 the time.
        let maxConcurrent = 4
        var index = 0
        while index < list.count {
            let upper = min(index + maxConcurrent, list.count)
            let slice = Array(list[index..<upper])

            await withTaskGroup(of: String?.self) { group in
                for asset in slice {
                    group.addTask {
                        // requestImage 的回调在主线程：这里只把 UIImage 取出来，
                        // CIEdges + CIAreaAverage + CIContext.render 留在本后台
                        // task 里跑（CIContext 线程安全），避免扫描期间 UI 假死。
                        let image = await withCheckedContinuation { (cont: CheckedContinuation<UIImage?, Never>) in
                            manager.requestImage(
                                for: asset,
                                targetSize: targetSize,
                                contentMode: .aspectFill,
                                options: options
                            ) { image, _ in
                                cont.resume(returning: image)
                            }
                        }
                        guard let image, isLikelyBlurry(image) else { return nil }
                        return asset.localIdentifier
                    }
                }
                for await id in group {
                    if let id { result.insert(id) }
                }
            }

            index = upper
            await MainActor.run {
                self.aiProgressText = "ai.progress.analyzing".localized(with: index, list.count)
            }
        }
        return result
    }

    // nonisolated：在 findBlurryIDs 的后台 task 里执行（CIContext 线程安全），
    // 不能挂在 MainActor 上，否则 Core Image 又会回到主线程。
    nonisolated private func isLikelyBlurry(_ uiImage: UIImage) -> Bool {
        guard let cg = uiImage.cgImage else { return false }
        let ci = CIImage(cgImage: cg)
        // 更“苛刻”：提高 edge 强度 + 降低阈值，减少把清晰照片误判为模糊
        let edges = ci.applyingFilter("CIEdges", parameters: [kCIInputIntensityKey: 3.0])
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
        blurCIContext.render(
            avg,
            toBitmap: &pixel,
            rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: blurRenderColorSpace
        )
        let mean = (Double(pixel[0]) + Double(pixel[1]) + Double(pixel[2])) / (3.0 * 255.0)

        // 更保守的阈值（之前 0.035 太宽松）
        return mean < 0.020
    }
}

// MARK: - AssetThumbnailView
import SwiftUI
import Photos

struct AssetThumbnailView: View {
    let asset: PHAsset
    let noteText: String?
    let isSearchMatched: Bool

    @State private var thumbnail: UIImage?
    @State private var requestID: PHImageRequestID = PHInvalidImageRequestID

    var body: some View {
        ZStack(alignment: .topLeading) {
            // No per-cell GeometryReader: in a LazyVGrid that runs layout for
            // every cell on every scroll frame and is a classic source of
            // scroll jank. A square aspect-ratio container + scaledToFill/clip
            // gives the identical visual without the per-frame layout cost.
            ZStack {
                Rectangle().fill(Color.gray.opacity(0.20))

                if let image = thumbnail {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: "photo")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.secondary.opacity(0.6))
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .clipped()
            .contentShape(Rectangle())

            // 便签角标（保留）
            if let note = noteText, !note.isEmpty {
                Image(systemName: "note.text")
                    .font(.caption2.bold())
                    .foregroundColor(.white)
                    .padding(4)
                    .background(isSearchMatched ? Color.orange : Color.blue.opacity(0.8))
                    .clipShape(Circle())
                    .padding(5)
            }

            // 视频时长（保留）
            if asset.mediaType == .video {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Text(formatDuration(asset.duration))
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.white)
                            .padding(2)
                            .background(Color.black.opacity(0.5))
                            .cornerRadius(3)
                    }
                }
                .padding(4)
            }
        }
        .onAppear { requestThumbnailIfNeeded() }
        .onChange(of: asset.localIdentifier) { _, _ in requestThumbnailIfNeeded() }
        .onDisappear {
            // ✅ 关键：滚动复用时取消旧请求，避免错图/浪费
            PHAssetThumbnailLoader.shared.cancel(requestID)
        }
    }

    private func requestThumbnailIfNeeded() {
        // 先取消旧请求
        PHAssetThumbnailLoader.shared.cancel(requestID)
        requestID = PHInvalidImageRequestID

        let targetSize = gridThumbnailTargetSize()

        // 先用缓存立即显示（如果有）
        if let cached = PHAssetThumbnailLoader.shared.cachedImage(for: asset.localIdentifier, targetSize: targetSize) {
            thumbnail = cached
            return
        }

        requestID = PHAssetThumbnailLoader.shared.requestThumbnail(
            asset: asset,
            targetSize: targetSize
        ) { image, isDegraded in
            // 注意：degraded 也显示（防空白），非 degraded 会覆盖更清晰版本
            // 另外：避免“旧回调覆盖新 asset”的错图
            guard asset.localIdentifier == self.asset.localIdentifier else { return }
            self.thumbnail = image
        }
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        let m = Int(duration) / 60
        let s = Int(duration) % 60
        return String(format: "%d:%02d", m, s)
    }

    private func gridThumbnailTargetSize() -> CGSize {
        let scale = UIScreen.main.scale
        let gridSide = Layout.gridCellSide(spacing: 2)
        let pixelSide = max(gridSide * scale, 180)
        return CGSize(width: pixelSide, height: pixelSide)
    }
}
