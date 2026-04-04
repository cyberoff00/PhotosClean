import SwiftUI
import Photos
import SwiftData
import WidgetKit
import AVKit
import PhotosUI
import UIKit

// MARK: - ContentView
struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject var storeManager: StoreManager
    @EnvironmentObject var paywallGate: PaywallGate

    @Query(sort: \PhotoTag.createdAt, order: .reverse)
    private var allTags: [PhotoTag]

    // MARK: Buffer
    @State private var buffer: [CardState] = []
    @State private var loadingIDs: Set<String> = []
    private let preloadCount: Int = 6
    private let stackDisplayCount: Int = 3

    @State private var activeCard: CardState? = nil
    @State private var sessionProcessed: Set<String> = []
    @State private var undoStack: [String] = []
    @State private var isUndoRestoring = false
    @State private var sourceRevision: Int = 0
    @State private var cardImageRequestIDs: [String: PHImageRequestID] = [:]

    // MARK: Date source mode (Today / Random Date)
    enum DateSourceMode: Equatable {
        case today
        case random
    }

    enum TodayScope: Equatable {
        case day
        case week
        case month
    }

    @State private var dateSourceMode: DateSourceMode = .today
    @State private var todayScope: TodayScope = .day
    @State private var randomPickedDay: Date? = nil

    // MARK: Today/Day source (selected day + unmarked)
    @State private var todayAssets: [PHAsset] = []
    @State private var todayCursor: Int = 0
    @State private var todayOrderByID: [String: Int] = [:]


    // MARK: Tag cache (关键：O(1) lookup)
    @State private var tagCache: [String: PhotoTag] = [:]

    // MARK: Header counts cache（避免 body 里每帧 filter allTags）
    @State private var redCount: Int = 0

    // MARK: Widget count cache
    @State private var todayPendingCount: Int = 0
    @State private var widgetReloadTask: Task<Void, Never>?
    @State private var isSourceLoading = false
    @State private var sourceLoadToken: Int = 0
    @State private var isPickingRandomDay = false
    @State private var randomPickToken: Int = 0
    private let groupID = "group.com.claire.TastyTidy"

    // MARK: Gesture
    @GestureState private var dragOffset: CGSize = .zero
    @State private var settleOffset: CGSize = .zero
    @State private var isAnimatingOut = false

    // MARK: Media
    @State private var livePhoto: PHLivePhoto?
    @State private var isPlayingLivePhoto = false
    @State private var player: AVPlayer?
    @State private var isMuted = true
    @State private var currentVideoAssetID: String? = nil
    @State private var currentVideoRequestID: PHImageRequestID = PHInvalidImageRequestID
    @State private var currentVideoUpgradeRequestID: PHImageRequestID = PHInvalidImageRequestID
    @State private var videoEndObserver: NSObjectProtocol?
    @State private var videoCloudProgress: Double? = nil

    // MARK: Zoom (outer decides swipe disable)
    @State private var zoomScale: CGFloat = 1.0
    @State private var zoomResetToken = UUID()
    private var isZoomingImage: Bool { zoomScale > 1.01 }

    // MARK: Note
    @State private var showNoteEditor = false
    @State private var currentNote = ""
    @FocusState private var isNoteFocused: Bool
    
    //share
    
    @State private var showShareOptions = false
    @State private var showPreview = false
    @State private var previewImage: UIImage?

    // MARK: UI layout
    private let cardWidth = UIScreen.main.bounds.width - 40
    private var cardHeight: CGFloat { (UIScreen.main.bounds.width - 40) * 4 / 3 }

    // Swipe config
    private var swipeThresholdX: CGFloat { 120 }
    private var swipeThresholdY: CGFloat { 120 }
    private var outDistanceX: CGFloat { 900 }
    private var outDistanceY: CGFloat { 1100 }

    private var currentCardOffset: CGSize {
        CGSize(width: dragOffset.width + settleOffset.width,
               height: dragOffset.height + settleOffset.height)
    }
    private var rotationDeg: Double { Double(currentCardOffset.width / 18) }
    private var isDragging: Bool { dragOffset != .zero }
    private var isHeavyPhase: Bool { isDragging || isAnimatingOut }

    // Hint overlay during dragging (existing)
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
    private var filmstripAssets: [PHAsset] {
        filmstripSnapshot
    }
    @State private var filmstripSnapshot: [PHAsset] = []

    private func jump(to asset: PHAsset) {
        let id = asset.localIdentifier
        guard activeCard?.asset.localIdentifier != id else { return }
        guard let selectedIndex = todayAssets.firstIndex(where: { $0.localIdentifier == id }) else { return }
        sourceRevision += 1
        let revision = sourceRevision

        cancelPendingImageRequests()
        stopAllMedia()
        resetImageZoom()

        buffer.removeAll()
        loadingIDs.removeAll()
        settleOffset = .zero
        isAnimatingOut = false

        // 让 ensureBuffer 从选中位置后继续装填
        todayCursor = selectedIndex + 1
        activeCard = nil

        loadingIDs.insert(id)
        cardImageRequestIDs[id] = loadCardState(for: asset) { card in
            DispatchQueue.main.async {
                self.cardImageRequestIDs.removeValue(forKey: id)
                self.loadingIDs.remove(id)
                guard revision == self.sourceRevision else { return }
                self.activeCard = card
                self.syncNoteForCurrent()
                self.prepareMediaForCurrent()
                self.ensureBuffer()
                self.refreshFilmstripSnapshot()
            }
        }
    }


    private let imageManager = PHCachingImageManager()

    // MARK: - NEW: lightweight animated coach hints (non-blocking)
    @AppStorage("hint_today_banner_seen") private var hintTodayBannerSeen = false
    @AppStorage("hint_today_empty_seen") private var hintTodayEmptySeen = false
    @AppStorage("hint_today_gesture_seen") private var hintTodayGestureSeen = false

    @State private var showTopBanner: Bool = false
    @State private var bannerTextKey: LocalizedStringKey = "hint.banner.today"

    private var hasTodayCards: Bool {
        activeCard != nil || !buffer.isEmpty || !loadingIDs.isEmpty
    }

    private var shouldShowStageEmptyState: Bool {
        !isSourceLoading && activeCard == nil && buffer.isEmpty && loadingIDs.isEmpty
    }

    /// True when a free user has used up today's quota
    private var quotaExhaustedForFreeUser: Bool {
        !storeManager.hasUnlockedPremium && paywallGate.isQuotaExhausted
    }

    private var shouldShowRandomContinueState: Bool {
        shouldShowStageEmptyState && dateSourceMode == .random
    }

    private var shouldShowStageLoadingState: Bool {
        isSourceLoading || (activeCard == nil && buffer.isEmpty && !loadingIDs.isEmpty)
    }

    private var shouldShowGestureHint: Bool {
        // 只在有卡片时出现
        if !hasTodayCards { return false }
        // 已展示过就不再出现
        if hintTodayGestureSeen { return false }
        // 手势中/动画中/放大中不出现
        if isAnimatingOut || isDragging || isZoomingImage { return false }
        // note editor 弹出中不出现
        if showNoteEditor { return false }
        return true
    }

    private var currentDisplayedAssetID: String? {
        activeCard?.asset.localIdentifier ?? buffer.first?.asset.localIdentifier
    }

    // MARK: - Stable layout metrics
    // Keep the card + filmstrip stage sizes constant so switching Random / tapping previews
    // only swaps the media, without the rest of the page jumping.
    private let cardHorizontalInset: CGFloat = 56
    private let bottomButtonsLiftFromTab: CGFloat = 58

    private var cardStageHeight: CGFloat {
        let cardW = UIScreen.main.bounds.width - cardHorizontalInset
        let cardH = cardW * 4 / 3
        // cardStackView uses .padding(20)
        return cardH + 40
    }

    // 32pt thumbnails + small vertical padding.
    private let filmstripStageHeight: CGFloat = 46
    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()

            VStack(spacing: 0) {
                // Header belongs to the safe area and should not be pushed around by
                // photo switching / loading.
                headerView
                    .padding(.horizontal, 16)
                    .padding(.top, 42)
                    .padding(.bottom, 10)

                // ✅ NEW: top lightweight banner (auto dismiss)
                if showTopBanner {
                    Text(bannerTextKey)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity)
                        .transition(.opacity)
                }

                // Filmstrip sits ABOVE the card, close to it, so it feels like a direct
                // control for the current photo (and doesn't fight with bottom actions).
                FilmstripView(assets: filmstripAssets,
                             selectedID: currentDisplayedAssetID,
                             onSelect: jump)
                    .padding(.horizontal, 12)
                    .padding(.top, 4)
                    .padding(.bottom, -2)
                    .frame(height: filmstripStageHeight)
                    .opacity(activeCard == nil ? 0 : 1)
                    .allowsHitTesting(activeCard != nil)

                // Fixed-height stage: only the media changes, the surrounding layout stays put.
                ZStack {
                    ContentUnavailableView(
                        "empty.title".localized,
                        systemImage: "sparkles",
                        description: Text("empty.description".localized)
                    )
                    .opacity(shouldShowStageEmptyState && !shouldShowRandomContinueState ? 1 : 0)

                    ProgressView()
                        .opacity(shouldShowStageLoadingState ? 1 : 0)

                    if activeCard != nil || !buffer.isEmpty {
                        cardStackView
                            .padding(20)
                    }

                    if shouldShowRandomContinueState {
                        randomContinueEmptyState
                    }

                    // Inline quota upgrade card (hard wall for free users)
                    if quotaExhaustedForFreeUser && !shouldShowStageEmptyState {
                        quotaUpgradeCard
                            .transition(.opacity)
                    }
                }
                .frame(height: cardStageHeight)
                .overlay(alignment: .center) {
                    // ✅ NEW: non-blocking gesture animation hint
                    if shouldShowGestureHint {
                        TodayGestureHintView()
                            .allowsHitTesting(false)
                            .transition(.opacity)
                    }
                }
            }

            // Bottom action buttons should never cover the tab bar.
            // Using a safe-area inset keeps layout stable and user-friendly.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                bottomButtons
                    .padding(.horizontal, 18)
                    .padding(.vertical, 4)
                    .padding(.bottom, bottomButtonsLiftFromTab)
            }

            if showNoteEditor { noteEditorOverlay }
            if showShareOptions {
                shareOptionsOverlay
            }

            if showPreview, let preview = previewImage {
                previewOverlay(image: preview)
            }
        }
        .onAppear {
            buildTagCacheOnce()
            rebuildCurrentSource {
                recalcTodayPendingCountFast()
                bootstrapBuffer(force: true)
                refreshFilmstripSnapshot()
                presentTopBannerIfNeeded()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("ReloadPhotos"))) { _ in
            refreshCurrentSourcePreservingSelection(showBanner: true)
        }
        // When the app resigns active / goes to background, release audio focus so other apps can resume.
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
            refreshFilmstripSnapshot()
        }
        .onDisappear {
            stopAllMedia()
            cancelPendingImageRequests()
        }

    }

    // MARK: - NEW: banner logic
    private func presentTopBannerIfNeeded() {
        guard !isSourceLoading else { return }
        // 今天没有待处理：只提示一次
        if todayPendingCount == 0 || !hasTodayCards {
            if !hintTodayEmptySeen {
                hintTodayEmptySeen = true
                bannerTextKey = "hint.banner.today.empty"
                showBannerFor(seconds: 3)
            }
            return
        }

        // 今天有待处理：只提示一次
        if !hintTodayBannerSeen {
            hintTodayBannerSeen = true
            bannerTextKey = "hint.banner.today"
            showBannerFor(seconds: 3)
        }
    }

    private func showBannerFor(seconds: Double) {
        withAnimation(.easeOut(duration: 0.2)) { showTopBanner = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            withAnimation(.easeOut(duration: 0.2)) { showTopBanner = false }
        }
    }

    // MARK: - Stack
    private var visibleStackCards: [CardState] {
        let merged = ([activeCard].compactMap { $0 } + buffer)
        var seen: Set<String> = []
        var unique: [CardState] = []
        unique.reserveCapacity(merged.count)

        for card in merged {
            let id = card.asset.localIdentifier
            if seen.insert(id).inserted {
                unique.append(card)
            }
        }
        return unique
    }

    private var cardStackView: some View {
        return ZStack {
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
                            zoomScale: $zoomScale,
                            zoomResetToken: zoomResetToken,
                            player: $player,
                            isMuted: $isMuted,
                            videoCloudProgress: videoCloudProgress,
                            isDragging: isDragging,
                            isAnimatingOut: isAnimatingOut,
                            onLoadVideo: { loadVideo(for: card.asset) },
                            onToggleLive: toggleLivePhoto,
                            onShare: shareCurrentAsset,
                            onOpenNote: openNoteEditor,
                            hasNote: hasNoteForCurrentAsset(),
                            onEdgeSwipe: { _ in resetImageZoom() }
                        )
                    } else {
                        SnapshotCardView(image: card.image)
                            .frame(width: cardWidth, height: cardHeight)
                    }
                }
                .offset(x: isTop ? currentCardOffset.width : 0,
                        y: isTop ? currentCardOffset.height : 0)
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
                guard !isAnimatingOut else { return }
                guard !isZoomingImage else { return }
                state = value.translation
            }
            .onChanged { _ in
                if settleOffset != .zero { settleOffset = .zero }
            }
            .onEnded { value in
                guard !isAnimatingOut else { return }

                guard !isZoomingImage else {
                    bounceBack(from: value.translation)
                    return
                }

                let t = value.translation
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
            // ✅ NEW: once user performs any swipe, mark gesture hint as seen
            self.hintTodayGestureSeen = true

            self.undoStack.append(assetID)
            self.sessionProcessed.insert(assetID)

            self.upsertTag(assetID: assetID) { tag in
                tag.status = status
                tag.createdAt = Date()
            }

            // daily quota gate
            self.paywallGate.recordSwipe(isPremium: self.storeManager.hasUnlockedPremium)

            if self.todayPendingCount > 0 {
                self.todayPendingCount -= 1
                self.writeWidgetCountDebounced(self.todayPendingCount)
            }

            self.stopAllMedia()
            self.resetImageZoom()

            var tx = Transaction()
            tx.disablesAnimations = true
            withTransaction(tx) {
                self.settleOffset = .zero

                if !self.buffer.isEmpty {
                    self.activeCard = self.buffer.removeFirst()
                } else {
                    self.activeCard = nil
                }

                self.syncNoteForCurrent()
                self.ensureBuffer()
                self.isAnimatingOut = false
            }
        }
    }

    // MARK: - Header
    private var headerView: some View {

        // Keep a normal product header (brand/title), and place Today/Random a bit lower.
        return VStack(alignment: .leading, spacing: 8) {
            Text("header.title".localized)
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(.primary)

            HStack(spacing: 12) {
                HStack(spacing: 8) {
                    Menu {
                        Button("filter.today".localized) {
                            activateTodayScope(.day)
                        }
                        Button("filter.week".localized) {
                            activateTodayScope(.week)
                        }
                        Button("filter.month".localized) {
                            activateTodayScope(.month)
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Text(currentTodayScopeLabel.localized)
                            Image(systemName: "chevron.down")
                                .font(.system(size: 10, weight: .semibold))
                        }
                        .font(.caption.weight(.semibold))
                        .foregroundColor(dateSourceMode == .today ? .white : .primary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(dateSourceMode == .today ? Color.blue : Color.secondary.opacity(0.12))
                        .clipShape(Capsule())
                    }

                    Button(action: randomButtonTapped) {
                        HStack(spacing: 6) {
                            if isPickingRandomDay {
                                ProgressView()
                                    .controlSize(.mini)
                            } else {
                                Image(systemName: "shuffle")
                                    .font(.caption.weight(.semibold))
                            }
                            Text(randomButtonLabel)
                                .font(.caption.weight(.semibold))
                                .lineLimit(1)
                        }
                        .foregroundColor(dateSourceMode == .random ? .white : .primary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(dateSourceMode == .random ? Color.blue : Color.secondary.opacity(0.12))
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(isPickingRandomDay)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // Daily quota indicator (free users only)
                if !storeManager.hasUnlockedPremium {
                    HStack(spacing: 4) {
                        Text("\(paywallGate.usedToday)/\(paywallGate.dailyFreeLimit)")
                            .font(.caption2.weight(.semibold).monospacedDigit())
                        Image(systemName: "sparkles")
                            .font(.system(size: 9, weight: .semibold))
                    }
                    .foregroundColor(paywallGate.isQuotaExhausted ? .orange : .secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        paywallGate.isQuotaExhausted
                            ? Color.orange.opacity(0.12)
                            : Color.secondary.opacity(0.10)
                    )
                    .clipShape(Capsule())
                }

                Button(action: undoLastAction) {
                    Image(systemName: "arrow.uturn.backward.circle.fill")
                        .font(.title2)
                        .frame(width: 44, height: 44)
                }
                .opacity(undoStack.isEmpty ? 0 : 1)
                .disabled(undoStack.isEmpty || isAnimatingOut || isUndoRestoring)
            }
            .padding(.top, 2)
        }
        .transaction { $0.animation = nil }
    }

    private var currentTodayScopeLabel: String {
        switch todayScope {
        case .day:
            return "filter.today"
        case .week:
            return "filter.week"
        case .month:
            return "filter.month"
        }
    }

    // MARK: - Bottom Buttons
    private func triggerButtonSwipe(status: String) {
        guard !isAnimatingOut else { return }
        guard !isUndoRestoring else { return }
        guard activeCard != nil else { return }
        guard !isZoomingImage else { return }

        // ✅ NEW: using buttons also counts as "user learned gestures"
        hintTodayGestureSeen = true

        let from: CGSize
        switch status {
        case "delete": from = CGSize(width: -140, height: 0)
        case "keep":   from = CGSize(width: 140, height: 0)
        default:       from = CGSize(width: 0, height: -140)
        }

        let predicted = CGSize(width: from.width * 6, height: from.height * 3)
        commitSwipeAndAdvance(status: status, from: from, predicted: predicted)
    }

    private var bottomButtons: some View {
        HStack(spacing: 40) {
            ActionButton(icon: "trash.fill", color: .red) { triggerButtonSwipe(status: "delete") }
            ActionButton(icon: "clock.fill", color: .yellow) { triggerButtonSwipe(status: "maybe") }
            ActionButton(icon: "heart.fill", color: .green) { triggerButtonSwipe(status: "keep") }
        }
    }

    // MARK: - Bootstrap / Today source
    private func bootstrapBuffer(force: Bool) {
        if force {
            sourceRevision += 1
            cancelPendingImageRequests()
            stopAllMedia()
            buffer.removeAll()
            loadingIDs.removeAll()
            activeCard = nil
            settleOffset = .zero
            todayCursor = 0
        }

        let revision = sourceRevision
        guard activeCard == nil, buffer.isEmpty else {
            ensureBuffer()
            return
        }

        guard let firstIndex = todayAssets.indices.first(where: { isUnmarkedTodayAsset(todayAssets[$0]) }) else {
            ensureBuffer()
            return
        }

        let firstAsset = todayAssets[firstIndex]
        let id = firstAsset.localIdentifier
        todayCursor = firstIndex + 1
        loadingIDs.insert(id)

        cardImageRequestIDs[id] = loadCardState(for: firstAsset) { card in
            DispatchQueue.main.async {
                self.cardImageRequestIDs.removeValue(forKey: id)
                self.loadingIDs.remove(id)
                guard revision == self.sourceRevision else { return }
                self.activeCard = card
                self.syncNoteForCurrent()
                self.prepareMediaForCurrent()
                self.refreshFilmstripSnapshot()
                self.ensureBuffer()
            }
        }
    }

    private var selectedSourceInterval: DateInterval {
        let calendar = Calendar.current
        switch dateSourceMode {
        case .today:
            return interval(for: todayScope, referenceDate: Date(), calendar: calendar)
        case .random:
            let day = randomPickedDay ?? Date()
            let start = calendar.startOfDay(for: day)
            let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(24 * 3600)
            return DateInterval(start: start, end: end)
        }
    }

    private func interval(for scope: TodayScope, referenceDate: Date, calendar: Calendar) -> DateInterval {
        switch scope {
        case .day:
            let start = calendar.startOfDay(for: referenceDate)
            let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(24 * 3600)
            return DateInterval(start: start, end: end)
        case .week:
            let week = calendar.dateInterval(of: .weekOfYear, for: referenceDate)
            return week ?? interval(for: .day, referenceDate: referenceDate, calendar: calendar)
        case .month:
            let month = calendar.dateInterval(of: .month, for: referenceDate)
            return month ?? interval(for: .day, referenceDate: referenceDate, calendar: calendar)
        }
    }

    private func rebuildCurrentSource(completion: (() -> Void)? = nil) {
        rebuildSource(for: selectedSourceInterval, completion: completion)
    }

    private func refreshCurrentSourcePreservingSelection(showBanner: Bool = false) {
        let currentID = activeCard?.asset.localIdentifier

        rebuildCurrentSource {
            recalcTodayPendingCountFast()

            guard let currentID else {
                bootstrapBuffer(force: true)
                if showBanner { presentTopBannerIfNeeded() }
                return
            }

            let availableIDs = Set(todayAssets.map(\.localIdentifier))
            guard availableIDs.contains(currentID) else {
                bootstrapBuffer(force: true)
                if showBanner { presentTopBannerIfNeeded() }
                return
            }

            // Keep current card stable; only realign buffer/loading to new source snapshot.
            buffer.removeAll { card in
                let id = card.asset.localIdentifier
                if id == currentID { return true }
                if !availableIDs.contains(id) { return true }
                return !isUnmarkedTodayAsset(card.asset)
            }
            buffer.sort {
                (todayOrderByID[$0.asset.localIdentifier] ?? Int.max) <
                (todayOrderByID[$1.asset.localIdentifier] ?? Int.max)
            }
            loadingIDs = Set(loadingIDs.filter { availableIDs.contains($0) && $0 != currentID })

            if let index = todayAssets.firstIndex(where: { $0.localIdentifier == currentID }) {
                todayCursor = index + 1
            } else {
                todayCursor = 0
            }
            ensureBuffer()
            refreshFilmstripSnapshot()
            if showBanner { presentTopBannerIfNeeded() }
        }
    }

    private func rebuildSource(for interval: DateInterval, completion: (() -> Void)? = nil) {
        sourceLoadToken += 1
        let token = sourceLoadToken
        isSourceLoading = true
        let start = interval.start
        let end = interval.end

        // PHAsset fetch 移到后台线程，避免阻塞主线程
        DispatchQueue.global(qos: .userInitiated).async {
            let options = PHFetchOptions()
            options.predicate = NSPredicate(format: "creationDate >= %@ AND creationDate < %@", start as NSDate, end as NSDate)
            options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]

            let results = PHAsset.fetchAssets(with: options)
            var arr: [PHAsset] = []
            arr.reserveCapacity(results.count)
            results.enumerateObjects { a, _, _ in arr.append(a) }

            var orderMap: [String: Int] = [:]
            orderMap.reserveCapacity(arr.count)
            for (idx, asset) in arr.enumerated() where orderMap[asset.localIdentifier] == nil {
                orderMap[asset.localIdentifier] = idx
            }

            DispatchQueue.main.async {
                guard token == self.sourceLoadToken else { return }
                self.todayAssets = arr
                self.todayOrderByID = orderMap
                self.todayCursor = 0
                self.refreshFilmstripSnapshot()
                self.isSourceLoading = false
                completion?()
            }
        }
    }

    private func fetchLibraryDateBounds() -> (oldest: Date, newest: Date)? {
        let oldestOpt = PHFetchOptions()
        oldestOpt.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        oldestOpt.fetchLimit = 1
        let oldestRes = PHAsset.fetchAssets(with: oldestOpt)
        guard let oldestAsset = oldestRes.firstObject, let oldestDate = oldestAsset.creationDate else { return nil }

        let newestOpt = PHFetchOptions()
        newestOpt.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        newestOpt.fetchLimit = 1
        let newestRes = PHAsset.fetchAssets(with: newestOpt)
        guard let newestAsset = newestRes.firstObject, let newestDate = newestAsset.creationDate else { return nil }

        return (oldest: oldestDate, newest: newestDate)
    }

    private func pickRandomDayWithPhotos(completion: @escaping (Date) -> Void) {
        // Snapshot current pending status on main thread, then use it in background.
        let nonPendingIDs = Set(allTags.compactMap { tag in
            tag.status == "pending" ? nil : tag.assetID
        })
        let sessionProcessedIDs = sessionProcessed

        // 整个随机选日逻辑移到后台线程，避免阻塞 UI
        DispatchQueue.global(qos: .userInitiated).async {
            guard let bounds = self.fetchLibraryDateBounds() else {
                DispatchQueue.main.async {
                    completion(self.randomPickedDay ?? Calendar.current.startOfDay(for: Date()))
                }
                return
            }

            let calendar = Calendar.current
            let todayStart = calendar.startOfDay(for: Date())
            let hasMultipleDays = calendar.startOfDay(for: bounds.oldest) != calendar.startOfDay(for: bounds.newest)

            let allOpt = PHFetchOptions()
            allOpt.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            let all = PHAsset.fetchAssets(with: allOpt)

            guard all.count > 0 else {
                DispatchQueue.main.async { completion(todayStart) }
                return
            }

            var anyDays: Set<Date> = []
            var pendingDays: Set<Date> = []

            all.enumerateObjects { asset, _, _ in
                guard let d = asset.creationDate else { return }
                let candidateDay = calendar.startOfDay(for: d)
                if hasMultipleDays && candidateDay == todayStart { return }

                anyDays.insert(candidateDay)

                let id = asset.localIdentifier
                if sessionProcessedIDs.contains(id) { return }
                if nonPendingIDs.contains(id) { return }
                pendingDays.insert(candidateDay)
            }

            let picked = (pendingDays.isEmpty ? nil : Array(pendingDays).randomElement())
                ?? (anyDays.isEmpty ? nil : Array(anyDays).randomElement())
            let finalDay = picked ?? calendar.startOfDay(for: bounds.newest)

            DispatchQueue.main.async {
                completion(finalDay)
            }
        }
    }

    private func switchToToday() {
        guard dateSourceMode != .today else { return }
        randomPickToken += 1
        isPickingRandomDay = false
        dateSourceMode = .today
        randomPickedDay = nil
        rebuildCurrentSource {
            recalcTodayPendingCountFast()
            bootstrapBuffer(force: true)
            presentTopBannerIfNeeded()
        }
    }

    private func activateTodayScope(_ scope: TodayScope) {
        if dateSourceMode != .today {
            dateSourceMode = .today
            randomPickedDay = nil
        }
        switchTodayScope(scope)
    }

    private func switchTodayScope(_ scope: TodayScope) {
        guard todayScope != scope else { return }
        todayScope = scope
        rebuildCurrentSource {
            recalcTodayPendingCountFast()
            bootstrapBuffer(force: true)
            presentTopBannerIfNeeded()
        }
    }

    private func randomButtonTapped() {
        guard !isPickingRandomDay else { return }
        randomPickToken += 1
        let token = randomPickToken
        isPickingRandomDay = true

        if dateSourceMode != .random {
            dateSourceMode = .random
        }
        pickRandomDayWithPhotos { day in
            guard token == randomPickToken else { return }
            isPickingRandomDay = false
            randomPickedDay = day
            let interval = interval(for: .day, referenceDate: day, calendar: Calendar.current)
            rebuildSource(for: interval) {
                guard token == randomPickToken else { return }
                recalcTodayPendingCountFast()
                bootstrapBuffer(force: true)
                presentTopBannerIfNeeded()
            }
        }
    }

    private func formattedDay(_ day: Date) -> String {
        let df = DateFormatter()
        df.locale = .current
        df.dateStyle = .medium
        df.timeStyle = .none
        return df.string(from: day)
    }

    private var randomButtonLabel: String {
        if let d = randomPickedDay {
            return "filter.random_date".localized(with: formattedDay(d))
        }
        return "filter.random".localized
    }

    private var randomContinueEmptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "shuffle")
                .font(.system(size: 28, weight: .semibold))
                .foregroundColor(.blue)

            Text("random.empty.title".localized)
                .font(.headline)

            Text("random.empty.description".localized)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            Button(action: randomButtonTapped) {
                HStack(spacing: 8) {
                    if isPickingRandomDay {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "sparkles")
                    }
                    Text("random.empty.cta".localized)
                        .font(.headline)
                }
                .foregroundColor(.white)
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .background(Color.blue)
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(isPickingRandomDay)
        }
        .padding(.horizontal, 24)
    }

    private func isUnmarkedTodayAsset(_ asset: PHAsset) -> Bool {
        let id = asset.localIdentifier
        if sessionProcessed.contains(id) { return false }
        if let t = tagCache[id], t.status != "pending" { return false }
        return true
    }

    private func insertBufferInTodayOrder(_ card: CardState) {
        let newID = card.asset.localIdentifier
        let newOrder = todayOrderByID[newID] ?? Int.max
        let insertAt = buffer.firstIndex { existing in
            let order = todayOrderByID[existing.asset.localIdentifier] ?? Int.max
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

    private func ensureBuffer() {
        let revision = sourceRevision

        func loadedCount() -> Int {
            (activeCard == nil ? 0 : 1) + buffer.count + loadingIDs.count
        }

        while loadedCount() < preloadCount, todayCursor < todayAssets.count {
            let asset = todayAssets[todayCursor]
            todayCursor += 1

            guard isUnmarkedTodayAsset(asset) else { continue }

            let id = asset.localIdentifier
            if loadingIDs.contains(id) { continue }
            if activeCard?.asset.localIdentifier == id { continue }
            if buffer.contains(where: { $0.asset.localIdentifier == id }) { continue }

            loadingIDs.insert(id)

            cardImageRequestIDs[id] = loadCardState(for: asset) { card in
                DispatchQueue.main.async {
                    self.loadingIDs.remove(id)
                    guard revision == self.sourceRevision else { return }

                    // Upgrade path: if card already exists (degraded delivered earlier), update its image
                    if self.activeCard?.asset.localIdentifier == id {
                        self.activeCard = card
                        return
                    }
                    if let idx = self.buffer.firstIndex(where: { $0.asset.localIdentifier == id }) {
                        self.buffer[idx] = card
                        return
                    }

                    self.insertBufferInTodayOrder(card)

                    if self.activeCard == nil, !self.buffer.isEmpty {
                        self.activeCard = self.buffer.removeFirst()
                        self.syncNoteForCurrent()
                        self.prepareMediaForCurrent()
                        self.refreshFilmstripSnapshot()
                    }
                }
            }
        }
    }

    // MARK: - Image Loading
    @discardableResult
    private func loadCardState(for asset: PHAsset, completion: @escaping (CardState) -> Void) -> PHImageRequestID {
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

    // MARK: - Tag cache init + counts
    private func buildTagCacheOnce() {
        var map: [String: PhotoTag] = [:]
        map.reserveCapacity(allTags.count)
        for tag in allTags where map[tag.assetID] == nil {
            map[tag.assetID] = tag
        }
        tagCache = map
        redCount = tagCache.values.reduce(0) { $0 + ($1.status == "delete" ? 1 : 0) }
    }

    // MARK: - Widget count
    private func recalcTodayPendingCountFast() {
        todayPendingCount = todayAssets.reduce(0) { acc, a in
            let id = a.localIdentifier
            if sessionProcessed.contains(id) { return acc }
            if let t = tagCache[id], t.status != "pending" { return acc }
            return acc + 1
        }
        writeWidgetCountDebounced(todayPendingCount)
    }

    private func writeWidgetCountDebounced(_ count: Int) {
        if let defaults = UserDefaults(suiteName: groupID) {
            defaults.set(count, forKey: "finalDisplayCount")
        }

        widgetReloadTask?.cancel()
        widgetReloadTask = Task {
            try? await Task.sleep(nanoseconds: 400_000_000)
            await MainActor.run {
                WidgetCenter.shared.reloadAllTimelines()
            }
        }
    }

    // MARK: - UpsertTag
    private func upsertTag(assetID: String, update: (PhotoTag) -> Void) {
        let tag: PhotoTag
        if let existing = tagCache[assetID] {
            tag = existing
        } else {
            tag = PhotoTag(assetID: assetID, status: "pending")
            modelContext.insert(tag)
        }

        let oldStatus = tag.status
        let oldCreatedAt = tag.createdAt

        update(tag)
        try? modelContext.save()
        tagCache[assetID] = tag

        if oldStatus != "delete" && tag.status == "delete" { redCount += 1 }
        if oldStatus == "delete" && tag.status != "delete" { redCount = max(0, redCount - 1) }
    }

    // MARK: - Media helpers
    private func prepareMediaForCurrent() {
        guard let asset = activeCard?.asset else { return }
        if asset.mediaType == .video { loadVideo(for: asset) }
    }

    private func stopAllMedia() {
        // Release audio focus so external audio (e.g., Music/Podcast) can resume.
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

    private func loadVideo(for asset: PHAsset) {
        if currentVideoAssetID == asset.localIdentifier, player != nil { return }
        currentVideoAssetID = asset.localIdentifier
        videoCloudProgress = nil
        cancelCurrentVideoRequests()

        let id = asset.localIdentifier
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

    private func refreshFilmstripSnapshot() {
        guard !todayAssets.isEmpty else {
            filmstripSnapshot = []
            return
        }
        let activeID = activeCard?.asset.localIdentifier
        let centerIndex = todayAssets.firstIndex { $0.localIdentifier == activeID }
            ?? todayAssets.firstIndex(where: { isUnmarkedTodayAsset($0) })
            ?? 0

        var result: [PHAsset] = []
        result.reserveCapacity(41)

        if centerIndex < todayAssets.count {
            let centerAsset = todayAssets[centerIndex]
            if activeID == centerAsset.localIdentifier || isUnmarkedTodayAsset(centerAsset) {
                result.append(centerAsset)
            }
        }

        var left = centerIndex - 1
        var right = centerIndex + 1
        while (left >= 0 || right < todayAssets.count) && result.count < 41 {
            if right < todayAssets.count {
                let a = todayAssets[right]
                if activeID == a.localIdentifier || isUnmarkedTodayAsset(a) {
                    result.append(a)
                }
                right += 1
            }
            if result.count >= 41 { break }
            if left >= 0 {
                let a = todayAssets[left]
                if activeID == a.localIdentifier || isUnmarkedTodayAsset(a) {
                    result.insert(a, at: 0)
                }
                left -= 1
            }
        }

        filmstripSnapshot = result
    }

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

    // MARK: - Share
    private func shareCurrentAsset() {
        guard let asset = activeCard?.asset else { return }

        if asset.mediaType == .video {
            let opt = PHVideoRequestOptions()
            opt.isNetworkAccessAllowed = true
            PHImageManager.default().requestAVAsset(forVideo: asset, options: opt) { av, _, _ in
                guard let url = (av as? AVURLAsset)?.url else { return }
                DispatchQueue.main.async { self.presentShareSheet(items: [url]) }
            }
        } else {
            // 图片：弹出分享选项
            showShareOptions = true
        }
    }

    private func presentShareSheet(items: [Any]) {
        let vc = UIActivityViewController(activityItems: items, applicationActivities: nil)
        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let root = scene.windows.first?.rootViewController {
            root.present(vc, animated: true)
        }
        
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
    private func shareOriginalImage() {
        showShareOptions = false
        guard let image = activeCard?.image else { return }
        presentShareSheet(items: [image])
    }

    private func shareImageWithNote() {
        showShareOptions = false
        guard let image = activeCard?.image,
              let note = tagCache[activeCard?.asset.localIdentifier ?? ""]?.note,
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
        UIColor.white.setFill()
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


    // MARK: - Note
    private func openNoteEditor() {
        syncNoteForCurrent()
        showNoteEditor = true
    }

    private func syncNoteForCurrent() {
        guard let id = activeCard?.asset.localIdentifier else { currentNote = ""; return }
        currentNote = tagCache[id]?.note ?? ""
    }

    private func hasNoteForCurrentAsset() -> Bool {
        guard let id = activeCard?.asset.localIdentifier else { return false }
        return (tagCache[id]?.note?.isEmpty == false)
    }

    private var noteEditorOverlay: some View {
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

    private func closeNoteEditor() {
        isNoteFocused = false
        showNoteEditor = false
        syncNoteForCurrent()
    }

    private func saveNote() {
        guard let id = activeCard?.asset.localIdentifier else { return }
        upsertTag(assetID: id) { tag in
            tag.note = currentNote
        }
        closeNoteEditor()
    }

    // MARK: - Undo
    private func undoLastAction() {
        guard !isAnimatingOut else { return }
        guard !isUndoRestoring else { return }
        guard let lastAssetID = undoStack.popLast() else { return }
        isUndoRestoring = true

        sessionProcessed.remove(lastAssetID)

        upsertTag(assetID: lastAssetID) { tag in
            tag.status = "pending"
            tag.createdAt = Date()
        }

        todayPendingCount += 1
        writeWidgetCountDebounced(todayPendingCount)

        sourceRevision += 1
        let revision = sourceRevision
        cancelPendingImageRequests()
        // 也取消正在进行的视频请求，避免旧回调干扰
        cancelCurrentVideoRequests()
        videoCloudProgress = nil
        loadingIDs.removeAll()

        let fetch = PHAsset.fetchAssets(withLocalIdentifiers: [lastAssetID], options: nil)
        guard let asset = fetch.firstObject else {
            rebuildCurrentSource {
                recalcTodayPendingCountFast()
                bootstrapBuffer(force: true)
                isUndoRestoring = false
            }
            return
        }

        // 超时保护：3 秒内 completion 没回来就强制恢复
        let undoTimeout = DispatchWorkItem { [self] in
            guard self.isUndoRestoring else { return }
            self.rebuildCurrentSource {
                self.recalcTodayPendingCountFast()
                self.bootstrapBuffer(force: true)
                self.isUndoRestoring = false
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0, execute: undoTimeout)

        loadCardState(for: asset) { card in
            DispatchQueue.main.async {
                undoTimeout.cancel()
                guard revision == self.sourceRevision else {
                    self.isUndoRestoring = false
                    return
                }
                self.stopAllMedia()
                self.resetImageZoom()
                self.settleOffset = .zero

                let restoredID = card.asset.localIdentifier
                self.buffer.removeAll { $0.asset.localIdentifier == restoredID }

                if let cur = self.activeCard {
                    let currentID = cur.asset.localIdentifier
                    if currentID != restoredID {
                        self.buffer.removeAll { $0.asset.localIdentifier == currentID }
                        self.insertBufferInTodayOrder(cur)
                    }
                }
                self.activeCard = card
                self.normalizeBuffer(excluding: restoredID)

                self.syncNoteForCurrent()
                self.ensureBuffer()
                self.refreshFilmstripSnapshot()
                self.isUndoRestoring = false

                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            }
        }
    }

    // MARK: - Zoom reset
    private func resetImageZoom() {
        zoomScale = 1.0
        zoomResetToken = UUID()
    }

    // MARK: - Quota upgrade card (inline, not a popup)
    private var quotaUpgradeCard: some View {
        VStack(spacing: 18) {
            Spacer()

            Text("🍪")
                .font(.system(size: 52))

            VStack(spacing: 6) {
                Text("quota.title")
                    .font(.title3.bold())
                Text("quota.subtitle")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }

            Text("quota.indie")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 4)

            Button {
                paywallGate.showPaywall = true
            } label: {
                Text("quota.cta")
                    .font(.subheadline.bold())
                    .foregroundColor(.white)
                    .frame(maxWidth: 220)
                    .padding(.vertical, 12)
                    .background(Color.orange)
                    .clipShape(Capsule())
            }

            Text("quota.reset.hint")
                .font(.caption2)
                .foregroundColor(.secondary.opacity(0.7))

            Spacer()
        }
        .frame(width: cardWidth, height: cardHeight)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(Color(.systemGray6))
        )
        .padding(20)
    }
}

// MARK: - Snapshot card (for non-top cards)
private struct SnapshotCardView: View {
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

// MARK: - NEW: Animated gesture hint (non-blocking)
private struct TodayGestureHintView: View {
    @State private var x: CGFloat = 0
    @State private var y: CGFloat = 0

    var body: some View {
        VStack(spacing: 10) {
            Spacer()

            VStack(spacing: 10) {
                // 手指左右摆动
                HStack(spacing: 28) {
                    Image(systemName: "arrow.left")
                        .font(.title3.weight(.semibold))
                        .opacity(0.6)

                    Image(systemName: "hand.point.up.left.fill")
                        .font(.system(size: 40))
                        .offset(x: x)
                        .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: x)

                    Image(systemName: "arrow.right")
                        .font(.title3.weight(.semibold))
                        .opacity(0.6)
                }

                // 上滑提示
                Image(systemName: "arrow.up")
                    .font(.title3.weight(.semibold))
                    .opacity(0.55)
                    .offset(y: y)
                    .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: y)

                Text(LocalizedStringKey("hint.gesture.today"))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 16)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 18))

            Spacer().frame(height: 110) // 避开底部按钮
        }
        .padding(.horizontal, 24)
        .onAppear {
            x = 36
            y = -10
        }
    }
}
