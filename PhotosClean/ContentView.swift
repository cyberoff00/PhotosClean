import SwiftUI
import Photos
import SwiftData
import WidgetKit
import AVKit
import PhotosUI
import UIKit
import Combine
import UniformTypeIdentifiers

// MARK: - ContentView
struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject var storeManager: StoreManager
    @EnvironmentObject var paywallGate: PaywallGate
    @EnvironmentObject var storageStats: StorageStats
    @EnvironmentObject var ratingPrompt: RatingPrompt

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
    /// Failed card-image loads (e.g. iCloud on bad network) retried a few times
    /// before the asset is skipped, so loading can always end.
    @State private var cardLoadRetryCounts: [String: Int] = [:]
    private static let cardLoadMaxRetries = 2
    /// First appear does a full load; later appears only do light revalidation.
    @State private var hasLoadedOnce = false

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

    // Default experience is a random historical day. Today / This week / a
    // specific month are reachable from the single source entry in the header.
    @State private var dateSourceMode: DateSourceMode = .random
    @State private var todayScope: TodayScope = .day
    @State private var randomPickedDay: Date? = nil
    /// The month shown when `todayScope == .month`. Lets the user browse any
    /// historical month, not just the current one.
    @State private var monthReference: Date = Date()
    @State private var showMonthPicker = false

    // MARK: Random-day pre-warming
    // Pick the *next* random day ahead of time and pre-download its first photos
    // so tapping "Random" lands on already-sharp images instead of waiting on iCloud.
    @State private var prewarmedRandomDay: Date? = nil
    @State private var prewarmedRandomAssets: [PHAsset] = []
    /// Assets currently registered with PHCachingImageManager for prefetch, so we
    /// can stop the previous set and avoid unbounded caching growth.
    @State private var cachedPrewarmAssets: [PHAsset] = []
    @State private var isPrewarmingRandom = false
    /// When false, pre-warming only runs on Wi-Fi. Default true (data is cheap;
    /// the user can restrict it in Settings). Mirrored by SettingsView.
    @AppStorage("prewarm_use_cellular") private var prewarmUseCellular: Bool = true
    private static let randomPrewarmCount = 8

    // MARK: Today/Day source (selected day + unmarked)
    @State private var todayAssets: [PHAsset] = []
    @State private var todayCursor: Int = 0
    @State private var todayOrderByID: [String: Int] = [:]


    // MARK: Tag cache (关键：O(1) lookup)
    @State private var tagCache: [String: PhotoTag] = [:]

    // MARK: Header counts cache（避免 body 里每帧 filter allTags）
    @State private var redCount: Int = 0
    @State private var showCleanupAuthAlert = false
    // Photos access blocked by Screen Time / MDM restrictions — needs its own
    // message because the per-app Settings toggle doesn't exist in this case.
    @State private var showCleanupRestrictedAlert = false
    /// True while a one-tap cleanup delete is in flight. Prevents repeated taps
    /// from enqueuing multiple PHPhotoLibrary delete requests whose system
    /// confirmation dialogs would otherwise stack up and flush on next launch.
    @State private var isCleanupDeleting = false
    /// Set true the instant we actually fire performChanges (i.e. the system
    /// delete confirmation is on its way). The watchdog below uses this to tell
    /// "still stuck waiting to present" apart from "user is staring at the system
    /// dialog" — it only unsticks the former.
    @State private var cleanupChangesStarted = false

    // MARK: Pending-release cache
    // Recomputed only when redCount or storageStats precise sizes change.
    // Body must NOT iterate tagCache on every drag frame.
    @State private var pendingReleaseBytesCache: Int64 = 0
    @State private var pendingReleaseAllPreciseCache: Bool = true

    // Library oldest/newest creation dates. Cached so repeated "random day"
    // picks don't re-run two PHAsset.fetchAssets queries each time.
    @State private var cachedLibraryDateBounds: (oldest: Date, newest: Date)? = nil

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
    /// The asset `livePhoto` belongs to, so we only play it for the matching card.
    @State private var livePhotoAssetID: String?
    /// In-flight background Live Photo preload, cancelled on card change.
    @State private var livePhotoPreloadID: PHImageRequestID = PHInvalidImageRequestID
    /// True while waiting on an iCloud Live Photo download triggered by a tap.
    @State private var isLoadingLivePhoto = false
    /// User tapped before the Live Photo finished loading — auto-play when it lands.
    @State private var pendingLivePlay = false
    /// Look-ahead cache: fully-loaded Live Photos for upcoming cards, so reaching
    /// a Live Photo and tapping plays instantly (no spinner).
    @State private var livePhotoCache: [String: PHLivePhoto] = [:]
    @State private var liveWarmInFlight: Set<String> = []
    /// In-flight Live Photo warm-up requests (asset id → request id) so they can
    /// be cancelled on source rebuild / disappear.
    @State private var liveWarmRequestIDs: [String: PHImageRequestID] = [:]
    private static let liveWarmAhead = 2     // upcoming Live Photos to pre-download
    private static let liveCacheCap = 5
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
    /// True while resolving share content (iCloud video / original image data).
    @State private var isPreparingShare = false

    // MARK: UI layout
    private var cardWidth: CGFloat { Layout.cardWidth(inset: 40) }
    private var cardHeight: CGFloat { Layout.cardWidth(inset: 40) * 4 / 3 }

    // Swipe config
    private var swipeThresholdX: CGFloat { 120 }
    private var swipeThresholdY: CGFloat { 120 }
    private var outDistanceX: CGFloat { Layout.swipeOutDistanceX }
    private var outDistanceY: CGFloat { Layout.swipeOutDistanceY }

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
        cardImageRequestIDs[id] = loadCardState(for: asset, onFailure: {
            self.handleCardLoadFailure(for: asset, revision: revision)
        }) { card in
            DispatchQueue.main.async {
                guard revision == self.sourceRevision else { return }
                // A late delivery must not resurrect an asset already swiped away.
                guard !self.sessionProcessed.contains(id) else { return }
                let isFirstDelivery = (self.loadingIDs.remove(id) != nil)
                // A late full-res delivery must not overwrite a card the user has
                // already swiped to during the degraded→full window.
                if let current = self.activeCard, current.asset.localIdentifier != id { return }
                self.activeCard = card
                guard isFirstDelivery else { return }   // run one-time setup once
                // Media prep (video/Live Photo) is driven by onChange(of: activeCard.id).
                self.syncNoteForCurrent()
                self.ensureBuffer()
                self.refreshFilmstripSnapshot()
            }
        }
    }


    /// One app-lifetime caching manager. ContentView is a struct SwiftUI keeps
    /// recreating, so a per-instance manager would lose its warm cache and make
    /// saved request IDs un-cancelable on the new instance.
    private static let sharedImageManager = PHCachingImageManager()
    private var imageManager: PHCachingImageManager { Self.sharedImageManager }

    // MARK: - NEW: lightweight animated coach hints (non-blocking)
    @AppStorage("hint_today_banner_seen") private var hintTodayBannerSeen = false
    @AppStorage("hint_today_empty_seen") private var hintTodayEmptySeen = false
    @AppStorage("hint_today_gesture_seen") private var hintTodayGestureSeen = false

    @State private var showTopBanner: Bool = false
    @State private var bannerTextKey: LocalizedStringKey = "hint.banner.today"
    /// Cancellable auto-dismiss for the top banner, so a new banner restarts the timer.
    @State private var bannerDismissWork: DispatchWorkItem?

    private var hasTodayCards: Bool {
        activeCard != nil || !buffer.isEmpty || !loadingIDs.isEmpty
    }

    private var shouldShowStageEmptyState: Bool {
        !isSourceLoading && !isPickingRandomDay && activeCard == nil && buffer.isEmpty && loadingIDs.isEmpty
    }

    /// True when a free user has used up today's quota
    private var quotaExhaustedForFreeUser: Bool {
        !storeManager.hasUnlockedPremium && paywallGate.isQuotaExhausted
    }

    private var shouldShowRandomContinueState: Bool {
        shouldShowStageEmptyState && dateSourceMode == .random
    }

    private var shouldShowStageLoadingState: Bool {
        isSourceLoading || isPickingRandomDay || (activeCard == nil && buffer.isEmpty && !loadingIDs.isEmpty)
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
        let cardW = Layout.cardWidth(inset: cardHorizontalInset)
        let cardH = cardW * 4 / 3
        // cardStackView uses .padding(20)
        return cardH + 40
    }

    // 32pt thumbnails + small vertical padding. A touch shorter on compact
    // phones so the card stage gets more room.
    private var filmstripStageHeight: CGFloat { Layout.isCompactHeight ? 40 : 46 }
    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()

            VStack(spacing: 0) {
                // Header belongs to the safe area and should not be pushed around by
                // photo switching / loading.
                headerView
                    .padding(.horizontal, 16)
                    .padding(.top, Layout.isCompactHeight ? 10 : 42)
                    .padding(.bottom, Layout.isCompactHeight ? 4 : 10)

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

                    stageLoadingView
                        .opacity(shouldShowStageLoadingState ? 1 : 0)

                    if activeCard != nil || !buffer.isEmpty {
                        cardStackView
                            .padding(20)
                    }

                    // Opacity-gated (not a structural `if`) and animation-disabled
                    // so it hard-cuts in instead of being captured by the swipe-out
                    // animation transaction — that capture is what made the page
                    // occasionally flash when a batch was swiped to the end.
                    randomContinueEmptyState
                        .opacity(shouldShowRandomContinueState ? 1 : 0)
                        .allowsHitTesting(shouldShowRandomContinueState)
                        .animation(.none, value: shouldShowRandomContinueState)

                    // Inline quota upgrade card (hard wall for free users)
                    if quotaExhaustedForFreeUser && !shouldShowStageEmptyState {
                        quotaUpgradeCard
                            .transition(.opacity)
                    } else if storageStats.shouldShowCelebrationCard && !shouldShowStageEmptyState {
                        // Celebration card has lower priority than the quota card
                        goalAchievedCard
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
            //
            // Short phones (iPhone SE / mini): there isn't enough vertical room
            // for the card *and* these buttons above the tab bar, so we drop the
            // buttons entirely — left/right/up swipes (and the on-card edge
            // buttons) still cover delete / keep / maybe. On taller phones we
            // keep them but hide them whenever there's no card to act on (the
            // "This day is done" / loading states), so they never float over the
            // tab bar in an empty stage.
            // Short phones (iPhone SE / mini): drop the swipe circles entirely so
            // the card can be larger — delete / keep / maybe stay available via
            // swipes and the on-card edge buttons. Taller phones & iPad keep the
            // buttons, hidden only when there's no card to act on. The storage
            // badge no longer lives here (it's a chip on the card corner now).
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if !Layout.isCompactHeight {
                    bottomButtons
                        .padding(.horizontal, 18)
                        .padding(.vertical, 4)
                        .padding(.bottom, bottomButtonsLiftFromTab)
                        .opacity(hasTodayCards ? 1 : 0)
                        .allowsHitTesting(hasTodayCards)
                        .animation(.none, value: hasTodayCards)
                }
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
            recomputePendingRelease()
            if !hasLoadedOnce {
                hasLoadedOnce = true
                if dateSourceMode == .random && randomPickedDay == nil {
                    // First launch default: land on a random historical day. Once a
                    // day is picked this branch never runs again.
                    randomButtonTapped()
                } else {
                    rebuildCurrentSource {
                        recalcTodayPendingCountFast()
                        bootstrapBuffer(force: true)
                        refreshFilmstripSnapshot()
                        presentTopBannerIfNeeded()
                    }
                }
            } else {
                // Re-appear (tab switch): tag cache was just rebuilt above, so drop
                // cards marked elsewhere but keep loaded images — no force reload.
                // photoLibraryDidChange → ReloadPhotos covers real library changes.
                buffer.removeAll { !isUnmarkedTodayAsset($0.asset) }
                if let cur = activeCard, !isUnmarkedTodayAsset(cur.asset) {
                    activeCard = buffer.isEmpty ? nil : buffer.removeFirst()
                    syncNoteForCurrent()
                }
                recalcTodayPendingCountFast()
                ensureBuffer()
                refreshFilmstripSnapshot()
            }
            storageStats.notePendingProgress(pendingReleaseBytes)
            // Warm the next random day in the background so re-rolling stays
            // fast and sharp.
            prewarmNextRandomDay()
            prefetchLibraryDateBounds()
        }
        .sheet(isPresented: $showMonthPicker) {
            MonthPickerSheet(
                bounds: cachedLibraryDateBounds,
                initial: monthReference
            ) { picked in
                selectMonth(picked)
            }
            .presentationDetents([.height(320)])
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
        // Midnight rollover: lift the free-quota wall and refresh "today"-anchored sources.
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name.NSCalendarDayChanged).receive(on: RunLoop.main)) { _ in
            handleDayChange()
        }
        // Returning to the foreground may also cross midnight — re-check the quota.
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            _ = paywallGate.checkQuota(isPremium: storeManager.hasUnlockedPremium)
        }
        .onChange(of: activeCard?.asset.localIdentifier) { _, _ in
            stopAllMedia()
            resetImageZoom()
            syncNoteForCurrent()
            prepareMediaForCurrent()
            refreshFilmstripSnapshot()
        }
        .onChange(of: redCount) { _, _ in
            recomputePendingRelease()
            storageStats.notePendingProgress(pendingReleaseBytes)
        }
        // When async precise-size results land, refresh the cache so the
        // "~" approx prefix can drop off without rerunning per body frame.
        // Throttled: size prefetch can publish many batches in a burst, and
        // recomputePendingRelease() is O(tagCache) — without throttling this
        // recomputes app-wide on every batch and makes all taps feel laggy.
        .onReceive(storageStats.$preciseSizes.dropFirst().throttle(for: .milliseconds(300), scheduler: RunLoop.main, latest: true)) { _ in
            recomputePendingRelease()
        }
        .onDisappear {
            stopAllMedia()
            cancelPendingImageRequests()
            cancelLiveWarmRequests()
        }
        .alert("cleanup.auth.title".localized, isPresented: $showCleanupAuthAlert) {
            Button("cleanup.auth.settings".localized) { PhotoLibraryAuth.openSettings() }
            Button("common.cancel".localized, role: .cancel) {}
        } message: {
            Text("cleanup.auth.message".localized)
        }
        // Restricted by Screen Time / MDM: the app's Settings page has no Photos
        // toggle, so we point the user to Screen Time instead of "Open Settings".
        .alert("cleanup.auth.restricted.title".localized, isPresented: $showCleanupRestrictedAlert) {
            Button("common.ok".localized, role: .cancel) {}
        } message: {
            Text("cleanup.auth.restricted.message".localized)
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
        bannerDismissWork?.cancel()
        withAnimation(.easeOut(duration: 0.2)) { showTopBanner = true }
        let work = DispatchWorkItem {
            withAnimation(.easeOut(duration: 0.2)) { showTopBanner = false }
        }
        bannerDismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func hideBanner() {
        bannerDismissWork?.cancel()
        bannerDismissWork = nil
        withAnimation(.easeOut(duration: 0.2)) { showTopBanner = false }
    }

    /// Midnight rollover: re-check the free quota (lifts the wall via the gate's
    /// objectWillChange) and rebuild "now"-anchored sources.
    private func handleDayChange() {
        _ = paywallGate.checkQuota(isPremium: storeManager.hasUnlockedPremium)
        if dateSourceMode == .today, todayScope == .day || todayScope == .week {
            refreshCurrentSourcePreservingSelection()
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
                            isLoadingLivePhoto: isLoadingLivePhoto,
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
                // Only attach the drag recognizer to the top card. The previous
                // "always attach + mask" form created gesture state for every
                // card in the stack and re-installed the recognizer when the
                // top changed, which showed up as a flash after each swipe.
                .highPriorityGesture(
                    isTop ? cardGesture() : nil,
                    including: (isTop && !isZoomingImage) ? .all : .subviews
                )
            }
        }
        // Storage/goal progress sits as a small chip in the card's bottom-left
        // corner instead of taking a full row above the tab bar — that lets the
        // card itself be larger. Pinned to the stack frame so it stays put while
        // a card swipes out.
        .overlay(alignment: .bottomLeading) {
            stageStatusBadge
                .padding(10)
                .allowsHitTesting(false)
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
        // Daily quota gate at the single commit entry (gesture, button and edge
        // swipe all funnel through here). recordSwipe is a no-op for premium.
        guard paywallGate.recordSwipe(isPremium: storeManager.hasUnlockedPremium) else {
            if !paywallGate.showPaywall { paywallGate.showPaywall = true }
            return
        }
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

            // Cancel any in-flight (esp. iCloud) image download for the swiped
            // card so it stops competing with the next card's high-res fetch.
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

            // Quota was recorded at commit entry. Hard wall: the moment a free
            // user uses up today's quota, auto-present
            // the paywall sheet (the inline upgrade card stays as a fallback).
            if !self.storeManager.hasUnlockedPremium,
               self.paywallGate.isQuotaExhausted,
               !self.paywallGate.showPaywall {
                self.paywallGate.showPaywall = true
            }

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
            HStack(alignment: .center) {
                Text("header.title".localized)
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(.primary)

                Spacer()

                // One-tap cleanup: actually delete everything marked for deletion,
                // so users don't need to dig into the "To Delete" folder. Appears
                // only once something has been left-swiped. Opacity-gated (not a
                // structural `if`) and animation-disabled so swiping a card can't
                // capture it in the swipe-out transaction and make it flash.
                cleanupTrashButton
                    .opacity(redCount > 0 ? 1 : 0)
                    .allowsHitTesting(redCount > 0)
                    .animation(.none, value: redCount > 0)
            }

            HStack(spacing: 12) {
                HStack(spacing: 8) {
                    // Single source entry: pick Random day / Today / This week /
                    // a specific month. Replaces the old separate scope + random pills.
                    Menu {
                        Button {
                            randomButtonTapped()
                        } label: {
                            Label("filter.random".localized, systemImage: "shuffle")
                        }
                        Button {
                            activateTodayScope(.day)
                        } label: {
                            Label("filter.today".localized, systemImage: "sun.max")
                        }
                        Button {
                            activateTodayScope(.week)
                        } label: {
                            Label("filter.week".localized, systemImage: "calendar")
                        }
                        Button {
                            prefetchLibraryDateBounds()
                            showMonthPicker = true
                        } label: {
                            Label("filter.pick_month".localized, systemImage: "calendar.badge.clock")
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: currentSourceIcon)
                            Text(currentSourceLabel)
                                .lineLimit(1)
                            Image(systemName: "chevron.down")
                                .font(.system(size: 10, weight: .semibold))
                        }
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.blue)
                        .clipShape(Capsule())
                    }

                    // Date next to the entry: day for day/random, the week's first
                    // day for week, year-month for month.
                    if let dateLabel = currentSourceDateLabel {
                        Text(dateLabel)
                            .font(.caption.weight(.medium))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .layoutPriority(-1)
                    }

                    // One-tap re-roll, kept only in random mode so changing days
                    // stays a single tap instead of reopening the menu.
                    if dateSourceMode == .random {
                        Button(action: randomButtonTapped) {
                            Group {
                                if isPickingRandomDay {
                                    ProgressView()
                                        .controlSize(.mini)
                                } else {
                                    Image(systemName: "shuffle")
                                        .font(.caption.weight(.semibold))
                                }
                            }
                            .foregroundColor(.primary)
                            .frame(width: 30, height: 30)
                            .background(Color.secondary.opacity(0.12))
                            .clipShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .disabled(isPickingRandomDay)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // Daily quota indicator removed from the header so it can't crowd
                // the source date label. The quota itself is unchanged — the paywall
                // still gates free users once the daily limit is reached.

                Button(action: undoLastAction) {
                    Image(systemName: "arrow.uturn.backward.circle.fill")
                        .font(.title2)
                        .frame(width: 44, height: 44)
                }
                .opacity(undoStack.isEmpty ? 0 : 1)
                .disabled(undoStack.isEmpty || isAnimatingOut || isUndoRestoring)
                // Same anti-flash treatment as the cleanup button: never let the
                // swipe-out animation transaction animate the empty→visible flip.
                .animation(.none, value: undoStack.isEmpty)
            }
            .padding(.top, 2)
        }
        .transaction { $0.animation = nil }
    }

    /// Name shown on the single source entry pill.
    private var currentSourceLabel: String {
        switch dateSourceMode {
        case .random:
            return "filter.random".localized
        case .today:
            switch todayScope {
            case .day:   return "filter.today".localized
            case .week:  return "filter.week".localized
            case .month: return "filter.month".localized
            }
        }
    }

    /// SF Symbol shown on the source entry pill, matching the current mode.
    private var currentSourceIcon: String {
        switch dateSourceMode {
        case .random:
            return "shuffle"
        case .today:
            switch todayScope {
            case .day:   return "sun.max"
            case .week:  return "calendar"
            case .month: return "calendar"
            }
        }
    }

    /// The date shown next to the entry: a day for day/random, the week's first
    /// day for week, and the year-month for month. Nil when no day is picked yet.
    private var currentSourceDateLabel: String? {
        switch dateSourceMode {
        case .random:
            guard let day = randomPickedDay else { return nil }
            return formattedDay(day)
        case .today:
            switch todayScope {
            case .day:   return formattedDay(Date())
            case .week:  return formattedDay(selectedSourceInterval.start)
            case .month: return formattedMonth(monthReference)
            }
        }
    }

    /// Friendly loading placeholder shown while a source switch / random pick
    /// prepares its first sharp card.
    private var stageLoadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("loading.preparing".localized)
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
    }

    // MARK: - Bottom Buttons
    private func triggerButtonSwipe(status: String) {
        guard !isAnimatingOut else { return }
        guard !isUndoRestoring else { return }
        guard activeCard != nil else { return }
        // Quota wall: buttons must not bypass the daily free limit.
        if quotaExhaustedForFreeUser {
            paywallGate.showPaywall = true
            return
        }
        if isZoomingImage { resetImageZoom() }

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
            // Gray, not red: left-swipe / this button only *marks* for deletion.
            // The actual delete is the red trash in the header. (The storage/goal
            // badge now lives in the card's bottom-left corner, not here.)
            ActionButton(icon: "trash.fill", color: .gray) { triggerButtonSwipe(status: "delete") }
            ActionButton(icon: "clock.fill", color: .yellow) { triggerButtonSwipe(status: "maybe") }
            ActionButton(icon: "heart.fill", color: .green) { triggerButtonSwipe(status: "keep") }
        }
    }

    /// Cached pending-release total. Hot path getter for the badge — no allocation,
    /// no tagCache iteration. Refresh via `recomputePendingRelease()`.
    private var pendingReleaseBytes: Int64 { pendingReleaseBytesCache }

    private var pendingReleaseAllPrecise: Bool { pendingReleaseAllPreciseCache }

    /// Walk tagCache once and update cached totals. Called when redCount changes
    /// or when async precise-size results arrive — never per body re-eval.
    private func recomputePendingRelease() {
        var total: Int64 = 0
        var allPrecise = true
        for (id, tag) in tagCache where tag.status == "delete" {
            total += storageStats.bestSize(forID: id)
            if !storageStats.hasPrecise(forID: id) { allPrecise = false }
        }
        if pendingReleaseBytesCache != total {
            pendingReleaseBytesCache = total
        }
        if pendingReleaseAllPreciseCache != allPrecise {
            pendingReleaseAllPreciseCache = allPrecise
        }
    }

    /// Single status badge: shows pending-to-release size, optionally with goal.
    @ViewBuilder
    private var stageStatusBadge: some View {
        let bytes = pendingReleaseBytes
        let prefix = pendingReleaseAllPrecise ? "" : "~"
        let achieved = storageStats.goalAchievedToday
        let color: Color = achieved ? .green : .red

        if storageStats.goalEnabled {
            HStack(spacing: 4) {
                Image(systemName: achieved ? "checkmark.circle.fill" : "target")
                    .font(.system(size: 10, weight: .semibold))
                Text("\(prefix)\(bytes.byteCountShort) / \(StorageStats.goalLabel(storageStats.dailyGoalBytes))")
                    .font(.caption2.weight(.semibold).monospacedDigit())
            }
            .foregroundColor(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            // Material backing so it stays readable sitting over a photo.
            .background(.ultraThinMaterial, in: Capsule())
        } else if redCount > 0 {
            HStack(spacing: 4) {
                Image(systemName: "trash")
                    .font(.system(size: 10, weight: .semibold))
                Text("\(prefix)\(bytes.byteCountShort)")
                    .font(.caption2.weight(.semibold).monospacedDigit())
            }
            .foregroundColor(.red)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.ultraThinMaterial, in: Capsule())
        }
    }

    // MARK: - One-tap cleanup (delete everything marked for deletion)

    private var cleanupTrashButton: some View {
        Button(action: cleanupMarkedForDeletion) {
            HStack(spacing: 5) {
                Image(systemName: "trash.fill")
                    .font(.system(size: 13, weight: .semibold))
                Text("\(redCount)")
                    .font(.subheadline.weight(.bold).monospacedDigit())
            }
            .foregroundColor(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Color.red)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(isAnimatingOut || isUndoRestoring || isCleanupDeleting)
    }

    /// Collect every asset whose freshest tag is "delete" and remove it from the
    /// photo library. iOS shows its own deletion confirmation before anything is
    /// actually deleted, so this is safe as a single tap.
    private func cleanupMarkedForDeletion() {
        var latest: [String: (status: String, date: Date)] = [:]
        for tag in allTags {
            if let e = latest[tag.assetID], tag.createdAt <= e.date { continue }
            latest[tag.assetID] = (tag.status, tag.createdAt)
        }
        let ids = latest.compactMap { $0.value.status == "delete" ? $0.key : nil }
        cleanLog("[Today] tapped cleanup — ids=\(ids.count) isCleanupDeleting=\(isCleanupDeleting)")
        guard !ids.isEmpty else { cleanLog("[Today] abort: no ids"); return }
        // Re-entrancy guard: one delete request at a time. Without this, repeated
        // taps (while iOS defers its delete confirmation) queue up dozens of
        // requests that all surface at once on the next launch.
        guard !isCleanupDeleting else { cleanLog("[Today] abort: already deleting (button locked)"); return }
        isCleanupDeleting = true
        // Safety valve: if we somehow never reach performChanges (UIKit dropped
        // the presentation, the scene state misreported, a permission callback
        // never returned…) the button would stay grey forever. Unstick it after
        // a few seconds — but only while we're still waiting to present; once the
        // system dialog is actually up (cleanupChangesStarted) we leave it to the
        // performChanges completion so we never yank the lock mid-deletion.
        cleanupChangesStarted = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
            if isCleanupDeleting && !cleanupChangesStarted {
                isCleanupDeleting = false
            }
        }
        // Hard safety net: on iPad the system "Delete N Photos?" confirmation can
        // be dropped without ever calling performChanges' completion (the dialog
        // is presented into a transient state and silently discarded), which left
        // the button disabled forever — the "一键清理卡死" report. Re-enable
        // unconditionally after a long delay so the feature can never get stuck.
        // Harmless if a real deletion is still in flight: the completion handler
        // also clears this flag, and re-deleting already-deleted assets is a no-op.
        DispatchQueue.main.asyncAfter(deadline: .now() + 25) {
            if isCleanupDeleting { cleanLog("[Today] HARD watchdog (25s) fired — button was still locked, unsticking. Dialog likely never completed.") ; isCleanupDeleting = false }
        }

        cleanLog("[Today] requesting write access… status=\(PHPhotoLibrary.authorizationStatus(for: .readWrite).rawValue)")
        PhotoLibraryAuth.requestWriteAccess { granted in
            cleanLog("[Today] write access result granted=\(granted)")
            guard granted else {
                isCleanupDeleting = false
                // A restricted user has no Photos toggle in Settings, so route
                // them to the Screen Time message instead of "Open Settings".
                if PhotoLibraryAuth.isRestricted {
                    showCleanupRestrictedAlert = true
                } else {
                    showCleanupAuthAlert = true
                }
                return
            }
            performCleanupDelete(ids: ids)
        }
    }

    private func performCleanupDelete(ids: [String]) {
        cleanLog("[Today] performCleanupDelete — fetching \(ids.count) assets off main…")
        // fetchAssets + enumerate is synchronous Photos I/O — keep it off main.
        DispatchQueue.global(qos: .userInitiated).async {
            let result = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
            var array: [PHAsset] = []
            array.reserveCapacity(result.count)
            result.enumerateObjects { a, _, _ in array.append(a) }
            cleanLog("[Today] fetched \(result.count) assets, hopping to main for runWhenReady")

            DispatchQueue.main.async {
                // Fire the delete (and thus iOS's confirmation) only when the UI
                // can present it: foreground-active and no menu/alert mid-transition.
                // Otherwise UIKit drops the system dialog (nothing happens) or holds
                // it to the next launch (a pile of dialogs). This waits until ready.
                ForegroundGate.runWhenReady {
                    cleanupChangesStarted = true
                    let bytes = storageStats.totalBestSize(for: array)
                    cleanLog("[Today] ▶︎ calling PHPhotoLibrary.performChanges (system Delete dialog should appear NOW)")
                    PHPhotoLibrary.shared().performChanges({
                        PHAssetChangeRequest.deleteAssets(result)
                    }) { success, error in
                        cleanLog("[Today] ◀︎ performChanges COMPLETION success=\(success) error=\(error?.localizedDescription ?? "nil")")
                        DispatchQueue.main.async {
                            isCleanupDeleting = false
                            // success=false means the user cancelled the system delete dialog.
                            guard success else { return }
                            let idSet = Set(ids)

                            for tag in allTags where idSet.contains(tag.assetID) {
                                modelContext.delete(tag)
                            }
                            try? modelContext.save()

                            for id in idSet { tagCache.removeValue(forKey: id) }
                            // Physically deleted assets can no longer be undone —
                            // drop them so undo can't write tags for dead assets.
                            undoStack.removeAll { idSet.contains($0) }
                            redCount = 0   // every delete-marked asset was just removed

                            storageStats.recordCleanup(bytes: bytes)
                            ratingPrompt.registerCleanup()
                            recomputePendingRelease()
                            storageStats.notePendingProgress(pendingReleaseBytes)
                            WidgetCenter.shared.reloadAllTimelines()
                            // The library change observer fires ReloadPhotos, which
                            // refreshes the current source so deleted assets drop out.
                        }
                    }
                }
            }
        }
    }

    // MARK: - Bootstrap / Today source
    private func bootstrapBuffer(force: Bool) {
        if force {
            sourceRevision += 1
            cancelPendingImageRequests()
            cancelLiveWarmRequests()
            stopAllMedia()
            buffer.removeAll()
            loadingIDs.removeAll()
            cardLoadRetryCounts.removeAll()
            livePhotoCache.removeAll()
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

        cardImageRequestIDs[id] = loadCardState(for: firstAsset, highQuality: true, onFailure: {
            self.handleCardLoadFailure(for: firstAsset, revision: revision)
        }) { card in
            DispatchQueue.main.async {
                guard revision == self.sourceRevision else { return }
                // A late delivery must not resurrect an asset already swiped away.
                guard !self.sessionProcessed.contains(id) else { return }
                let isFirstDelivery = (self.loadingIDs.remove(id) != nil)
                // A late full-res delivery must not overwrite a card the user has
                // already swiped to during the degraded→full window.
                if let current = self.activeCard, current.asset.localIdentifier != id { return }
                self.activeCard = card
                guard isFirstDelivery else { return }   // run one-time setup once
                // Media prep (video/Live Photo) is driven by onChange(of: activeCard.id).
                self.syncNoteForCurrent()
                self.refreshFilmstripSnapshot()
                self.ensureBuffer()
            }
        }
    }

    private var selectedSourceInterval: DateInterval {
        let calendar = Calendar.current
        switch dateSourceMode {
        case .today:
            // Day/week track "now"; month browses whichever month was picked.
            let reference = (todayScope == .month) ? monthReference : Date()
            return interval(for: todayScope, referenceDate: reference, calendar: calendar)
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

    /// Prefetch the library date bounds off-main and cache them, so the month
    /// picker sheet never runs synchronous Photos fetches on the main thread.
    private func prefetchLibraryDateBounds() {
        guard cachedLibraryDateBounds == nil else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            guard let bounds = fetchLibraryDateBounds() else { return }
            DispatchQueue.main.async {
                if cachedLibraryDateBounds == nil { cachedLibraryDateBounds = bounds }
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
        // Snapshot the cached bounds on the main thread before going background.
        let cachedBounds = cachedLibraryDateBounds

        // 整个随机选日逻辑移到后台线程，避免阻塞 UI
        DispatchQueue.global(qos: .userInitiated).async {
            guard let bounds = cachedBounds ?? self.fetchLibraryDateBounds() else {
                DispatchQueue.main.async {
                    completion(self.randomPickedDay ?? Calendar.current.startOfDay(for: Date()))
                }
                return
            }
            // Persist freshly-computed bounds back to the cache (on main).
            if cachedBounds == nil {
                DispatchQueue.main.async { self.cachedLibraryDateBounds = bounds }
            }

            let calendar = Calendar.current
            let todayStart = calendar.startOfDay(for: Date())
            let hasMultipleDays = calendar.startOfDay(for: bounds.oldest) != calendar.startOfDay(for: bounds.newest)

            // Day bucketing via integer keys instead of Calendar.startOfDay per
            // asset. startOfDay is an ICU/Calendar call (~microseconds each); on a
            // 50k+ library, calling it once per asset adds up to multiple seconds
            // of cold-start "Loading…". Bucketing on (creationDate + tzOffset) /
            // 86400 — a plain integer day index — is hundreds of times faster. The
            // ±1h DST skew near midnight is irrelevant for "pick a random day". We
            // keep one real creationDate per bucket so the *picked* day still gets
            // an exact startOfDay (and thus a correct day interval) below.
            let tzOffset = TimeInterval(TimeZone.current.secondsFromGMT(for: Date()))
            func dayKey(_ date: Date) -> Int {
                Int((date.timeIntervalSince1970 + tzOffset) / 86400)
            }
            let todayKey = dayKey(todayStart)

            let allOpt = PHFetchOptions()
            allOpt.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            let all = PHAsset.fetchAssets(with: allOpt)

            guard all.count > 0 else {
                DispatchQueue.main.async { completion(todayStart) }
                return
            }

            var anyDays: Set<Int> = []
            var pendingDays: Set<Int> = []
            var representativeDate: [Int: Date] = [:]

            all.enumerateObjects { asset, _, _ in
                guard let d = asset.creationDate else { return }
                let key = dayKey(d)
                if hasMultipleDays && key == todayKey { return }

                anyDays.insert(key)
                if representativeDate[key] == nil { representativeDate[key] = d }

                let id = asset.localIdentifier
                if sessionProcessedIDs.contains(id) { return }
                if nonPendingIDs.contains(id) { return }
                pendingDays.insert(key)
            }

            let pickedKey = pendingDays.randomElement() ?? anyDays.randomElement()
            let finalDay: Date
            if let pickedKey, let rep = representativeDate[pickedKey] {
                finalDay = calendar.startOfDay(for: rep)
            } else {
                finalDay = calendar.startOfDay(for: bounds.newest)
            }

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
        // Invalidate any in-flight random pick so its late callback can't
        // override the source the user just switched to.
        randomPickToken += 1
        isPickingRandomDay = false
        let modeChanged = dateSourceMode != .today
        if modeChanged {
            dateSourceMode = .today
            randomPickedDay = nil
        }
        if modeChanged && todayScope == scope {
            // Scope unchanged but the mode did — still needs a rebuild.
            rebuildCurrentSource {
                recalcTodayPendingCountFast()
                bootstrapBuffer(force: true)
                presentTopBannerIfNeeded()
            }
            return
        }
        switchTodayScope(scope)
    }

    private func switchTodayScope(_ scope: TodayScope) {
        guard todayScope != scope else { return }
        randomPickToken += 1
        isPickingRandomDay = false
        todayScope = scope
        rebuildCurrentSource {
            recalcTodayPendingCountFast()
            bootstrapBuffer(force: true)
            presentTopBannerIfNeeded()
        }
    }

    /// Jump to a specific historical month. Always rebuilds, even if the month
    /// scope is already active, because the reference month changed.
    private func selectMonth(_ month: Date) {
        randomPickToken += 1
        isPickingRandomDay = false
        monthReference = month
        dateSourceMode = .today
        randomPickedDay = nil
        todayScope = .month
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
        // Set immediately (both paths) so a rapid second tap is ignored by the
        // guard above instead of falling through to a duplicate pick.
        isPickingRandomDay = true

        if dateSourceMode != .random {
            dateSourceMode = .random
        }

        // Fast path: the next random day was pre-picked and its first photos
        // pre-downloaded — switch instantly to already-sharp images.
        if let day = prewarmedRandomDay {
            prewarmedRandomDay = nil
            prewarmedRandomAssets = []
            randomPickedDay = day
            let interval = interval(for: .day, referenceDate: day, calendar: Calendar.current)
            rebuildSource(for: interval) {
                guard token == randomPickToken else { return }
                isPickingRandomDay = false
                recalcTodayPendingCountFast()
                bootstrapBuffer(force: true)
                presentTopBannerIfNeeded()
                prewarmNextRandomDay()   // queue the following day
            }
            return
        }

        // Slow path: nothing pre-warmed yet (first tap, or restricted to Wi-Fi
        // while on cellular). Pick on demand, then start pre-warming for next time.
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
                prewarmNextRandomDay()
            }
        }
    }

    // MARK: - Random-day pre-warming

    /// Whether proactive iCloud prefetching is currently allowed by the user's
    /// network preference.
    private var prefetchAllowedNow: Bool {
        guard NetworkMonitor.shared.isConnected else { return false }
        return prewarmUseCellular || NetworkMonitor.shared.isUnmetered
    }

    /// Pre-pick the next random day and pre-download its first photos so the next
    /// "Random" tap is instant and crisp. No-op if one is already warmed or the
    /// network preference disallows it right now.
    private func prewarmNextRandomDay() {
        guard prewarmedRandomDay == nil, !isPrewarmingRandom, prefetchAllowedNow else { return }
        isPrewarmingRandom = true

        pickRandomDayWithPhotos { day in
            // Snapshot marked assets on the main thread; the prewarm must skip them
            // so the first photo the user actually sees (the first *unmarked* one)
            // is the one we pre-download.
            var marked = self.sessionProcessed
            for (id, tag) in self.tagCache where tag.status != "pending" { marked.insert(id) }

            DispatchQueue.global(qos: .utility).async {
                let assets = self.fetchDayAssets(day, limit: Self.randomPrewarmCount, excluding: marked)
                DispatchQueue.main.async {
                    self.isPrewarmingRandom = false
                    guard !assets.isEmpty, self.prewarmedRandomDay == nil else { return }
                    // Stop the previously warmed set so caching doesn't grow unbounded.
                    if !self.cachedPrewarmAssets.isEmpty {
                        self.setPrewarmCaching(self.cachedPrewarmAssets, enabled: false)
                    }
                    self.prewarmedRandomDay = day
                    self.prewarmedRandomAssets = assets
                    self.cachedPrewarmAssets = assets
                    self.setPrewarmCaching(assets, enabled: true)
                }
            }
        }
    }

    /// Fetch the first `limit` *unmarked* assets (newest first) of a given day,
    /// skipping anything the user has already sorted.
    private func fetchDayAssets(_ day: Date, limit: Int, excluding: Set<String>) -> [PHAsset] {
        let cal = Calendar.current
        let start = cal.startOfDay(for: day)
        let end = cal.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(24 * 3600)
        let opt = PHFetchOptions()
        opt.predicate = NSPredicate(format: "creationDate >= %@ AND creationDate < %@", start as NSDate, end as NSDate)
        opt.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let res = PHAsset.fetchAssets(with: opt)
        var arr: [PHAsset] = []
        arr.reserveCapacity(limit)
        res.enumerateObjects { a, _, stop in
            if excluding.contains(a.localIdentifier) { return }
            arr.append(a)
            if arr.count >= limit { stop.pointee = true }
        }
        return arr
    }

    /// Start/stop PHCachingImageManager pre-download for the given assets at the
    /// exact card target the swipe stack requests, so warmed images are reused.
    private func setPrewarmCaching(_ assets: [PHAsset], enabled: Bool) {
        guard !assets.isEmpty else { return }
        let scale = UIScreen.main.scale
        let target = CGSize(width: cardWidth * scale, height: cardHeight * scale)
        let opt = PHImageRequestOptions()
        opt.isNetworkAccessAllowed = true
        opt.deliveryMode = .highQualityFormat
        opt.resizeMode = .fast
        if enabled {
            imageManager.startCachingImages(for: assets, targetSize: target, contentMode: .aspectFit, options: opt)
        } else {
            imageManager.stopCachingImages(for: assets, targetSize: target, contentMode: .aspectFit, options: opt)
        }
    }

    // Cached formatters: DateFormatter init is expensive and these run per frame.
    private static let dayDisplayFormatter: DateFormatter = {
        let df = DateFormatter()
        df.locale = .current
        df.dateStyle = .medium
        df.timeStyle = .none
        return df
    }()

    private static let monthDisplayFormatter: DateFormatter = {
        let df = DateFormatter()
        df.locale = .current
        df.setLocalizedDateFormatFromTemplate("yMMMM")
        return df
    }()

    private func formattedDay(_ day: Date) -> String {
        Self.dayDisplayFormatter.string(from: day)
    }

    private func formattedMonth(_ date: Date) -> String {
        Self.monthDisplayFormatter.string(from: date)
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

            cardImageRequestIDs[id] = loadCardState(for: asset, onFailure: {
                self.handleCardLoadFailure(for: asset, revision: revision)
            }) { card in
                DispatchQueue.main.async {
                    guard revision == self.sourceRevision else { return }

                    // .opportunistic delivers twice (degraded then full). The first
                    // delivery removes the id from loadingIDs; a later delivery is an
                    // upgrade. We must distinguish them so a late high-res upgrade for
                    // an already-swiped asset can't resurrect it into the buffer.
                    let isFirstDelivery = (self.loadingIDs.remove(id) != nil)

                    // Upgrade path: if the card is still on screen / queued, swap in
                    // the higher-quality image in place.
                    if self.activeCard?.asset.localIdentifier == id {
                        self.activeCard = card
                        return
                    }
                    if let idx = self.buffer.firstIndex(where: { $0.asset.localIdentifier == id }) {
                        self.buffer[idx] = card
                        return
                    }

                    // Only the FIRST delivery of an asset the user hasn't acted on
                    // may create a new card. This blocks the "swiped card comes back"
                    // bug where a late upgrade re-inserted a dismissed asset.
                    guard isFirstDelivery,
                          !self.sessionProcessed.contains(id),
                          self.isUnmarkedTodayAsset(asset) else { return }

                    self.insertBufferInTodayOrder(card)

                    if self.activeCard == nil, !self.buffer.isEmpty {
                        self.activeCard = self.buffer.removeFirst()
                        // Media prep is driven by onChange(of: activeCard.id).
                        self.syncNoteForCurrent()
                        self.refreshFilmstripSnapshot()
                    }
                }
            }
        }
    }

    // MARK: - Image Loading
    @discardableResult
    private func loadCardState(for asset: PHAsset, highQuality: Bool = false, onFailure: (() -> Void)? = nil, completion: @escaping (CardState) -> Void) -> PHImageRequestID {
        let scale = UIScreen.main.scale
        let target = CGSize(width: cardWidth * scale, height: cardHeight * scale)

        let opt = PHImageRequestOptions()
        opt.isNetworkAccessAllowed = true
        // The first card after a source switch loads at full quality so the user
        // lands on a sharp image (behind the loading spinner) instead of the
        // opportunistic degraded→full blur flash. Buffered cards keep opportunistic.
        opt.deliveryMode = highQuality ? .highQualityFormat : .opportunistic
        opt.resizeMode = .fast

        let assetID = asset.localIdentifier
        return imageManager.requestImage(
            for: asset,
            targetSize: target,
            contentMode: .aspectFit,
            options: opt
        ) { img, info in
            if let cancelled = info?[PHImageCancelledKey] as? Bool, cancelled { return }
            let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
            if !isDegraded {
                // Final delivery: drop the saved request id (if it's still ours).
                let reqID = (info?[PHImageResultRequestIDKey] as? NSNumber)?.int32Value
                DispatchQueue.main.async {
                    if let reqID, self.cardImageRequestIDs[assetID] == reqID {
                        self.cardImageRequestIDs.removeValue(forKey: assetID)
                    }
                    if img != nil { self.cardLoadRetryCounts.removeValue(forKey: assetID) }
                }
            }
            if let img {
                completion(CardState(asset: asset, image: img))
            } else if !isDegraded {
                // Final delivery without an image = real failure (e.g. iCloud
                // on bad network). Degraded interim callbacks never end up here.
                onFailure?()
            }
        }
    }

    /// A card image load failed on its final delivery. Clear the loading marker
    /// so the spinner can end, retry a couple of times, then skip the asset.
    private func handleCardLoadFailure(for asset: PHAsset, revision: Int) {
        DispatchQueue.main.async {
            guard revision == self.sourceRevision else { return }
            let id = asset.localIdentifier
            self.cardImageRequestIDs.removeValue(forKey: id)
            guard self.loadingIDs.remove(id) != nil else { return }

            let attempts = self.cardLoadRetryCounts[id, default: 0]
            if attempts < Self.cardLoadMaxRetries {
                self.cardLoadRetryCounts[id] = attempts + 1
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    guard revision == self.sourceRevision else { return }
                    // Rewind the cursor so ensureBuffer re-requests this asset.
                    if let order = self.todayOrderByID[id] {
                        self.todayCursor = min(self.todayCursor, order)
                    }
                    self.ensureBuffer()
                }
            } else {
                // Give up on this asset and move on so the stack keeps flowing.
                self.cardLoadRetryCounts.removeValue(forKey: id)
                self.ensureBuffer()
            }
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

        update(tag)
        try? modelContext.save()
        tagCache[assetID] = tag

        if oldStatus != "delete" && tag.status == "delete" { redCount += 1 }
        if oldStatus == "delete" && tag.status != "delete" { redCount = max(0, redCount - 1) }
    }

    // MARK: - Media helpers
    private func prepareMediaForCurrent() {
        guard let asset = activeCard?.asset else { return }
        if asset.mediaType == .video {
            loadVideo(for: asset)
        } else if asset.mediaSubtypes.contains(.photoLive) {
            preloadLivePhoto(for: asset)
        }
        // Pre-download the next few upcoming Live Photos so they're instant on arrival.
        warmUpcomingLivePhotos()
    }

    /// Pre-download full Live Photos for the next cards in the buffer so that by
    /// the time the user swipes to one, it's ready to play with no spinner.
    private func warmUpcomingLivePhotos() {
        // Speculative prefetch must honor the user's network preference.
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

    /// Cancel all in-flight Live Photo warm-ups (source rebuild / disappear).
    private func cancelLiveWarmRequests() {
        for reqID in liveWarmRequestIDs.values {
            PHImageManager.default().cancelImageRequest(reqID)
        }
        liveWarmRequestIDs.removeAll()
        liveWarmInFlight.removeAll()
    }

    private func cacheLivePhoto(_ live: PHLivePhoto, for id: String) {
        livePhotoCache[id] = live
        guard livePhotoCache.count > Self.liveCacheCap else { return }
        // Evict entries no longer near the current position.
        let keep = Set([activeCard?.asset.localIdentifier].compactMap { $0 }
                       + buffer.map(\.asset.localIdentifier))
        for k in Array(livePhotoCache.keys) where !keep.contains(k) {
            livePhotoCache.removeValue(forKey: k)
            if livePhotoCache.count <= Self.liveCacheCap { return }
        }
        // Still over cap (everything left is "keep"): force-evict anything but
        // the freshly cached entry so the cache can't grow unbounded.
        for k in Array(livePhotoCache.keys) where k != id {
            livePhotoCache.removeValue(forKey: k)
            if livePhotoCache.count <= Self.liveCacheCap { return }
        }
    }

    /// Apple-style instant Live Photo: load the Live Photo as soon as the card
    /// appears and keep the PHLivePhotoView mounted (but invisible) so it has time
    /// to prepare. Tapping then only flips playback — no request, no fresh view,
    /// no decode stall (the bug that made the previous prefetch "not play").
    private func preloadLivePhoto(for asset: PHAsset) {
        let assetID = asset.localIdentifier
        guard livePhotoAssetID != assetID else { return }   // already loaded

        // Look-ahead cache hit: it was pre-downloaded while on a previous card.
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
        // .highQualityFormat forces the FULL Live Photo (incl. the iCloud video
        // component). .opportunistic often returns only a still placeholder for
        // iCloud assets, which is why historical Live Photos wouldn't animate.
        opt.deliveryMode = .highQualityFormat

        let scale = UIScreen.main.scale
        let target = CGSize(width: cardWidth * scale, height: cardHeight * scale)

        livePhotoPreloadID = PHImageManager.default().requestLivePhoto(
            for: asset,
            targetSize: target,
            contentMode: .aspectFit,
            options: opt
        ) { live, _ in
            guard let live else { return }
            DispatchQueue.main.async {
                self.cacheLivePhoto(live, for: assetID)
                guard self.activeCard?.asset.localIdentifier == assetID else { return }
                self.livePhoto = live
                self.livePhotoAssetID = assetID
                // If the user already tapped while this was downloading, play now.
                if self.pendingLivePlay {
                    self.pendingLivePlay = false
                    self.isLoadingLivePhoto = false
                    self.isPlayingLivePhoto = true
                }
            }
        }
    }

    private func stopAllMedia() {
        // Release audio focus so external audio (e.g., Music/Podcast) can resume.
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
        // O(1) center lookup via the prebuilt id→index map instead of an O(n)
        // firstIndex scan on every swipe. Falls back to the first unmarked asset.
        let centerIndex = activeID.flatMap { todayOrderByID[$0] }
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

        // Tapped again while a slow (iCloud) load is in progress — cancel it.
        if isLoadingLivePhoto {
            isLoadingLivePhoto = false
            pendingLivePlay = false
            return
        }

        if isPlayingLivePhoto {
            isPlayingLivePhoto = false
            return
        }

        // Preloaded and warm → instant play (the Apple-like case).
        if livePhoto != nil, livePhotoAssetID == asset.localIdentifier {
            isPlayingLivePhoto = true
            return
        }

        // Not ready yet (historical iCloud Live Photo still downloading). Show a
        // spinner and auto-play the moment the background load finishes — no
        // second request, so no double download.
        pendingLivePlay = true
        isLoadingLivePhoto = true
        preloadLivePhoto(for: asset)
    }

    // MARK: - Share
    private func shareCurrentAsset() {
        guard let asset = activeCard?.asset else { return }

        if asset.mediaType == .video {
            guard !isPreparingShare else { return }
            beginSharePreparation()
            let opt = PHVideoRequestOptions()
            opt.isNetworkAccessAllowed = true
            PHImageManager.default().requestAVAsset(forVideo: asset, options: opt) { av, _, _ in
                DispatchQueue.main.async {
                    if let url = (av as? AVURLAsset)?.url {
                        self.finishSharePreparation()
                        self.presentShareSheet(items: [url])
                    } else if av != nil {
                        // AVComposition (slo-mo etc.) has no file URL — export the
                        // original video resource to a temp file instead.
                        self.exportVideoResourceAndShare(asset: asset)
                    } else {
                        self.failSharePreparation()
                    }
                }
            }
        } else {
            // 图片：弹出分享选项
            showShareOptions = true
        }
    }

    /// Slo-mo / edited videos come back as AVComposition. Write the underlying
    /// video resource to a temp file so the share sheet gets a real URL.
    private func exportVideoResourceAndShare(asset: PHAsset) {
        let resources = PHAssetResource.assetResources(for: asset)
        guard let resource = resources.first(where: { $0.type == .fullSizeVideo })
                ?? resources.first(where: { $0.type == .video }) else {
            failSharePreparation()
            return
        }
        var ext = (resource.originalFilename as NSString).pathExtension
        if ext.isEmpty { ext = "mov" }
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(ext)
        let opt = PHAssetResourceRequestOptions()
        opt.isNetworkAccessAllowed = true
        PHAssetResourceManager.default().writeData(for: resource, toFile: tempURL, options: opt) { error in
            DispatchQueue.main.async {
                if error == nil {
                    self.finishSharePreparation()
                    self.presentShareSheet(items: [tempURL])
                } else {
                    self.failSharePreparation()
                }
            }
        }
    }

    private func beginSharePreparation() {
        isPreparingShare = true
        bannerTextKey = "share.preparing"
        showBannerFor(seconds: 30)   // safety net; dismissed on finish/fail
    }

    private func finishSharePreparation() {
        isPreparingShare = false
        hideBanner()
    }

    private func failSharePreparation() {
        isPreparingShare = false
        bannerTextKey = "share.failed"
        showBannerFor(seconds: 3)
    }

    private func presentShareSheet(items: [Any]) {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        guard let window = scene?.keyWindow ?? scene?.windows.first else { return }

        // Present on the top-most presented controller, not the root.
        var presenter = window.rootViewController
        while let presented = presenter?.presentedViewController {
            presenter = presented
        }
        guard let presenter else { return }

        let vc = UIActivityViewController(activityItems: items, applicationActivities: nil)
        // iPad requires a popover anchor or it crashes on presentation.
        if let popover = vc.popoverPresentationController {
            popover.sourceView = presenter.view
            popover.sourceRect = CGRect(x: presenter.view.bounds.midX,
                                        y: presenter.view.bounds.midY,
                                        width: 1, height: 1)
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
        guard let asset = activeCard?.asset else { return }
        guard !isPreparingShare else { return }
        beginSharePreparation()

        let opt = PHImageRequestOptions()
        opt.isNetworkAccessAllowed = true
        opt.deliveryMode = .highQualityFormat
        // Original image data (full resolution + EXIF), not the card thumbnail.
        PHImageManager.default().requestImageDataAndOrientation(for: asset, options: opt) { data, uti, _, _ in
            guard let data else {
                DispatchQueue.main.async { self.failSharePreparation() }
                return
            }
            // Write to a temp file off-main so the share sheet offers a real
            // image file with its metadata intact.
            DispatchQueue.global(qos: .userInitiated).async {
                let ext = uti.flatMap { UTType($0)?.preferredFilenameExtension } ?? "jpg"
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString)
                    .appendingPathExtension(ext)
                do {
                    try data.write(to: url)
                    DispatchQueue.main.async {
                        self.finishSharePreparation()
                        self.presentShareSheet(items: [url])
                    }
                } catch {
                    DispatchQueue.main.async { self.failSharePreparation() }
                }
            }
        }
    }

    private func shareImageWithNote() {
        showShareOptions = false
        guard let image = activeCard?.image else {
            failSharePreparation()
            return
        }
        guard let note = tagCache[activeCard?.asset.localIdentifier ?? ""]?.note,
              !note.isEmpty else {
            presentShareSheet(items: [image])
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

        // PHAsset.fetchAssets is synchronous Photos I/O — running it on the main
        // thread made every undo tap visibly stutter. Resolve it on a background
        // queue, then hop back to main for all UI/state work.
        DispatchQueue.global(qos: .userInitiated).async {
            let fetch = PHAsset.fetchAssets(withLocalIdentifiers: [lastAssetID], options: nil)
            let asset = fetch.firstObject
            DispatchQueue.main.async {
                guard self.isUndoRestoring else { return }
                // Verify the asset still exists BEFORE writing any tag — it may
                // have been physically deleted in the meantime.
                guard let asset else {
                    self.bannerTextKey = "undo.failed.deleted"
                    self.showBannerFor(seconds: 3)
                    self.isUndoRestoring = false
                    return
                }

                self.sessionProcessed.remove(lastAssetID)
                self.upsertTag(assetID: lastAssetID) { tag in
                    tag.status = "pending"
                    tag.createdAt = Date()
                }

                // The undone asset may belong to a previous source (e.g. an
                // earlier random day). Only restore it on stage — and count it —
                // when it's part of the current source.
                guard self.todayOrderByID[lastAssetID] != nil else {
                    self.bannerTextKey = "undo.restored.other"
                    self.showBannerFor(seconds: 3)
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    self.isUndoRestoring = false
                    return
                }

                self.todayPendingCount += 1
                self.writeWidgetCountDebounced(self.todayPendingCount)

                self.sourceRevision += 1
                let revision = self.sourceRevision
                self.cancelPendingImageRequests()
                // 也取消正在进行的视频请求，避免旧回调干扰
                self.cancelCurrentVideoRequests()
                self.videoCloudProgress = nil
                self.loadingIDs.removeAll()

                self.continueUndo(asset: asset, revision: revision)
            }
        }
    }

    private func continueUndo(asset: PHAsset, revision: Int) {
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

        // .opportunistic delivers degraded then full-res. One-time side effects
        // (media stop, zoom reset, haptics) must only run on the first delivery;
        // the upgrade just swaps the image in place.
        var isFirstDelivery = true
        loadCardState(for: asset) { card in
            DispatchQueue.main.async {
                undoTimeout.cancel()
                guard revision == self.sourceRevision else {
                    self.isUndoRestoring = false
                    return
                }
                let restoredID = card.asset.localIdentifier
                guard isFirstDelivery else {
                    if self.activeCard?.asset.localIdentifier == restoredID {
                        self.activeCard = card
                    }
                    return
                }
                isFirstDelivery = false

                self.stopAllMedia()
                self.resetImageZoom()
                self.settleOffset = .zero

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

            Spacer()
        }
        .frame(width: cardWidth, height: cardHeight)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(Color(.systemGray6))
        )
        .padding(20)
    }

    // MARK: - Goal achieved card (inline, same format as quota card)
    private var goalAchievedCard: some View {
        VStack(spacing: 18) {
            Spacer()

            Text("🎉")
                .font(.system(size: 52))

            VStack(spacing: 6) {
                Text("goal.title")
                    .font(.title3.bold())
                Text(String(format: "goal.subtitle".localized, storageStats.dailyPendingPeak.byteCountShort))
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }

            Text("goal.hint")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 4)

            Button {
                storageStats.dismissCelebrationToday()
            } label: {
                Text("goal.cta")
                    .font(.subheadline.bold())
                    .foregroundColor(.white)
                    .frame(maxWidth: 220)
                    .padding(.vertical, 12)
                    .background(Color.green)
                    .clipShape(Capsule())
            }

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

// MARK: - Month picker (browse any historical month)
/// Two-wheel year + month picker, constrained to the library's date range so the
/// user can only pick months that could actually contain photos.
private struct MonthPickerSheet: View {
    let bounds: (oldest: Date, newest: Date)?
    let initial: Date
    let onPick: (Date) -> Void

    @Environment(\.dismiss) private var dismiss
    private let calendar = Calendar.current

    @State private var year: Int
    @State private var month: Int

    init(bounds: (oldest: Date, newest: Date)?, initial: Date, onPick: @escaping (Date) -> Void) {
        self.bounds = bounds
        self.initial = initial
        self.onPick = onPick
        let cal = Calendar.current
        _year = State(initialValue: cal.component(.year, from: initial))
        _month = State(initialValue: cal.component(.month, from: initial))
    }

    private var years: [Int] {
        let currentYear = calendar.component(.year, from: initial)
        guard let bounds else { return Array((currentYear - 20)...currentYear) }
        let lo = calendar.component(.year, from: bounds.oldest)
        let hi = calendar.component(.year, from: bounds.newest)
        return Array(lo...max(lo, hi))
    }

    /// Months selectable in the chosen year, clamped to the library range so the
    /// edges (oldest / newest year) don't offer empty months.
    private var selectableMonths: [Int] {
        var lo = 1, hi = 12
        if let bounds {
            if year == calendar.component(.year, from: bounds.oldest) {
                lo = calendar.component(.month, from: bounds.oldest)
            }
            if year == calendar.component(.year, from: bounds.newest) {
                hi = calendar.component(.month, from: bounds.newest)
            }
        }
        guard lo <= hi else { return Array(1...12) }
        return Array(lo...hi)
    }

    private func monthName(_ m: Int) -> String {
        let df = DateFormatter()
        df.locale = .current
        let symbols = df.standaloneMonthSymbols ?? []
        return (m >= 1 && m <= symbols.count) ? symbols[m - 1] : "\(m)"
    }

    var body: some View {
        NavigationStack {
            HStack(spacing: 0) {
                Picker("", selection: $year) {
                    ForEach(years, id: \.self) { Text(String($0)).tag($0) }
                }
                .pickerStyle(.wheel)
                .frame(maxWidth: .infinity)

                Picker("", selection: $month) {
                    ForEach(selectableMonths, id: \.self) { Text(monthName($0)).tag($0) }
                }
                .pickerStyle(.wheel)
                .frame(maxWidth: .infinity)
            }
            .padding(.horizontal)
            .navigationTitle("filter.pick_month".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.cancel".localized) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("common.done".localized) {
                        var comp = DateComponents()
                        comp.year = year
                        comp.month = month
                        comp.day = 1
                        if let picked = calendar.date(from: comp) {
                            onPick(picked)
                        }
                        dismiss()
                    }
                }
            }
            .onChange(of: year) { _, _ in
                // Keep the month valid when switching to an edge year.
                if !selectableMonths.contains(month) {
                    month = selectableMonths.first ?? month
                }
            }
        }
    }
}
