import SwiftUI
import Photos
import PhotosUI
import SwiftData
import AVKit
import UIKit

// MARK: - Main View
struct RetroCleanView: View {

    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject var storeManager: StoreManager
    @EnvironmentObject var paywallGate: PaywallGate

    @Environment(\.dismiss) private var dismiss
    @Query(sort: \PhotoTag.createdAt, order: .reverse) private var allTags: [PhotoTag]

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
    @State private var assetOrderByID: [String: Int] = [:]

    // Live / Video
    @State private var livePhoto: PHLivePhoto?
    @State private var isPlayingLivePhoto = false
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

    // Zoom
    @State private var imageScale: CGFloat = 1.0
    @State private var zoomResetToken = UUID()
    private var isZooming: Bool { imageScale > 1.01 }

    private let cardWidth = UIScreen.main.bounds.width - 40
    private var cardHeight: CGFloat { (UIScreen.main.bounds.width - 40) * 4 / 3 }
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
    private var outDistanceX: CGFloat { 900 }
    private var outDistanceY: CGFloat { 1100 }

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
        activeCard?.asset.localIdentifier ?? buffer.first?.asset.localIdentifier ?? currentAssetID
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
        let cardW = UIScreen.main.bounds.width - cardHorizontalInset
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
        activeCard == nil && buffer.isEmpty && !shouldShowDoneState
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

                    if activeCard != nil || !buffer.isEmpty {
                        cardStackView
                            .padding(20)
                    }
                }
                .frame(height: cardStageHeight)
            }

            .safeAreaInset(edge: .bottom, spacing: 0) {
                bottomButtons
                    .padding(.horizontal, 18)
                    .padding(.vertical, 8)
                    .padding(.bottom, bottomButtonsLiftFromTab)
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
        }
        // Retro is pushed from a NavigationStack (Library). Hide the default navigation bar
        // so its extra top inset doesn't push the whole page down compared to ContentView.
        .toolbar(.hidden, for: .navigationBar)
        .onAppear {
            rebuildTagCache()
            refreshFilmstripSnapshot()
            bootstrapBuffer(force: true)
        }
        .onDisappear {
            stopAllMedia()
            cancelPendingImageRequests()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
            stopAllMedia()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
            stopAllMedia()
        }
        .onChange(of: activeCard?.asset.localIdentifier) { _, _ in
            stopAllMedia()
            resetImageZoom()
            syncNoteForCurrent()
            prepareMediaForCurrent()
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
                            hasNote: hasNoteForCurrentAsset()
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
                    .highPriorityGesture(isTop ? cardGesture() : nil)
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

            self.upsertTag(assetID: assetID) { tag in
                tag.status = status
                tag.createdAt = Date()
            }
            self.paywallGate.recordSwipeAndCheckIfNeedPaywall(isPremium: self.storeManager.hasUnlockedPremium)


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
                } else if let first = self.buffer.first {
                    // buffer 里没有精确匹配，用第一张
                    self.activeCard = first
                    self.currentAssetID = first.asset.localIdentifier
                    self.normalizeBuffer(excluding: first.asset.localIdentifier)
                    self.syncNoteForCurrent()
                    self.ensureBuffer()
                } else {
                    // buffer 空了，重新加载
                    self.activeCard = nil
                    self.bootstrapBuffer(force: true)
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
        guard !isZooming else { return }

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
            ActionButton(icon: "trash.fill", color: .red) {
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
        var map: [String: PhotoTag] = [:]
        map.reserveCapacity(allTags.count)
        for tag in allTags where map[tag.assetID] == nil {
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
            buffer.removeAll()
            loadingIDs.removeAll()
            activeCard = nil
            settleOffset = .zero
            isAnimatingOut = false
        }
        let revision = sourceRevision

        guard let currentIndex, assets.indices.contains(currentIndex) else { return }
        let currentAsset = assets[currentIndex]
        let id = currentAsset.localIdentifier

        loadingIDs.insert(id)

        cardImageRequestIDs[id] = loadCardState(for: currentAsset) { card in
            DispatchQueue.main.async {
                self.cardImageRequestIDs.removeValue(forKey: id)
                self.loadingIDs.remove(id)
                guard revision == self.sourceRevision else { return }

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

            cardImageRequestIDs[id] = loadCardState(for: asset) { card in
                DispatchQueue.main.async {
                    self.loadingIDs.remove(id)
                    guard revision == self.sourceRevision else { return }
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

                    if self.activeCard == nil {
                        self.activeCard = self.buffer.first
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

        cardImageRequestIDs[lastAssetID] = loadCardState(for: assets[lastIndex]) { restored in
            DispatchQueue.main.async {
                undoTimeout.cancel()
                self.cardImageRequestIDs.removeValue(forKey: lastAssetID)
                guard revision == self.sourceRevision else {
                    self.isUndoRestoring = false
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
    @discardableResult
    func loadCardState(for asset: PHAsset, completion: @escaping (CardState) -> Void) -> PHImageRequestID {
        let scale = UIScreen.main.scale
        let width = UIScreen.main.bounds.width - 40
        let height = width * 4 / 3
        let target = CGSize(width: width * scale, height: height * scale)

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
            guard let img else { return }
            completion(CardState(asset: asset, image: img))
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

        if isPlayingLivePhoto {
            isPlayingLivePhoto = false
            return
        }

        let opt = PHLivePhotoRequestOptions()
        opt.isNetworkAccessAllowed = true
        opt.deliveryMode = .opportunistic

        let scale = UIScreen.main.scale
        let targetSize = CGSize(width: UIScreen.main.bounds.width * scale,
                                height: UIScreen.main.bounds.height * scale)

        PHImageManager.default().requestLivePhoto(
            for: asset,
            targetSize: targetSize,
            contentMode: .aspectFit,
            options: opt
        ) { live, info in
            guard let live else { return }

            if let degraded = info?[PHLivePhotoInfoIsDegradedKey] as? Bool, degraded {
                return
            }

            DispatchQueue.main.async {
                self.livePhoto = live
                self.isPlayingLivePhoto = true
            }
        }
    }

    // MARK: - Video
    private func prepareMediaForCurrent() {
        guard let asset = activeCard?.asset else { return }
        if asset.mediaType == .video { loadVideo(for: asset) }
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
        player?.pause()
        player = nil
        currentVideoAssetID = nil
        videoCloudProgress = nil

        isPlayingLivePhoto = false
        livePhoto = nil

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
        currentNote = tagCache[asset.localIdentifier]?.note ?? ""
    }

    func hasNoteForCurrentAsset() -> Bool {
        guard let asset = activeCard?.asset else { return false }
        return tagCache[asset.localIdentifier]?.note?.isEmpty == false
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
        let vc = UIActivityViewController(activityItems: items, applicationActivities: nil)
        UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.windows.first?.rootViewController }
            .first?
            .present(vc, animated: true)
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

    private func shareOriginalImage() {
        showShareOptions = false
        guard let image = activeCard?.image else { return }
        presentShareSheet(items: [image])
    }

    private func shareImageWithNote() {
        showShareOptions = false
        guard let image = activeCard?.image,
              let assetID = activeCard?.asset.localIdentifier,
              let note = tagCache[assetID]?.note,
              !note.isEmpty else {
            presentShareSheet(items: [activeCard?.image ?? UIImage()])
            return
        }

        let composedImage = composeImageWithNote(image: image, note: note)
        previewImage = composedImage
        showPreview = true
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

        UIGraphicsBeginImageContextWithOptions(rect.size, true, 0)
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
    func upsertTag(assetID: String, mutate: (PhotoTag) -> Void) {
        let tag: PhotoTag
        if let existing = tagCache[assetID] {
            tag = existing
        } else {
            tag = PhotoTag(assetID: assetID, status: "pending")
            tag.createdAt = Date()
            modelContext.insert(tag)
        }
        mutate(tag)
        try? modelContext.save()
        tagCache[assetID] = tag
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
