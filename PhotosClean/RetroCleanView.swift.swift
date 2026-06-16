import SwiftUI
import Photos
import PhotosUI
import SwiftData
import AVKit
import UIKit
import UniformTypeIdentifiers

// MARK: - Main View
struct RetroCleanView: View {

    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject var storeManager: StoreManager
    @EnvironmentObject var paywallGate: PaywallGate
    @EnvironmentObject var storageStats: StorageStats

    @Environment(\.dismiss) private var dismiss

    let assets: [PHAsset]
    @State private var currentAssetID: String

    // MARK: - Buffer
    @State private var buffer: [CardState] = []
    @State private var loadingIDs: Set<String> = []
    private let preloadCount = 6
    private let stackDisplayCount = 3

    @State private var activeCard: CardState? = nil
    @State private var undoStack: [String] = []
    @State private var isUndoRestoring = false
    @State private var sourceRevision: Int = 0
    @State private var cardImageRequestIDs: [String: PHImageRequestID] = [:]
    @State private var tagCache: [String: PhotoTag] = [:]
    // Detached, un-persisted tag edits made during this swipe session. See
    // upsertTag / commitPendingTags for why writes are batched off the swipe path.
    @State private var pendingTags: [String: PhotoTag] = [:]
    @State private var assetOrderByID: [String: Int] = [:]
    // Throttled SwiftData save: coalesce per-swipe writes into one save (~0.6s
    // after the last change), with a forced flush on disappear/background.
    @State private var pendingTagSave: DispatchWorkItem?

    // Live / Video
    @State private var livePhoto: PHLivePhoto?
    @State private var isPlayingLivePhoto = false
    @State private var livePhotoAssetID: String?
    @State private var livePhotoPreloadID: PHImageRequestID = PHInvalidImageRequestID
    @State private var isLoadingLivePhoto = false
    @State private var pendingLivePlay = false
    @State private var livePhotoCache: [String: PHLivePhoto] = [:]
    @State private var liveWarmInFlight: Set<String> = []
    @State private var liveWarmRequestIDs: [String: PHImageRequestID] = [:]
    private static let liveWarmAhead = 2
    private static let liveCacheCap = 5
    @State private var player: AVPlayer?
    @State private var isMuted = true
    @State private var currentVideoAssetID: String? = nil
    @State private var currentVideoRequestID: PHImageRequestID = PHInvalidImageRequestID
    @State private var currentVideoUpgradeRequestID: PHImageRequestID = PHInvalidImageRequestID
    @State private var videoEndObserver: NSObjectProtocol?
    @State private var videoCloudProgress: Double? = nil
    private let imageManager = PHCachingImageManager()

    // Drag
    @GestureState private var dragOffset: CGSize = .zero
    @State private var settleOffset: CGSize = .zero
    @State private var isAnimatingOut = false

    // Note
    @State private var showNoteEditor = false
    @State private var currentNote = ""
    @FocusState private var isNoteFocused: Bool
    
    //share
    
    @State private var showShareOptions = false
    @State private var showPreview = false
    @State private var previewImage: UIImage?
    @State private var isPreparingShareImage = false

    // Zoom
    @State private var imageScale: CGFloat = 1.0
    @State private var zoomResetToken = UUID()
    private var isZooming: Bool { imageScale > 1.01 }

    // Network preference for speculative iCloud prefetch (mirrors ContentView).
    @AppStorage("prewarm_use_cellular") private var prewarmUseCellular: Bool = true
    private var prefetchAllowedNow: Bool {
        guard NetworkMonitor.shared.isConnected else { return false }
        return prewarmUseCellular || NetworkMonitor.shared.isUnmetered
    }

    private var cardWidth: CGFloat { Layout.cardWidth(inset: 40) }
    private var cardHeight: CGFloat { Layout.cardWidth(inset: 40) * 4 / 3 }
    init(assets: [PHAsset], initialIndex: Int) {
        self.assets = assets
        let safeInitialID: String
        if assets.indices.contains(initialIndex) {
            safeInitialID = assets[initialIndex].localIdentifier
        } else {
            safeInitialID = assets.first?.localIdentifier ?? ""
        }
        var orderByID: [String: Int] = [:]
        orderByID.reserveCapacity(assets.count)
        for (idx, asset) in assets.enumerated() where orderByID[asset.localIdentifier] == nil {
            orderByID[asset.localIdentifier] = idx
        }
        self._currentAssetID = State(initialValue: safeInitialID)
        self._assetOrderByID = State(initialValue: orderByID)
    }

    private var currentIndex: Int? {
        assetOrderByID[currentAssetID]
    }

    private var progressTextIndex: Int {
        guard let currentIndex else { return 0 }
        return min(currentIndex + 1, assets.count)
    }

    // MARK: - Swipe config
    private var swipeThresholdX: CGFloat { 120 }
    private var swipeThresholdY: CGFloat { 120 }
    private var outDistanceX: CGFloat { Layout.swipeOutDistanceX }
    private var outDistanceY: CGFloat { Layout.swipeOutDistanceY }

    private var currentCardOffset: CGSize {
        CGSize(
            width: dragOffset.width + settleOffset.width,
            height: dragOffset.height + settleOffset.height
        )
    }

    private var rotationDeg: Double {
        Double(currentCardOffset.width / 18)
    }

    private var swipeHint: String? {
        if isAnimatingOut { return nil }
        if currentCardOffset.width > 40 { return "keep" }
        if currentCardOffset.width < -40 { return "delete" }
        if currentCardOffset.height < -40 { return "maybe" }
        return nil
    }

    private var swipeHintOpacity: Double {
        let x = abs(currentCardOffset.width)
        let y = abs(currentCardOffset.height)
        let v = max(x / 180, y / 180)
        return Double(min(max(v, 0.0), 1.0))
    }

    // MARK: - Filmstrip
    private var filmstripAssets: [PHAsset] { filmstripSnapshot }
    private var currentDisplayedAssetID: String? {
        // While waiting for the in-order next card, buffer.first may be a later
        // photo — highlight the asset we're actually advancing to instead.
        activeCard?.asset.localIdentifier ?? currentAssetID
    }
    @State private var filmstripSnapshot: [PHAsset] = []

    private func refreshFilmstripSnapshot() {
        guard !assets.isEmpty else {
            filmstripSnapshot = []
            return
        }
        let center = min(max(currentIndex ?? 0, 0), assets.count - 1)
        let from = max(0, center - 10)
        let to = min(assets.count - 1, center + 10)
        filmstripSnapshot = Array(assets[from...to])
    }

    private func jump(to asset: PHAsset) {
        let newAssetID = asset.localIdentifier
        guard newAssetID != currentAssetID else { return }
        guard assetOrderByID[newAssetID] != nil else { return }
        currentAssetID = newAssetID
        bootstrapBuffer(force: true)
    }

    // MARK: - Stable layout metrics
    private let cardHorizontalInset: CGFloat = 56
    private let bottomButtonsLiftFromTab: CGFloat = 52

    private var cardStageHeight: CGFloat {
        let cardW = Layout.cardWidth(inset: cardHorizontalInset)
        let cardH = cardW * 4 / 3
        // cardStackView uses .padding(20)
        return cardH + 40
    }

    private let filmstripStageHeight: CGFloat = 46

    private var shouldShowDoneState: Bool {
        guard activeCard == nil, buffer.isEmpty, loadingIDs.isEmpty else { return false }
        if assets.isEmpty { return true }
        guard let idx = currentIndex else { return true }
        return idx >= assets.count - 1
    }

    private var shouldShowLoadingState: Bool {
        // No active card (even if later cards are buffered) means we're waiting
        // for the in-order next photo — show the spinner instead of letting a
        // later buffered card jump to the top of the stack.
        activeCard == nil && !shouldShowDoneState
    }

    // MARK: - Body
    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()

            VStack(spacing: 0) {
                headerView
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 8)

                // Keep filmstrip height stable to avoid layout jumps when card switches/loading.
                FilmstripView(assets: filmstripAssets,
                             selectedID: currentDisplayedAssetID,
                             onSelect: jump)
                    .padding(.horizontal, 12)
                    .padding(.bottom, -2)
                    .frame(height: filmstripStageHeight)
                    .opacity(activeCard == nil ? 0 : 1)
                    .allowsHitTesting(activeCard != nil)

                ZStack {
                    ContentUnavailableView(
                        "retro.done".localized,
                        systemImage: "checkmark.circle",
                        description: Text("retro.finished".localized)
                    )
                    .opacity(shouldShowDoneState ? 1 : 0)

                    ProgressView()
                        .opacity(shouldShowLoadingState ? 1 : 0)

                    if activeCard != nil {
                        cardStackView
                            .padding(20)
                    }
                }
                .frame(height: cardStageHeight)
            }

            // Short phones (iPhone SE / mini): drop the swipe circles so the card
            // can be larger; swipes and the on-card edge buttons still cover
            // delete / keep / maybe. Taller phones & iPad keep the buttons.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if !Layout.isCompactHeight {
                    bottomButtons
                        .padding(.horizontal, 18)
                        .padding(.vertical, 8)
                        .padding(.bottom, bottomButtonsLiftFromTab)
                        .opacity(activeCard != nil ? 1 : 0)
                        .allowsHitTesting(activeCard != nil)
                        .animation(.none, value: activeCard != nil)
                }
            }

            if showNoteEditor {
                noteEditorOverlay
            }
            if showShareOptions {
                shareOptionsOverlay
            }

            if showPreview, let preview = previewImage {
                previewOverlay(image: preview)
            }

            if isPreparingShareImage {
                sharePreparingOverlay
            }
        }
        // Retro is pushed from a NavigationStack (Library). Hide the default navigation bar
        // so its extra top inset doesn't push the whole page down compared to ContentView.
        .toolbar(.hidden, for: .navigationBar)
        .trackFrameHitches("retro")
        .onAppear {
            cleanLog("[Retro] onAppear START assets=\(assets.count) currentID=\(currentAssetID)")
            measureMain("retro.onAppear.rebuildTagCache") { rebuildTagCache() }
            measureMain("retro.onAppear.refreshFilmstrip") { refreshFilmstripSnapshot() }
            measureMain("retro.onAppear.bootstrapBuffer") { bootstrapBuffer(force: true) }
            cleanLog("[Retro] onAppear DONE")
        }
        .onDisappear {
            stopAllMedia()
            cancelPendingImageRequests()
            cancelLiveWarmRequests()
            flushPendingTagSave()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
            stopAllMedia()
            flushPendingTagSave()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
            stopAllMedia()
            flushPendingTagSave()
        }
        .onChange(of: activeCard?.asset.localIdentifier) { _, _ in
            measureMain("retro.activeCardChange") {
                stopAllMedia()
                resetImageZoom()
                syncNoteForCurrent()
                prepareMediaForCurrent()
            }
        }
        .onChange(of: currentAssetID) { _, _ in
            refreshFilmstripSnapshot()
        }


    }

    // MARK: - Card Stack
    private var visibleStackCards: [CardState] {
        var seen: Set<String> = []
        var unique: [CardState] = []

        // 先放 activeCard，确保当前卡片始终在栈顶
        if let active = activeCard {
            let id = active.asset.localIdentifier
            seen.insert(id)
            unique.append(active)
        }

        for card in buffer {
            let id = card.asset.localIdentifier
            if seen.insert(id).inserted {
                unique.append(card)
            }
        }
        return unique
    }

    private var cardStackView: some View {
        ZStack {
            ForEach(Array(visibleStackCards.prefix(stackDisplayCount).enumerated()),
                    id: \.element.asset.localIdentifier) { idx, card in

                let isTop = (idx == 0)

                Group {
                    if isTop {
                        MediaCardView(
                            asset: card.asset,
                            displayImage: card.image,
                            livePhoto: $livePhoto,
                            isPlayingLivePhoto: $isPlayingLivePhoto,
                            isLoadingLivePhoto: isLoadingLivePhoto,
                            zoomScale: $imageScale,
                            zoomResetToken: zoomResetToken,
                            player: $player,
                            isMuted: $isMuted,
                            videoCloudProgress: videoCloudProgress,
                            isDragging: dragOffset != .zero,
                            isAnimatingOut: isAnimatingOut,
                            onLoadVideo: { loadVideo(for: card.asset) },
                            onToggleLive: toggleLivePhoto,
                            onShare: shareCurrentAsset,
                            onOpenNote: openNoteEditor,
                            hasNote: hasNoteForCurrentAsset(),
                            onEdgeSwipe: { direction in
                                resetImageZoom()
                                if direction > 0 {
                                    triggerButtonSwipe(status: "keep")
                                } else {
                                    triggerButtonSwipe(status: "delete")
                                }
                            }
                        )
                    } else {
                        RetroSnapshotCardView(image: card.image)
                            .frame(width: cardWidth, height: cardHeight)
                    }
                }
                    .offset(
                        x: isTop ? currentCardOffset.width : 0,
                        y: isTop ? currentCardOffset.height : 0
                    )
                    .rotationEffect(isTop ? .degrees(rotationDeg) : .degrees(0))
                    .zIndex(Double(stackDisplayCount - idx))
                    .allowsHitTesting(isTop && !isAnimatingOut)
                    .overlay(isTop ? swipeHintOverlay : nil)
                    // Only attach the drag recognizer to the top card. Attaching it
                    // to every stacked card creates gesture state per card and
                    // re-installs recognizers on each swipe — the source of jank.
                    .highPriorityGesture(
                        isTop ? cardGesture() : nil,
                        including: (isTop && !isZooming) ? .all : .subviews
                    )
            }
        }
    }

    private var swipeHintOverlay: some View {
        ZStack {
            if let hint = swipeHint {
                VStack {
                    if hint == "maybe" {
                        Text("hint.maybe".localized)
                            .font(.system(size: 22, weight: .heavy, design: .rounded))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(Color.black.opacity(0.15))
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                            .padding(.top, 16)
                    } else {
                        HStack {
                            Text(hint == "keep" ? "hint.keep".localized : "hint.delete".localized)
                                .font(.system(size: 22, weight: .heavy, design: .rounded))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                                .background(Color.black.opacity(0.15))
                                .clipShape(RoundedRectangle(cornerRadius: 14))

                            Spacer()
                        }
                        .padding(.top, 16)
                        .padding(.horizontal, 16)
                    }

                    Spacer()
                }
                .opacity(swipeHintOpacity)
                .animation(.easeOut(duration: 0.12), value: swipeHintOpacity)
            }
        }
    }

    // MARK: - Gesture
    private func cardGesture() -> some Gesture {
        DragGesture(minimumDistance: 8)
            .updating($dragOffset) { value, state, _ in
                guard !isAnimatingOut, !isZooming else { return }
                state = value.translation
            }
            .onChanged { _ in
                if settleOffset != .zero { settleOffset = .zero }
            }
            .onEnded { value in
                guard !isAnimatingOut else { return }

                let t = value.translation

                guard !isZooming else {
                    bounceBack(from: t)
                    return
                }

                let p = value.predictedEndTranslation
                let pick = CGSize(
                    width: t.width * 0.4 + p.width * 0.6,
                    height: t.height * 0.4 + p.height * 0.6
                )

                if pick.width > swipeThresholdX {
                    commitSwipeAndAdvance(status: "keep", from: t, predicted: pick)
                } else if pick.width < -swipeThresholdX {
                    commitSwipeAndAdvance(status: "delete", from: t, predicted: pick)
                } else if pick.height < -swipeThresholdY {
                    commitSwipeAndAdvance(status: "maybe", from: t, predicted: pick)
                } else {
                    bounceBack(from: t)
                }
            }
    }

    private func bounceBack(from t: CGSize) {
        settleOffset = t
        withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
            settleOffset = .zero
        }
    }

    private func commitSwipeAndAdvance(status: String, from t: CGSize, predicted: CGSize) {
        guard !isUndoRestoring else { return }
        guard let card = activeCard else { return }
        isAnimatingOut = true

        settleOffset = t

        let clampY = max(min(predicted.height, 420), -420)
        let clampX = max(min(predicted.width, 420), -420)

        let out: CGSize
        switch status {
        case "delete":
            out = CGSize(width: -outDistanceX, height: clampY)
        case "keep":
            out = CGSize(width: outDistanceX, height: clampY)
        default:
            out = CGSize(width: clampX, height: -outDistanceY)
        }

        withAnimation(.easeOut(duration: 0.18)) {
            settleOffset = out
        }

        let assetID = card.asset.localIdentifier

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            self.undoStack.append(assetID)

            // Cancel the swiped card's in-flight (esp. iCloud) download so it stops
            // competing with the next card's fetch.
            if let reqID = self.cardImageRequestIDs.removeValue(forKey: assetID) {
                self.imageManager.cancelImageRequest(reqID)
            }

            self.upsertTag(assetID: assetID) { tag in
                tag.status = status
                tag.createdAt = Date()
            }

            if status == "delete" {
                self.storageStats.noteAsset(card.asset)
            }

            self.paywallGate.recordSwipe(isPremium: self.storeManager.hasUnlockedPremium)

            // Hard wall: auto-present the paywall the moment the daily free quota runs out.
            if !self.storeManager.hasUnlockedPremium,
               self.paywallGate.isQuotaExhausted,
               !self.paywallGate.showPaywall {
                self.paywallGate.showPaywall = true
            }

            self.stopAllMedia()
            self.resetImageZoom()

            var tx = Transaction()
            tx.disablesAnimations = true

            withTransaction(tx) {
                // 从 buffer 中移除刚滑走的卡片
                self.buffer.removeAll { $0.asset.localIdentifier == assetID }
                self.settleOffset = .zero

                guard let processedIndex = self.assetOrderByID[assetID] else {
                    self.activeCard = nil
                    self.isAnimatingOut = false
                    return
                }
                let nextIndex = processedIndex + 1

                guard nextIndex < self.assets.count else {
                    self.activeCard = nil
                    self.isAnimatingOut = false
                    self.refreshFilmstripSnapshot()
                    return
                }

                let nextAssetID = self.assets[nextIndex].localIdentifier
                self.currentAssetID = nextAssetID

                // 先从 buffer 里找下一张
                if let nextCard = self.buffer.first(where: { $0.asset.localIdentifier == nextAssetID }) {
                    self.activeCard = nextCard
                    self.normalizeBuffer(excluding: nextAssetID)
                    self.syncNoteForCurrent()
                    self.ensureBuffer()
                } else {
                    // 下一张还没加载完：保持 currentAssetID 指向顺序上的下一张并
                    // 显示 loading 等它送达。不能拿 buffer 里更后面的卡顶替——
                    // 顶替会把未到的那张挤出 keep 窗口（回调被 order 守卫丢弃），
                    // 该照片本会话就永远不会出现了。
                    self.activeCard = nil
                    if self.loadingIDs.contains(nextAssetID) {
                        // 请求已在途：到货后 ensureBuffer 的回调会按
                        // card.id == currentAssetID 回填 activeCard；失败则由
                        // handleCardLoadFailure 跳过并推进。
                        self.ensureBuffer()
                    } else {
                        // 没有在途请求（如此前失败被清理）→ 重新发起加载
                        self.bootstrapBuffer(force: false)
                    }
                }

                self.isAnimatingOut = false
            }
        }
    }

    // MARK: - Zoom reset
    private func resetImageZoom() {
        imageScale = 1.0
        zoomResetToken = UUID()
    }

    // MARK: - Header
    var headerView: some View {
        // Keep a normal product header (brand/title) + controls row slightly lower.
        HStack(spacing: 12) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.title3.weight(.semibold))
                    .frame(width: 36, height: 36)
                    .background(.ultraThinMaterial, in: Circle())
            }

            Text("retro.progress".localized(with: progressTextIndex, assets.count))
                .font(.caption.monospacedDigit())
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: undoLastAction) {
                Image(systemName: "arrow.uturn.backward.circle.fill")
                    .font(.title2)
                    .frame(width: 44, height: 44)
            }
            .opacity(undoStack.isEmpty ? 0 : 1)
            .disabled(undoStack.isEmpty || isAnimatingOut || isUndoRestoring)
        }
        .padding(.top, 4)
        .transaction { $0.animation = nil }
    }

    // MARK: - Bottom buttons
    private func triggerButtonSwipe(status: String) {
        guard !isAnimatingOut else { return }
        guard !isUndoRestoring else { return }
        guard activeCard != nil else { return }
        if isZooming { resetImageZoom() }

        let from: CGSize
        switch status {
        case "delete": from = CGSize(width: -140, height: 0)
        case "keep":   from = CGSize(width: 140, height: 0)
        default:       from = CGSize(width: 0, height: -140)
        }

        let predicted = CGSize(width: from.width * 6, height: from.height * 3)
        commitSwipeAndAdvance(status: status, from: from, predicted: predicted)
    }

    var bottomButtons: some View {
        HStack(spacing: 40) {
            ActionButton(icon: "trash.fill", color: .gray) {
                triggerButtonSwipe(status: "delete")
            }
            ActionButton(icon: "clock.fill", color: .yellow) {
                triggerButtonSwipe(status: "maybe")
            }
            ActionButton(icon: "heart.fill", color: .green) {
                triggerButtonSwipe(status: "keep")
            }
        }
    }

    // MARK: - Buffer Management
    private func rebuildTagCache() {
        // One-shot fetch instead of a live @Query: this view only reads tags via
        // tagCache, and a @Query would re-fetch the whole table on every save.
        let descriptor = FetchDescriptor<PhotoTag>(
            sortBy: [SortDescriptor(\PhotoTag.createdAt, order: .reverse)]
        )
        let tags = (try? modelContext.fetch(descriptor)) ?? []
        var map: [String: PhotoTag] = [:]
        map.reserveCapacity(tags.count)
        for tag in tags where map[tag.assetID] == nil {
            map[tag.assetID] = tag
        }
        tagCache = map
    }

    private func insertBufferInOrder(_ card: CardState) {
        let newID = card.asset.localIdentifier
        let newOrder = assetOrderByID[newID] ?? Int.max
        let insertAt = buffer.firstIndex { existing in
            let order = assetOrderByID[existing.asset.localIdentifier] ?? Int.max
            return order > newOrder
        } ?? buffer.endIndex
        buffer.insert(card, at: insertAt)
    }

    private func normalizeBuffer(excluding excludedID: String? = nil) {
        var seen: Set<String> = []
        if let excludedID { seen.insert(excludedID) }

        var normalized: [CardState] = []
        for card in buffer {
            let id = card.asset.localIdentifier
            if seen.insert(id).inserted {
                normalized.append(card)
            }
        }
        buffer = normalized
    }

    func bootstrapBuffer(force: Bool) {
        stopAllMedia()

        if force {
            sourceRevision += 1
            cancelPendingImageRequests()
            cancelLiveWarmRequests()
            buffer.removeAll()
            loadingIDs.removeAll()
            livePhotoCache.removeAll()
            activeCard = nil
            settleOffset = .zero
            isAnimatingOut = false
        }
        let revision = sourceRevision

        guard let currentIndex, assets.indices.contains(currentIndex) else { return }
        let currentAsset = assets[currentIndex]
        let id = currentAsset.localIdentifier

        loadingIDs.insert(id)

        cardImageRequestIDs[id] = loadCardState(for: currentAsset) { card, isDegraded in
            DispatchQueue.main.async {
                self.loadingIDs.remove(id)
                if !isDegraded {
                    self.cardImageRequestIDs.removeValue(forKey: id)
                }
                guard revision == self.sourceRevision else { return }

                guard let card else {
                    self.handleCardLoadFailure(assetID: id)
                    return
                }

                // The user may have swiped away during the degraded→full load window.
                // Only adopt this card as active if it's still the current one;
                // otherwise upgrade it in the buffer (if still in range) or drop it,
                // so a late delivery can't resurrect a dismissed card.
                guard self.currentAssetID == id else {
                    if let idx = self.buffer.firstIndex(where: { $0.asset.localIdentifier == id }) {
                        self.buffer[idx] = card
                    }
                    return
                }

                self.buffer.removeAll(where: { $0.asset.localIdentifier == id })
                self.buffer.insert(card, at: 0)
                self.normalizeBuffer(excluding: id)

                self.activeCard = card
                self.syncNoteForCurrent()
                self.ensureBuffer()
            }
        }
    }

    func ensureBuffer() {
        let revision = sourceRevision
        guard let currentIndex else {
            buffer.removeAll()
            return
        }

        for offset in 1...preloadCount {
            let targetIndex = currentIndex + offset
            guard targetIndex < assets.count else { break }

            let asset = assets[targetIndex]
            let id = asset.localIdentifier

            if buffer.contains(where: { $0.asset.localIdentifier == id }) || loadingIDs.contains(id) {
                continue
            }

            loadingIDs.insert(id)

            cardImageRequestIDs[id] = loadCardState(for: asset) { card, isDegraded in
                DispatchQueue.main.async {
                    self.loadingIDs.remove(id)
                    if !isDegraded {
                        self.cardImageRequestIDs.removeValue(forKey: id)
                    }
                    guard revision == self.sourceRevision else { return }

                    guard let card else {
                        self.handleCardLoadFailure(assetID: id)
                        return
                    }

                    guard let order = self.assetOrderByID[id] else { return }

                    // Late async callbacks from older swipes can arrive out of order.
                    // Always evaluate against the latest current index, not the captured one.
                    guard let liveCurrentIndex = self.currentIndex else { return }
                    let keepFrom = liveCurrentIndex
                    let keepTo = min(self.assets.count - 1, liveCurrentIndex + self.preloadCount + 2)
                    guard order >= keepFrom && order <= keepTo else { return }

                    // Upgrade path: if card already exists (degraded delivered earlier), update its image
                    if self.activeCard?.asset.localIdentifier == id {
                        self.activeCard = card
                        return
                    }
                    if let idx = self.buffer.firstIndex(where: { $0.asset.localIdentifier == id }) {
                        self.buffer[idx] = card
                        return
                    }

                    self.insertBufferInOrder(card)

                    // 回填 activeCard 只允许顺序上正等待的那张（currentAssetID），
                    // 否则后面的卡会顶替还没到的卡，造成闪变/进度错位。
                    if self.activeCard == nil, id == self.currentAssetID {
                        self.activeCard = card
                        self.syncNoteForCurrent()
                    }
                }
            }
        }

        let keepFrom = currentIndex
        let keepTo = min(assets.count - 1, currentIndex + preloadCount + 2)
        if keepFrom <= keepTo, assets.indices.contains(keepFrom), assets.indices.contains(keepTo) {
            let keepIDs = Set((keepFrom...keepTo).map { assets[$0].localIdentifier })
            buffer.removeAll(where: { !keepIDs.contains($0.asset.localIdentifier) })
        } else {
            buffer.removeAll()
        }
    }

    /// A card request finished without an image (e.g. iCloud fetch failed).
    /// If we're currently blocked waiting on that exact asset, skip past it so
    /// the loading state can never get stuck forever.
    private func handleCardLoadFailure(assetID: String) {
        loadingIDs.remove(assetID)
        cardImageRequestIDs.removeValue(forKey: assetID)

        // A degraded image may have been delivered earlier; if a card already
        // exists for this asset there's nothing to recover from.
        guard currentAssetID == assetID,
              activeCard?.asset.localIdentifier != assetID,
              !buffer.contains(where: { $0.asset.localIdentifier == assetID }) else { return }

        guard let failedIndex = assetOrderByID[assetID] else { return }
        let nextIndex = failedIndex + 1
        guard nextIndex < assets.count else {
            // Failed on the last photo → fall through to the done state.
            refreshFilmstripSnapshot()
            return
        }

        let nextAssetID = assets[nextIndex].localIdentifier
        currentAssetID = nextAssetID

        if let nextCard = buffer.first(where: { $0.asset.localIdentifier == nextAssetID }) {
            activeCard = nextCard
            normalizeBuffer(excluding: nextAssetID)
            syncNoteForCurrent()
            ensureBuffer()
        } else if loadingIDs.contains(nextAssetID) {
            ensureBuffer()
        } else {
            bootstrapBuffer(force: false)
        }
    }

    func undoLastAction() {
        guard !isAnimatingOut else { return }
        guard !isUndoRestoring else { return }
        guard let lastAssetID = undoStack.popLast() else { return }
        guard let lastIndex = assetOrderByID[lastAssetID] else { return }
        guard assets.indices.contains(lastIndex) else { return }
        isUndoRestoring = true
        sourceRevision += 1
        let revision = sourceRevision
        cancelPendingImageRequests()
        // 也取消正在进行的视频请求
        cancelCurrentVideoRequests()
        videoCloudProgress = nil
        loadingIDs.removeAll()

        upsertTag(assetID: lastAssetID) { tag in
            tag.status = "pending"
        }

        // 超时保护：3 秒内 completion 没回来就强制恢复
        let undoTimeout = DispatchWorkItem { [self] in
            guard self.isUndoRestoring else { return }
            self.isUndoRestoring = false
            self.currentAssetID = lastAssetID
            self.bootstrapBuffer(force: true)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0, execute: undoTimeout)

        cardImageRequestIDs[lastAssetID] = loadCardState(for: assets[lastIndex]) { restored, isDegraded in
            DispatchQueue.main.async {
                undoTimeout.cancel()
                if !isDegraded {
                    self.cardImageRequestIDs.removeValue(forKey: lastAssetID)
                }
                guard revision == self.sourceRevision else {
                    self.isUndoRestoring = false
                    return
                }
                guard let restored else {
                    // Restore-load failed (e.g. iCloud unreachable). Fall back to
                    // a full bootstrap; if the asset keeps failing, the failure
                    // path will skip past it instead of hanging.
                    self.isUndoRestoring = false
                    self.currentAssetID = lastAssetID
                    self.bootstrapBuffer(force: true)
                    return
                }
                self.currentAssetID = lastAssetID

                self.stopAllMedia()
                self.resetImageZoom()
                self.settleOffset = .zero

                self.buffer.removeAll(where: { $0.asset.localIdentifier == lastAssetID })
                self.buffer.insert(restored, at: 0)
                self.normalizeBuffer(excluding: lastAssetID)

                self.activeCard = restored
                self.syncNoteForCurrent()
                self.ensureBuffer()
                self.refreshFilmstripSnapshot()
                self.isUndoRestoring = false

                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            }
        }
    }

    // MARK: - Image Loading
    /// Requests the card image. `completion` may be called twice (degraded then
    /// full quality). On a final failure it is called once with `nil` so callers
    /// can unblock the loading state instead of waiting forever.
    @discardableResult
    func loadCardState(for asset: PHAsset, completion: @escaping (CardState?, _ isDegraded: Bool) -> Void) -> PHImageRequestID {
        let scale = UIScreen.main.scale
        let target = CGSize(width: cardWidth * scale, height: cardHeight * scale)

        let opt = PHImageRequestOptions()
        opt.isNetworkAccessAllowed = true
        opt.deliveryMode = .opportunistic
        opt.resizeMode = .fast

        return imageManager.requestImage(
            for: asset,
            targetSize: target,
            contentMode: .aspectFit,
            options: opt
        ) { img, info in
            if let cancelled = info?[PHImageCancelledKey] as? Bool, cancelled { return }
            let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
            guard let img else {
                // Only report failure on the final delivery; a nil degraded pass
                // can still be followed by a successful full-quality one.
                if !isDegraded {
                    completion(nil, false)
                }
                return
            }
            if isDegraded {
                // Low-res interim image: cheap to decode, deliver immediately so
                // the card paints fast.
                completion(CardState(asset: asset, image: img), true)
            } else {
                // Full image: force-decode off the main thread. PHImageManager
                // hands back an undecoded image, so the first Image(uiImage:) /
                // UIImageView render would otherwise decode the full bitmap ON
                // THE MAIN THREAD (the 200-500ms swipe stalls we measured).
                // prepareForDisplay does the decode on a background queue.
                img.prepareForDisplay { decoded in
                    DispatchQueue.main.async {
                        completion(CardState(asset: asset, image: decoded ?? img), false)
                    }
                }
            }
        }
    }

    private func cancelPendingImageRequests() {
        for requestID in cardImageRequestIDs.values {
            imageManager.cancelImageRequest(requestID)
        }
        cardImageRequestIDs.removeAll()
    }

    // MARK: - Live Photo
    private func toggleLivePhoto() {
        guard let asset = activeCard?.asset,
              asset.mediaSubtypes.contains(.photoLive) else { return }

        // Tapped again while a slow (iCloud) load is in progress — cancel it,
        // including the actual in-flight request so it stops downloading.
        if isLoadingLivePhoto {
            isLoadingLivePhoto = false
            pendingLivePlay = false
            if livePhotoPreloadID != PHInvalidImageRequestID {
                PHImageManager.default().cancelImageRequest(livePhotoPreloadID)
                livePhotoPreloadID = PHInvalidImageRequestID
            }
            return
        }
        if isPlayingLivePhoto {
            isPlayingLivePhoto = false
            return
        }
        // Preloaded and warm → instant play.
        if livePhoto != nil, livePhotoAssetID == asset.localIdentifier {
            isPlayingLivePhoto = true
            return
        }
        // Not ready yet (historical iCloud Live Photo still downloading): show a
        // spinner and auto-play the moment the background load finishes.
        pendingLivePlay = true
        isLoadingLivePhoto = true
        preloadLivePhoto(for: asset)
    }

    /// Load the Live Photo as soon as the card appears so a tap plays instantly.
    private func preloadLivePhoto(for asset: PHAsset) {
        let assetID = asset.localIdentifier
        guard livePhotoAssetID != assetID else { return }

        if let cached = livePhotoCache[assetID] {
            livePhoto = cached
            livePhotoAssetID = assetID
            return
        }

        if livePhotoPreloadID != PHInvalidImageRequestID {
            PHImageManager.default().cancelImageRequest(livePhotoPreloadID)
            livePhotoPreloadID = PHInvalidImageRequestID
        }

        let opt = PHLivePhotoRequestOptions()
        opt.isNetworkAccessAllowed = true
        opt.deliveryMode = .highQualityFormat
        let scale = UIScreen.main.scale
        let target = CGSize(width: cardWidth * scale, height: cardHeight * scale)

        livePhotoPreloadID = PHImageManager.default().requestLivePhoto(
            for: asset, targetSize: target, contentMode: .aspectFit, options: opt
        ) { live, _ in
            guard let live else { return }
            DispatchQueue.main.async {
                self.cacheLivePhoto(live, for: assetID)
                guard self.activeCard?.asset.localIdentifier == assetID else { return }
                self.livePhoto = live
                self.livePhotoAssetID = assetID
                if self.pendingLivePlay {
                    self.pendingLivePlay = false
                    self.isLoadingLivePhoto = false
                    self.isPlayingLivePhoto = true
                }
            }
        }
    }

    /// Pre-download Live Photos for the next cards so they're instant on arrival.
    private func warmUpcomingLivePhotos() {
        // Speculative iCloud prefetch must honor the user's network preference.
        // Retro shows old (offloaded) photos, so without this guard every swipe
        // kicks off high-quality Live Photo downloads that starve the visible
        // card's still-image fetch for bandwidth/decode — the source of the jank.
        guard prefetchAllowedNow else { return }
        let upcoming = buffer.prefix(6).map(\.asset)
            .filter { $0.mediaSubtypes.contains(.photoLive) }
        var warmed = 0
        for asset in upcoming {
            if warmed >= Self.liveWarmAhead { break }
            warmed += 1
            let id = asset.localIdentifier
            if livePhotoCache[id] != nil || liveWarmInFlight.contains(id) { continue }
            liveWarmInFlight.insert(id)

            let opt = PHLivePhotoRequestOptions()
            opt.isNetworkAccessAllowed = true
            opt.deliveryMode = .highQualityFormat
            let scale = UIScreen.main.scale
            let target = CGSize(width: cardWidth * scale, height: cardHeight * scale)

            liveWarmRequestIDs[id] = PHImageManager.default().requestLivePhoto(
                for: asset, targetSize: target, contentMode: .aspectFit, options: opt
            ) { live, _ in
                DispatchQueue.main.async {
                    self.liveWarmInFlight.remove(id)
                    self.liveWarmRequestIDs.removeValue(forKey: id)
                    guard let live else { return }
                    self.cacheLivePhoto(live, for: id)
                }
            }
        }
    }

    /// Cancel all in-flight Live Photo warm-up downloads (on disappear or when
    /// the buffer is force-rebuilt) so they stop competing for bandwidth.
    private func cancelLiveWarmRequests() {
        for requestID in liveWarmRequestIDs.values {
            PHImageManager.default().cancelImageRequest(requestID)
        }
        liveWarmRequestIDs.removeAll()
        liveWarmInFlight.removeAll()
    }

    private func cacheLivePhoto(_ live: PHLivePhoto, for id: String) {
        livePhotoCache[id] = live
        guard livePhotoCache.count > Self.liveCacheCap else { return }
        let keep = Set([activeCard?.asset.localIdentifier].compactMap { $0 }
                       + buffer.map(\.asset.localIdentifier))
        for k in livePhotoCache.keys where !keep.contains(k) {
            livePhotoCache.removeValue(forKey: k)
            if livePhotoCache.count <= Self.liveCacheCap { break }
        }
    }

    // MARK: - Video
    private func prepareMediaForCurrent() {
        guard let asset = activeCard?.asset else { return }
        if asset.mediaType == .video {
            loadVideo(for: asset)
        } else if asset.mediaSubtypes.contains(.photoLive) {
            preloadLivePhoto(for: asset)
        }
        warmUpcomingLivePhotos()
    }

    func loadVideo(for asset: PHAsset) {
        guard asset.mediaType == .video else { return }

        let id = asset.localIdentifier
        if currentVideoAssetID == id, player != nil { return }
        currentVideoAssetID = id
        videoCloudProgress = nil
        cancelCurrentVideoRequests()

        let localOpt = PHVideoRequestOptions()
        localOpt.isNetworkAccessAllowed = false
        localOpt.deliveryMode = .fastFormat
        localOpt.version = .current

        currentVideoRequestID = imageManager.requestPlayerItem(forVideo: asset, options: localOpt) { item, info in
            DispatchQueue.main.async {
                guard self.currentVideoAssetID == id else { return }
                self.currentVideoRequestID = PHInvalidImageRequestID
                if let cancelled = info?[PHImageCancelledKey] as? Bool, cancelled { return }

                if let item {
                    self.applyVideoItem(item, preservePlaybackState: false)
                } else {
                    self.requestNetworkFastVideo(for: asset)
                }
            }
        }
    }

    private func requestNetworkFastVideo(for asset: PHAsset) {
        let id = asset.localIdentifier
        let opt = PHVideoRequestOptions()
        opt.isNetworkAccessAllowed = true
        opt.deliveryMode = .fastFormat
        opt.version = .current
        opt.progressHandler = { progress, _, _, _ in
            DispatchQueue.main.async {
                guard self.currentVideoAssetID == id else { return }
                self.videoCloudProgress = max(0, min(progress, 1))
            }
        }

        videoCloudProgress = 0
        currentVideoRequestID = imageManager.requestPlayerItem(forVideo: asset, options: opt) { item, info in
            DispatchQueue.main.async {
                guard self.currentVideoAssetID == id else { return }
                self.currentVideoRequestID = PHInvalidImageRequestID
                self.videoCloudProgress = nil
                if let cancelled = info?[PHImageCancelledKey] as? Bool, cancelled { return }
                guard let item else { return }
                self.applyVideoItem(item, preservePlaybackState: false)
                self.requestNetworkHighQualityUpgrade(for: asset)
            }
        }
    }

    private func requestNetworkHighQualityUpgrade(for asset: PHAsset) {
        let id = asset.localIdentifier
        let opt = PHVideoRequestOptions()
        opt.isNetworkAccessAllowed = true
        opt.deliveryMode = .highQualityFormat
        opt.version = .current

        if currentVideoUpgradeRequestID != PHInvalidImageRequestID {
            imageManager.cancelImageRequest(currentVideoUpgradeRequestID)
            currentVideoUpgradeRequestID = PHInvalidImageRequestID
        }

        currentVideoUpgradeRequestID = imageManager.requestPlayerItem(forVideo: asset, options: opt) { item, info in
            DispatchQueue.main.async {
                guard self.currentVideoAssetID == id else { return }
                self.currentVideoUpgradeRequestID = PHInvalidImageRequestID
                if let cancelled = info?[PHImageCancelledKey] as? Bool, cancelled { return }
                guard let item else { return }
                self.applyVideoItem(item, preservePlaybackState: true)
            }
        }
    }

    private func applyVideoItem(_ item: AVPlayerItem, preservePlaybackState: Bool) {
        if let obs = videoEndObserver {
            NotificationCenter.default.removeObserver(obs)
            videoEndObserver = nil
        }

        let p: AVPlayer
        var resumeTime: CMTime = .zero
        var shouldResume = false

        if let existing = player {
            p = existing
            if preservePlaybackState, let current = existing.currentItem {
                resumeTime = current.currentTime()
                shouldResume = (existing.timeControlStatus == .playing)
            }
            p.replaceCurrentItem(with: item)
        } else {
            p = AVPlayer(playerItem: item)
            player = p
        }

        item.preferredForwardBufferDuration = 1.0
        p.isMuted = isMuted
        p.actionAtItemEnd = .pause
        p.automaticallyWaitsToMinimizeStalling = false

        if preservePlaybackState, resumeTime.isValid, resumeTime.seconds.isFinite, resumeTime.seconds > 0 {
            p.seek(to: resumeTime, toleranceBefore: .zero, toleranceAfter: .zero)
        }

        if shouldResume {
            if !isMuted {
                AudioSessionManager.beginVideoAudio()
            }
            p.play()
        } else {
            p.pause()
        }

        videoEndObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak p] _ in
            p?.pause()
            p?.seek(to: .zero)
            AudioSessionManager.endVideoAudio()
        }
    }

    private func cancelCurrentVideoRequests() {
        if currentVideoRequestID != PHInvalidImageRequestID {
            imageManager.cancelImageRequest(currentVideoRequestID)
            currentVideoRequestID = PHInvalidImageRequestID
        }
        if currentVideoUpgradeRequestID != PHInvalidImageRequestID {
            imageManager.cancelImageRequest(currentVideoUpgradeRequestID)
            currentVideoUpgradeRequestID = PHInvalidImageRequestID
        }
    }

    // MARK: - Stop All Media
    private func stopAllMedia() {
        AudioSessionManager.endVideoAudio()
        cancelCurrentVideoRequests()
        if livePhotoPreloadID != PHInvalidImageRequestID {
            PHImageManager.default().cancelImageRequest(livePhotoPreloadID)
            livePhotoPreloadID = PHInvalidImageRequestID
        }
        player?.pause()
        player = nil
        currentVideoAssetID = nil
        videoCloudProgress = nil

        isPlayingLivePhoto = false
        livePhoto = nil
        livePhotoAssetID = nil
        isLoadingLivePhoto = false
        pendingLivePlay = false

        isMuted = true

        if let obs = videoEndObserver {
            NotificationCenter.default.removeObserver(obs)
            videoEndObserver = nil
        }
    }

    // MARK: - Note
    func openNoteEditor() { showNoteEditor = true }

    var noteEditorOverlay: some View {
        ZStack {
            Color.black.opacity(0.3)
                .ignoresSafeArea()
                .onTapGesture { closeNoteEditor() }

            VStack(spacing: 0) {
                HStack {
                    Text("note.title".localized)
                        .font(.system(size: 18, weight: .semibold))
                    Spacer()
                    Button(action: closeNoteEditor) {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)

                Divider()

                TextEditor(text: $currentNote)
                    .font(.system(size: 15))
                    .lineSpacing(4)
                    .padding(12)
                    .focused($isNoteFocused)

                Divider()

                Button(action: saveNote) {
                    Text("note.save".localized)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(height: 48)
                        .frame(maxWidth: .infinity)
                }
                .background(Color.blue)
            }
            .background(Color(.systemBackground))
            .cornerRadius(16)
            .frame(height: 280)
            .padding(.horizontal, 24)
        }
        .onAppear { isNoteFocused = true }
    }

    func closeNoteEditor() {
        isNoteFocused = false
        showNoteEditor = false
        syncNoteForCurrent()
    }

    func saveNote() {
        guard let asset = activeCard?.asset else { return }
        upsertTag(assetID: asset.localIdentifier) { tag in
            tag.note = currentNote
        }
        closeNoteEditor()
    }

    func syncNoteForCurrent() {
        guard let asset = activeCard?.asset else { currentNote = ""; return }
        currentNote = effectiveNote(asset.localIdentifier) ?? ""
    }

    func hasNoteForCurrentAsset() -> Bool {
        guard let asset = activeCard?.asset else { return false }
        return effectiveNote(asset.localIdentifier)?.isEmpty == false
    }

    // MARK: - Share
    func shareCurrentAsset() {
        guard let asset = activeCard?.asset else { return }

        if asset.mediaType == .video {
            let opt = PHVideoRequestOptions()
            opt.isNetworkAccessAllowed = true
            PHImageManager.default().requestAVAsset(forVideo: asset, options: opt) { av, _, _ in
                guard let url = (av as? AVURLAsset)?.url else { return }
                DispatchQueue.main.async { presentShareSheet(items: [url]) }
            }
        } else {
            // 图片：弹出分享选项
            showShareOptions = true
        }
    }

    func presentShareSheet(items: [Any]) {
        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive })?
            .windows.first(where: { $0.isKeyWindow }) else { return }

        // Present from the top-most presented controller so the sheet isn't
        // swallowed by an overlay already on screen.
        var presenter = window.rootViewController
        while let presented = presenter?.presentedViewController {
            presenter = presented
        }
        guard let presenter else { return }

        let vc = UIActivityViewController(activityItems: items, applicationActivities: nil)
        // iPad requires a popover anchor; without it UIKit crashes on present.
        if let popover = vc.popoverPresentationController {
            popover.sourceView = window
            popover.sourceRect = CGRect(x: window.bounds.midX, y: window.bounds.midY, width: 1, height: 1)
            popover.permittedArrowDirections = []
        }
        presenter.present(vc, animated: true)
    }
    private var shareOptionsOverlay: some View {
        ZStack {
            Color.black.opacity(0.35)
                .ignoresSafeArea()
                .onTapGesture { showShareOptions = false }

            VStack(spacing: 12) {
                Button(action: shareOriginalImage) {
                    HStack {
                        Image(systemName: "photo")
                            .font(.system(size: 16))
                        Text("share.original".localized)
                            .font(.system(size: 16, weight: .semibold))
                        Spacer()
                    }
                    .foregroundColor(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .frame(height: 48)
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(12)
                }

                Button(action: shareImageWithNote) {
                    HStack {
                        Image(systemName: "note.text")
                            .font(.system(size: 16))
                        Text("share.with.note".localized)
                            .font(.system(size: 16, weight: .semibold))
                        Spacer()
                    }
                    .foregroundColor(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .frame(height: 48)
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(12)
                }

                Button(action: { showShareOptions = false }) {
                    Text("common.cancel".localized)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                        .background(Color(.secondarySystemBackground))
                        .cornerRadius(12)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            .background(Color(.systemBackground))
            .cornerRadius(16)
            .padding(.horizontal, 24)
        }
    }


    // MARK: - 添加预览弹窗（在 shareOptionsOverlay 后添加）

    private func previewOverlay(image: UIImage) -> some View {
        ZStack {
            Color.black.opacity(0.5)
                .ignoresSafeArea()
                .onTapGesture { showPreview = false }

            VStack(spacing: 20) {
                HStack {
                    Text("common.preview".localized)
                        .font(.system(size: 18, weight: .semibold))
                    Spacer()
                    Button(action: { showPreview = false }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)

                ScrollView {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .cornerRadius(12)
                }

                HStack(spacing: 12) {
                    Button(action: { showPreview = false }) {
                        Text("common.cancel".localized)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.primary)
                            .frame(maxWidth: .infinity)
                            .frame(height: 48)
                            .background(Color(.secondarySystemBackground))
                            .cornerRadius(12)
                    }

                    Button(action: {
                        showPreview = false
                        presentShareSheet(items: [image])
                    }) {
                        Text("common.share".localized)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 48)
                            .background(Color.blue)
                            .cornerRadius(12)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
            }
            .background(Color(.systemBackground))
            .cornerRadius(20)
            .padding(.horizontal, 16)
            .frame(maxHeight: .infinity, alignment: .center)
        }
    }


    // MARK: - 添加分享逻辑函数（在 presentShareSheet 函数后添加）

    private var sharePreparingOverlay: some View {
        ZStack {
            Color.black.opacity(0.25)
                .ignoresSafeArea()
            HStack(spacing: 10) {
                ProgressView()
                Text("share.preparing".localized)
                    .font(.subheadline)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        }
    }

    private func shareOriginalImage() {
        showShareOptions = false
        guard !isPreparingShareImage else { return }
        guard let asset = activeCard?.asset else { return }
        isPreparingShareImage = true

        requestOriginalImageData(for: asset) { data, dataUTI in
            DispatchQueue.global(qos: .userInitiated).async {
                // Write the untouched original bytes to a temp file so the share
                // sheet gets the real full-quality photo (incl. HEIC/metadata),
                // not the screen-sized card image.
                var item: Any?
                if let data {
                    let ext = dataUTI.flatMap { UTType($0)?.preferredFilenameExtension } ?? "jpg"
                    let url = FileManager.default.temporaryDirectory
                        .appendingPathComponent(UUID().uuidString)
                        .appendingPathExtension(ext)
                    if (try? data.write(to: url)) != nil {
                        item = url
                    } else {
                        item = UIImage(data: data)
                    }
                }
                DispatchQueue.main.async {
                    self.isPreparingShareImage = false
                    if let item {
                        self.presentShareSheet(items: [item])
                    } else if let fallback = self.activeCard?.image {
                        self.presentShareSheet(items: [fallback])
                    }
                }
            }
        }
    }

    private func shareImageWithNote() {
        showShareOptions = false
        guard !isPreparingShareImage else { return }
        guard let asset = activeCard?.asset else { return }

        let note = effectiveNote(asset.localIdentifier) ?? ""
        guard !note.isEmpty else {
            shareOriginalImage()
            return
        }

        isPreparingShareImage = true
        requestOriginalImageData(for: asset) { data, _ in
            DispatchQueue.global(qos: .userInitiated).async {
                // Compose from the full-quality original, capped at 4096px on the
                // long edge so the rendered bitmap can't blow up memory.
                let base = data.flatMap { UIImage(data: $0) }.map {
                    self.downscaledIfNeeded($0, maxDimension: 4096)
                }
                let composed = base.map { self.composeImageWithNote(image: $0, note: note) }
                DispatchQueue.main.async {
                    self.isPreparingShareImage = false
                    if let composed {
                        self.previewImage = composed
                        self.showPreview = true
                    } else if let fallback = self.activeCard?.image {
                        self.previewImage = self.composeImageWithNote(image: fallback, note: note)
                        self.showPreview = true
                    }
                }
            }
        }
    }

    /// Fetch the original photo data (network allowed, current version).
    private func requestOriginalImageData(for asset: PHAsset,
                                          completion: @escaping (Data?, String?) -> Void) {
        let opt = PHImageRequestOptions()
        opt.isNetworkAccessAllowed = true
        opt.deliveryMode = .highQualityFormat
        opt.version = .current
        PHImageManager.default().requestImageDataAndOrientation(for: asset, options: opt) { data, dataUTI, _, _ in
            completion(data, dataUTI)
        }
    }

    private func downscaledIfNeeded(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
        let pixelWidth = image.size.width * image.scale
        let pixelHeight = image.size.height * image.scale
        let longest = max(pixelWidth, pixelHeight)
        guard longest > maxDimension, longest > 0 else { return image }

        let ratio = maxDimension / longest
        let newSize = CGSize(width: floor(pixelWidth * ratio), height: floor(pixelHeight * ratio))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: newSize, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }

    private func composeImageWithNote(image: UIImage, note: String) -> UIImage {
        let imageSize = image.size
        let noteFont = UIFont.systemFont(ofSize: 28, weight: .semibold)
        let lineSpacing: CGFloat = 10
        let padding: CGFloat = 32
        let topBottomPadding: CGFloat = 36

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = lineSpacing
        paragraphStyle.alignment = .left
        
        let noteAttributes: [NSAttributedString.Key: Any] = [
            .font: noteFont,
            .foregroundColor: UIColor.black,
            .paragraphStyle: paragraphStyle
        ]

        let noteString = NSAttributedString(string: note, attributes: noteAttributes)
        let maxWidth = imageSize.width - padding * 2
        let textRect = noteString.boundingRect(
            with: CGSize(width: maxWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        )

        let bottomHeight = textRect.height + topBottomPadding * 2
        let totalHeight = imageSize.height + bottomHeight

        let rect = CGRect(x: 0, y: 0, width: imageSize.width, height: totalHeight)

        // Render at the source image's scale (1x for data-decoded originals) so a
        // 4096px base isn't multiplied by the 2-3x screen scale into a huge bitmap.
        UIGraphicsBeginImageContextWithOptions(rect.size, true, image.scale)
        defer { UIGraphicsEndImageContext() }

        UIColor(red: 0.97, green: 0.97, blue: 0.97, alpha: 1.0).setFill()
        UIRectFill(rect)

        image.draw(at: CGPoint(x: 0, y: 0))

        let bottomRect = CGRect(x: 0, y: imageSize.height, width: imageSize.width, height: bottomHeight)
        UIColor(red: 0.97, green: 0.97, blue: 0.97, alpha: 1.0).setFill()
        UIRectFill(bottomRect)

        noteString.draw(
            in: CGRect(
                x: padding,
                y: imageSize.height + topBottomPadding,
                width: maxWidth,
                height: textRect.height
            )
        )

        let composedImage = UIGraphicsGetImageFromCurrentImageContext() ?? UIImage()
        return composedImage
    }



    // MARK: - DB
    //
    // Tag edits made while swiping are accumulated here as DETACHED PhotoTag
    // scratch objects (created but never inserted into the context, so mutating
    // them dirties nothing). They're flushed to modelContext in ONE batch when
    // the user pauses / leaves / backgrounds. Writing the context on every swipe
    // dirties it and forces every live @Query (ContentView, LibraryView,
    // PhotoGridView — all alive behind Retro because you reached it through the
    // grid) to re-fetch and re-run their bodies on the main thread. That cascade
    // is the 250-500ms per-swipe stall we measured; batching collapses it to one
    // hit per pause/exit instead of one per swipe.
    private func effectiveNote(_ assetID: String) -> String? {
        if let pending = pendingTags[assetID] { return pending.note }
        return tagCache[assetID]?.note
    }

    func upsertTag(assetID: String, mutate: (PhotoTag) -> Void) {
        // Seed a detached scratch with the current effective state so a
        // status-only edit preserves the note (and vice-versa).
        let scratch: PhotoTag
        if let pending = pendingTags[assetID] {
            scratch = pending
        } else {
            scratch = PhotoTag(assetID: assetID, status: tagCache[assetID]?.status ?? "pending")
            scratch.note = tagCache[assetID]?.note
        }
        scratch.createdAt = Date()
        mutate(scratch)
        pendingTags[assetID] = scratch
        scheduleTagSave()
    }

    private func scheduleTagSave() {
        pendingTagSave?.cancel()
        let work = DispatchWorkItem {
            self.pendingTagSave = nil
            self.commitPendingTags()
        }
        pendingTagSave = work
        // Long debounce: a burst of swipes keeps rescheduling this, so the
        // context is only dirtied once the user genuinely pauses.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: work)
    }

    private func flushPendingTagSave() {
        pendingTagSave?.cancel()
        pendingTagSave = nil
        commitPendingTags()
    }

    /// Apply every accumulated edit to the context in one batch and save once.
    /// This is the only place Retro dirties the shared context.
    private func commitPendingTags() {
        guard !pendingTags.isEmpty else { return }
        for (id, scratch) in pendingTags {
            let tag: PhotoTag
            if let existing = tagCache[id] {
                tag = existing
            } else {
                tag = PhotoTag(assetID: id, status: scratch.status)
                modelContext.insert(tag)
            }
            tag.status = scratch.status
            tag.note = scratch.note
            tag.createdAt = scratch.createdAt
            tagCache[id] = tag
        }
        pendingTags.removeAll()
        try? modelContext.save()
    }
}

private struct RetroSnapshotCardView: View {
    let image: UIImage

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 20).fill(Color(.systemGray6))
            Image(uiImage: image)
                .resizable()
                .interpolation(.medium)
                .antialiased(true)
                .aspectRatio(contentMode: .fit)
                .padding(12)
        }
        .clipped()
        .shadow(color: .black.opacity(0.08), radius: 8)
    }
}
