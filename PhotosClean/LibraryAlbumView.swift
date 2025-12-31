import SwiftUI
import Photos
import PhotosUI
import SwiftData
import AVKit
import UIKit

// MARK: - CardState
struct CardState: Identifiable {
    let id = UUID()
    let asset: PHAsset
    let image: UIImage
}

// MARK: - LibraryCleanView
struct LibraryCleanView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \PhotoTag.createdAt, order: .reverse) private var allTags: [PhotoTag]

    let assets: [PHAsset]
    @State private var index: Int

    @State private var cardCache: [String: CardState] = [:]
    @State private var loadingIDs: Set<String> = []

    private let preloadForwardCount = 8
    private let preloadBackCount = 6

    @State private var tagCache: [String: PhotoTag] = [:]

    @State private var livePhoto: PHLivePhoto?
    @State private var isPlayingLivePhoto = false
    @State private var player: AVPlayer?
    @State private var isMuted = true
    @State private var currentVideoAssetID: String? = nil
    @State private var currentVideoRequestID: PHImageRequestID = PHInvalidImageRequestID
    @State private var currentVideoUpgradeRequestID: PHImageRequestID = PHInvalidImageRequestID
    @State private var videoCloudProgress: Double? = nil
    @State private var videoItemCache: [String: AVPlayerItem] = [:]
    @State private var videoRequestIDs: [String: PHImageRequestID] = [:]
    @State private var inFlightVideoIDs: Set<String> = []
    @State private var videoEndObserver: NSObjectProtocol?
    private let imageManager = PHCachingImageManager()

    @GestureState private var dragOffset: CGSize = .zero
    @State private var settleOffset: CGSize = .zero

    @State private var imageScale: CGFloat = 1.0
    @State private var zoomResetToken = UUID()
    private var isZooming: Bool { imageScale > 1.01 }

    @State private var showNoteEditor = false
    @State private var currentNote = ""
    @FocusState private var isNoteFocused: Bool

    @State private var showShareOptions = false
    @State private var showPreview = false
    @State private var previewImage: UIImage?
    
    @State private var isAnimatingOut = false
    private var isInteractionHeavyPhase: Bool { (dragOffset != .zero) || isAnimatingOut }

    init(assets: [PHAsset], initialIndex: Int) {
        self.assets = assets
        self._index = State(initialValue: initialIndex)
    }

    private var currentCardOffset: CGSize {
        CGSize(width: dragOffset.width + settleOffset.width, height: 0)
    }

    private var currentAsset: PHAsset? {
        guard assets.indices.contains(index) else { return nil }
        return assets[index]
    }

    private var currentAssetID: String? {
        currentAsset?.localIdentifier
    }

    private var currentCard: CardState? {
        guard let id = currentAssetID else { return nil }
        return cardCache[id]
    }

    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                ZStack {
                    ContentUnavailableView(
                        "library.done".localized,
                        systemImage: "checkmark.circle",
                        description: Text("library.finished".localized)
                    )
                    .opacity(currentAsset == nil ? 1 : 0)

                    if currentAsset != nil {
                        GeometryReader { geo in
                            cardStackView(containerSize: geo.size)
                                .frame(width: geo.size.width, height: geo.size.height)
                        }
                    }
                }

                Spacer()
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
        .onAppear {
            buildTagCache()
            preloadAroundIndex(force: true)
            syncNoteForCurrent()
            prepareMediaForCurrent()
        }
        .onDisappear {
            stopAllMedia()
            cancelAllVideoRequests()
        }
        .onChange(of: index) { _, _ in
            stopAllMedia()
            resetImageZoom()
            syncNoteForCurrent()
            preloadAroundIndex(force: false)
            prepareMediaForCurrent()
        }
    }

    // MARK: - Stack
    private func cardStackView(containerSize: CGSize) -> some View {
        let offsets = [-1, 0, 1]

        return ZStack {
            ForEach(offsets, id: \.self) { off in
                let targetIndex = index + off
                if assets.indices.contains(targetIndex) {
                    let asset = assets[targetIndex]
                    let id = asset.localIdentifier
                    let isTop = (off == 0)

                    let draggingX = currentCardOffset.width
                    let shouldShow: Bool = {
                        if isTop { return true }
                        if draggingX > 1 { return off == -1 }
                        if draggingX < -1 { return off == 1 }
                        return off == 1
                    }()

                    Group {
                        if let card = cardCache[id] {
                            mediaCardView(for: card, isInteractive: isTop, containerSize: containerSize)
                        } else {
                            placeholderCard(containerSize: containerSize)
                                .onAppear { loadCardStateIfNeeded(for: asset) }
                        }
                    }
                    .offset(x: isTop ? currentCardOffset.width : 0, y: 0)
                    .opacity(shouldShow ? 1 : 0)
                    .zIndex(isTop ? 2 : (off == 1 ? 1 : 0))
                    .allowsHitTesting(isTop && !isAnimatingOut && cardCache[id] != nil)
                    .highPriorityGesture(isTop ? cardGesture() : nil)
                }
            }
        }
    }

    private func placeholderCard(containerSize: CGSize) -> some View {
        ZStack {
            Color(.secondarySystemBackground)
            ProgressView()
        }
        .frame(width: containerSize.width, height: containerSize.height)
        .clipped()
    }

    // MARK: - Gesture
    private enum SwipeDirection { case next, previous }

    private func cardGesture() -> some Gesture {
        DragGesture(minimumDistance: 8)
            .updating($dragOffset) { value, state, _ in
                guard !isAnimatingOut, !isZooming else { return }
                state = CGSize(width: value.translation.width, height: 0)
            }
            .onChanged { _ in
                guard !isZooming else { return }
                settleOffset = .zero
            }
            .onEnded { value in
                guard !isAnimatingOut else { return }

                let t = CGSize(width: value.translation.width, height: 0)

                guard !isZooming else {
                    bounceBack(from: t)
                    return
                }

                let threshold: CGFloat = 80
                if t.width > threshold && index > 0 {
                    commitSwipe(.previous, from: t)
                } else if t.width < -threshold && index < assets.count - 1 {
                    commitSwipe(.next, from: t)
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

    private func commitSwipe(_ dir: SwipeDirection, from t: CGSize) {
        isAnimatingOut = true
        settleOffset = t

        let targetX: CGFloat = (dir == .next) ? -UIScreen.main.bounds.width * 2 : UIScreen.main.bounds.width * 2
        withAnimation(.easeOut(duration: 0.22)) {
            settleOffset = CGSize(width: targetX, height: 0)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
            var tx = Transaction()
            tx.disablesAnimations = true
            withTransaction(tx) {
                switch dir {
                case .next: self.index += 1
                case .previous: self.index -= 1
                }
                self.settleOffset = .zero
                self.isAnimatingOut = false
            }
        }
    }

    // MARK: - Media Card
    @ViewBuilder
    private func mediaCardView(for card: CardState, isInteractive: Bool, containerSize: CGSize) -> some View {
        let useStaticPreview = isInteractionHeavyPhase || !isInteractive

        ZStack {
            Color.black.opacity(0.95)

                if useStaticPreview {
                    Image(uiImage: card.image)
                    .resizable()
                    .interpolation(.medium)
                    .antialiased(true)
                    .scaledToFit()
                    .frame(width: containerSize.width, height: containerSize.height)
                    .clipped()
                } else {
                    if card.asset.mediaType == .video {
                        if let player = player {
                            StableVideoPlayerView(player: player, isMuted: isMuted)
                                .frame(width: containerSize.width, height: containerSize.height)
                                .clipped()
                        } else {
                        ZStack {
                            Color.black.opacity(0.95)
                            if let videoCloudProgress {
                                VStack(spacing: 10) {
                                    ProgressView(value: max(0, min(videoCloudProgress, 1)))
                                        .progressViewStyle(.linear)
                                        .tint(.white)
                                        .frame(width: 140)
                                    ProgressView()
                                }
                            } else {
                                ProgressView()
                            }
                        }
                        .frame(width: containerSize.width, height: containerSize.height)
                        .clipped()
                        .onAppear { loadVideo(for: card.asset) }
                    }
                } else {
                    if isInteractive, isPlayingLivePhoto, let livePhoto {
                        LivePhotoView(livePhoto: livePhoto, isPlaying: $isPlayingLivePhoto)
                            .frame(width: containerSize.width, height: containerSize.height)
                            .clipped()
                    } else {
                        ZoomableImageView(
                            image: card.image,
                            zoomScale: $imageScale,
                            minScale: 1.0,
                            maxScale: 4.0,
                            resetToken: zoomResetToken
                        )
                        .frame(width: containerSize.width, height: containerSize.height)
                        .clipped()
                    }
                }
            }

            // Buttons
            if isInteractive && !isInteractionHeavyPhase {
                VStack {
                    HStack {
                        Spacer()

                        if card.asset.mediaSubtypes.contains(.photoLive) {
                            Button(action: toggleLivePhoto) {
                                Image(systemName: isPlayingLivePhoto ? "stop.circle.fill" : "livephoto")
                                    .padding(12)
                                    .background(.ultraThinMaterial)
                                    .clipShape(Circle())
                            }
                        }

                        Button(action: openNoteEditor) {
                            Image(systemName: "note.text")
                                .padding(12)
                                .background(.ultraThinMaterial)
                                .foregroundColor(hasNoteForCurrentAsset() ? .orange : .primary)
                                .clipShape(Circle())
                        }

                        Button(action: { showShareOptions = true }) {
                            Image(systemName: "square.and.arrow.up")
                                .padding(12)
                                .background(.ultraThinMaterial)
                                .clipShape(Circle())
                        }
                    }
                    .padding()

                    Spacer()

                    if card.asset.mediaType == .video {
                        HStack {
                            Spacer()
                            Button {
                                isMuted.toggle()
                                player?.isMuted = isMuted

                                guard let player = player else { return }
                                // Only hold audio focus while playing *and* unmuted.
                                if player.timeControlStatus == .playing {
                                    if isMuted {
                                        AudioSessionManager.endVideoAudio()
                                    } else {
                                        AudioSessionManager.beginVideoAudio(policy: .duck)
                                    }
                                }
                            } label: {
                                Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                                    .padding(12)
                                    .background(.ultraThinMaterial)
                                    .clipShape(Circle())
                            }
                            .padding()
                        }
                    }
                }
            }

            // Classification
            if isInteractive && !isInteractionHeavyPhase {
                VStack {
                    Spacer()
                    HStack {
                        Button(action: cycleClassificationNoNilAfterFirstTap) {
                            classificationIndicator(status: currentStatus)
                                .frame(width: 52, height: 52)
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .padding(16)

                        Spacer()
                    }
                }
            }
        }
        .frame(width: containerSize.width, height: containerSize.height)
        .clipped()
    }

    // MARK: - Classification
    private var currentStatus: String? {
        guard let id = currentAssetID else { return nil }
        let s = tagCache[id]?.status
        if s == nil || s == "pending" { return nil }
        return s
    }

    private func statusColor(_ status: String) -> Color {
        switch status {
        case "keep": return .green
        case "delete": return .red
        case "maybe": return .yellow
        default: return .gray
        }
    }

    private func classificationIndicator(status: String?) -> some View {
        let size: CGFloat = 26
        return ZStack {
            Circle()
                .fill(Color.primary.opacity(0.001))
                .frame(width: size + 22, height: size + 22)

            Circle()
                .stroke(Color.primary.opacity(0.85), lineWidth: 2)
                .frame(width: size, height: size)

            if let status {
                Circle()
                    .fill(statusColor(status))
                    .frame(width: size - 6, height: size - 6)
            }
        }
        .shadow(radius: 2)
    }

    private func cycleClassificationNoNilAfterFirstTap() {
        guard let id = currentAssetID else { return }

        let raw = tagCache[id]?.status
        let current: String? = (raw == nil || raw == "pending") ? nil : raw

        let next: String
        if current == nil {
            next = "delete"
        } else {
            switch current {
            case "delete": next = "maybe"
            case "maybe":  next = "keep"
            case "keep":   next = "delete"
            default:       next = "delete"
            }
        }

        upsertTag(assetID: id) { tag in
            tag.status = next
        }

        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    // MARK: - Zoom reset
    private func resetImageZoom() {
        imageScale = 1.0
        zoomResetToken = UUID()
    }

    // MARK: - Preload
    private func preloadAroundIndex(force: Bool) {
        guard assets.indices.contains(index) else { return }

        let start = max(0, index - preloadBackCount)
        let end = min(assets.count - 1, index + preloadForwardCount)

        for i in start...end {
            loadCardStateIfNeeded(for: assets[i])
        }

        if !force {
            let keepFrom = max(0, index - preloadBackCount - 10)
            let keepTo = min(assets.count - 1, index + preloadForwardCount + 10)
            let keepIDs = Set((keepFrom...keepTo).map { assets[$0].localIdentifier })
            cardCache = cardCache.filter { keepIDs.contains($0.key) }
        }
    }

    private func loadCardStateIfNeeded(for asset: PHAsset) {
        let id = asset.localIdentifier
        if cardCache[id] != nil { return }
        if loadingIDs.contains(id) { return }
        loadingIDs.insert(id)

        loadCardState(for: asset) { card in
            DispatchQueue.main.async {
                self.loadingIDs.remove(id)
                self.cardCache[id] = card
            }
        }
    }

    private func loadCardState(for asset: PHAsset, completion: @escaping (CardState) -> Void) {
        let scale = UIScreen.main.scale
        let screen = UIScreen.main.bounds.size
        let target = CGSize(width: screen.width * scale, height: screen.height * scale)

        let opt = PHImageRequestOptions()
        opt.isNetworkAccessAllowed = true
        opt.deliveryMode = .highQualityFormat
        opt.resizeMode = .exact
        opt.version = .current

        PHImageManager.default().requestImage(
            for: asset,
            targetSize: target,
            contentMode: .aspectFit,
            options: opt
        ) { img, info in
            if let cancelled = info?[PHImageCancelledKey] as? Bool, cancelled { return }
            if let degraded = info?[PHImageResultIsDegradedKey] as? Bool, degraded { return }
            completion(CardState(asset: asset, image: img ?? UIImage()))
        }
    }

    // MARK: - Media
    private func prepareMediaForCurrent() {
        guard let asset = currentAsset else { return }
        if asset.mediaType == .video { loadVideo(for: asset) }
        prefetchNearbyVideos()
    }

    private func stopAllMedia() {
        AudioSessionManager.endVideoAudio()
        cancelCurrentVideoRequests()
        player?.pause()
        player?.replaceCurrentItem(with: nil)
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

    private func toggleLivePhoto() {
        guard let asset = currentAsset else { return }
        guard asset.mediaSubtypes.contains(.photoLive) else { return }

        if isPlayingLivePhoto {
            isPlayingLivePhoto = false
            return
        }

        let scale = UIScreen.main.scale
        let screen = UIScreen.main.bounds.size
        let target = CGSize(width: screen.width * scale, height: screen.height * scale)

        let opt = PHLivePhotoRequestOptions()
        opt.isNetworkAccessAllowed = true
        opt.deliveryMode = .highQualityFormat

        PHImageManager.default().requestLivePhoto(
            for: asset,
            targetSize: target,
            contentMode: .aspectFit,
            options: opt
        ) { live, info in
            if let degraded = info?[PHImageResultIsDegradedKey] as? Bool, degraded { return }

            DispatchQueue.main.async {
                self.livePhoto = live
                self.isPlayingLivePhoto = (live != nil)
            }
        }
    }

    private func loadVideo(for asset: PHAsset) {
        guard asset.mediaType == .video else { return }
        let id = asset.localIdentifier
        if currentVideoAssetID == id, player != nil { return }
        currentVideoAssetID = id
        videoCloudProgress = nil
        cancelCurrentVideoRequests()

        if let cached = videoItemCache[id] {
            DispatchQueue.main.async {
                self.usePlayerItem(cached, preservePlaybackState: false)
            }
            return
        }
        requestCurrentVideoLocalFirst(for: asset)
    }

    private func requestCurrentVideoLocalFirst(for asset: PHAsset) {
        let id = asset.localIdentifier
        let opt = PHVideoRequestOptions()
        opt.isNetworkAccessAllowed = false
        opt.deliveryMode = .fastFormat
        opt.version = .current

        currentVideoRequestID = imageManager.requestPlayerItem(forVideo: asset, options: opt) { item, info in
            DispatchQueue.main.async {
                guard self.currentVideoAssetID == id else { return }
                self.currentVideoRequestID = PHInvalidImageRequestID
                if let cancelled = info?[PHImageCancelledKey] as? Bool, cancelled { return }

                if let item {
                    self.videoItemCache[id] = item
                    self.usePlayerItem(item, preservePlaybackState: false)
                } else {
                    self.requestCurrentVideoFastNetwork(for: asset)
                }
            }
        }
    }

    private func requestCurrentVideoFastNetwork(for asset: PHAsset) {
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

                self.videoItemCache[id] = item
                if self.videoItemCache.count > 6 {
                    self.trimVideoCache(keepingAtMost: 6)
                }

                self.usePlayerItem(item, preservePlaybackState: false)
                self.requestCurrentVideoHighQualityUpgrade(for: asset)
            }
        }
    }

    private func requestCurrentVideoHighQualityUpgrade(for asset: PHAsset) {
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

                self.videoItemCache[id] = item
                self.usePlayerItem(item, preservePlaybackState: true)
            }
        }
    }

    private func usePlayerItem(_ item: AVPlayerItem, preservePlaybackState: Bool) {
        if let obs = videoEndObserver {
            NotificationCenter.default.removeObserver(obs)
            videoEndObserver = nil
        }

        let p: AVPlayer
        var resumeTime: CMTime = .zero
        var shouldResume = true

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

        if shouldResume, !isMuted {
            AudioSessionManager.beginVideoAudio(policy: .duck)
        } else if !shouldResume {
            AudioSessionManager.endVideoAudio()
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

        if shouldResume {
            p.play()
        } else {
            p.pause()
        }
    }

    private func prefetchNearbyVideos() {
        var candidates: [PHAsset] = []
        let nextIndex = index + 1
        let previousIndex = index - 1
        if assets.indices.contains(nextIndex) { candidates.append(assets[nextIndex]) }
        if assets.indices.contains(previousIndex) { candidates.append(assets[previousIndex]) }

        let unique = Dictionary(grouping: candidates, by: { $0.localIdentifier }).compactMap { $0.value.first }
        let keepIDs = Set(unique.map(\.localIdentifier))
        cancelStaleVideoRequests(keeping: keepIDs)

        for asset in unique where asset.mediaType == .video {
            let id = asset.localIdentifier
            if videoItemCache[id] != nil { continue }
            requestVideoItem(for: asset, attachToPlayerIfCurrent: false)
        }
    }

    private func requestVideoItem(for asset: PHAsset, attachToPlayerIfCurrent: Bool) {
        let id = asset.localIdentifier
        if inFlightVideoIDs.contains(id) { return }
        inFlightVideoIDs.insert(id)

        let opt = PHVideoRequestOptions()
        opt.isNetworkAccessAllowed = true
        opt.deliveryMode = .fastFormat

        let requestID = imageManager.requestPlayerItem(forVideo: asset, options: opt) { item, info in
            DispatchQueue.main.async {
                self.inFlightVideoIDs.remove(id)
                self.videoRequestIDs.removeValue(forKey: id)

                if let cancelled = info?[PHImageCancelledKey] as? Bool, cancelled { return }
                guard let item else { return }

                self.videoItemCache[id] = item
                if self.videoItemCache.count > 6 {
                    self.trimVideoCache(keepingAtMost: 6)
                }

                if attachToPlayerIfCurrent, self.currentVideoAssetID == id {
                    self.usePlayerItem(item, preservePlaybackState: false)
                }
            }
        }
        videoRequestIDs[id] = requestID
    }

    private func cancelStaleVideoRequests(keeping keepIDs: Set<String>) {
        for (id, requestID) in Array(videoRequestIDs) where !keepIDs.contains(id) {
            imageManager.cancelImageRequest(requestID)
            videoRequestIDs.removeValue(forKey: id)
            inFlightVideoIDs.remove(id)
        }
    }

    private func trimVideoCache(keepingAtMost limit: Int) {
        guard videoItemCache.count > limit else { return }
        let keepIDs = Set([
            currentAssetID,
            assets.indices.contains(index + 1) ? assets[index + 1].localIdentifier : nil,
            assets.indices.contains(index - 1) ? assets[index - 1].localIdentifier : nil
        ].compactMap { $0 })

        for key in Array(videoItemCache.keys) where !keepIDs.contains(key) {
            videoItemCache.removeValue(forKey: key)
            if videoItemCache.count <= limit { break }
        }
    }

    private func cancelAllVideoRequests() {
        cancelCurrentVideoRequests()
        for requestID in videoRequestIDs.values {
            imageManager.cancelImageRequest(requestID)
        }
        videoRequestIDs.removeAll()
        inFlightVideoIDs.removeAll()
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

    // MARK: - Note
    private func openNoteEditor() { showNoteEditor = true }

    private var noteEditorOverlay: some View {
        ZStack {
            Color.black.opacity(0.35)
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
        guard let id = currentAssetID else { return }
        upsertTag(assetID: id) { tag in
            tag.note = currentNote
        }
        closeNoteEditor()
    }

    private func syncNoteForCurrent() {
        guard let id = currentAssetID else { currentNote = ""; return }
        currentNote = tagCache[id]?.note ?? ""
    }

    private func hasNoteForCurrentAsset() -> Bool {
        guard let id = currentAssetID else { return false }
        return tagCache[id]?.note?.isEmpty == false
    }

    // MARK: - Share Options
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

    // MARK: - Share Functions
    private func shareOriginalImage() {
        showShareOptions = false
        guard let asset = currentAsset else { return }

        if asset.mediaType == .video {
            let opt = PHVideoRequestOptions()
            opt.isNetworkAccessAllowed = true
            PHImageManager.default().requestAVAsset(forVideo: asset, options: opt) { av, _, _ in
                guard let url = (av as? AVURLAsset)?.url else { return }
                DispatchQueue.main.async {
                    presentShareSheet(items: [url])
                }
            }
        } else if let image = currentCard?.image {
            presentShareSheet(items: [image])
        }
    }

    private func shareImageWithNote() {
        showShareOptions = false
        guard let image = currentCard?.image,
              let note = tagCache[currentAssetID ?? ""]?.note,
              !note.isEmpty else {
            presentShareSheet(items: [currentCard?.image ?? UIImage()])
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

        // 计算文本大小
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

        // 计算卡片底部区域高度
        let bottomHeight = textRect.height + topBottomPadding * 2
        let totalHeight = imageSize.height + bottomHeight

        let rect = CGRect(x: 0, y: 0, width: imageSize.width, height: totalHeight)

        UIGraphicsBeginImageContextWithOptions(rect.size, true, 0)
        defer { UIGraphicsEndImageContext() }

        
        UIColor(red: 0.97, green: 0.97, blue: 0.97, alpha: 1.0).setFill()
            UIRectFill(rect)

        // 绘制上面的图片
        image.draw(at: CGPoint(x: 0, y: 0))

        // 下方文字区域背景
        let bottomRect = CGRect(x: 0, y: imageSize.height, width: imageSize.width, height: bottomHeight)
        UIColor.white.setFill()
        UIRectFill(bottomRect)

        // 绘制文字
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

    private func presentShareSheet(items: [Any]) {
        let vc = UIActivityViewController(activityItems: items, applicationActivities: nil)
        UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.windows.first?.rootViewController }
            .first?
            .present(vc, animated: true)
    }

    // MARK: - Preview
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

    // MARK: - Tags DB
    private func buildTagCache() {
        var map: [String: PhotoTag] = [:]
        map.reserveCapacity(allTags.count)
        for tag in allTags where map[tag.assetID] == nil {
            map[tag.assetID] = tag
        }
        tagCache = map
    }

    private func upsertTag(assetID: String, mutate: (PhotoTag) -> Void) {
        let tag: PhotoTag
        if let existing = tagCache[assetID] {
            tag = existing
        } else {
            tag = PhotoTag(assetID: assetID, status: "pending")
            tag.createdAt = Date()
            modelContext.insert(tag)
            tagCache[assetID] = tag
        }

        mutate(tag)
        try? modelContext.save()
        tagCache[assetID] = tag
    }
}
