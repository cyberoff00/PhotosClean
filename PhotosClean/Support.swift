//
//  Support.swift
//  PhotosClean
//
//  Created by Claire Yang on 05/01/2026.
//
import SwiftUI
import Photos
import AVKit
import UIKit
import PhotosUI
/// PHLivePhotoView that only begins playback once it has a non-zero layout.
/// `startPlayback(with:)` captures the view geometry at the moment it's called,
/// so starting it while SwiftUI hasn't laid the view out yet (bounds == .zero)
/// makes iOS render the Live Photo shrunk into a small centered patch. Tapping a
/// freshly-loaded Live Photo auto-plays in the same state update that mounts this
/// view, which is exactly when bounds are still zero — hence the intermittent
/// "plays tiny in the middle" bug. Deferring the start to `layoutSubviews` (when
/// bounds are valid) fixes it regardless of caller timing.
final class PlaybackLivePhotoView: PHLivePhotoView {
    var wantsPlayback = false { didSet { syncPlayback() } }
    private var startedPlayback = false

    override func layoutSubviews() {
        super.layoutSubviews()
        syncPlayback()
    }

    /// Call after assigning a new `livePhoto` so playback can (re)start cleanly.
    func livePhotoDidChange() {
        if startedPlayback {
            stopPlayback()
            startedPlayback = false
        }
        syncPlayback()
    }

    private func syncPlayback() {
        if wantsPlayback {
            guard bounds.width > 1, bounds.height > 1 else { return }
            if !startedPlayback {
                startedPlayback = true
                startPlayback(with: .full)
            }
        } else if startedPlayback {
            startedPlayback = false
            stopPlayback()
        }
    }
}

struct LivePhotoView: UIViewRepresentable {
    let livePhoto: PHLivePhoto
    @Binding var isPlaying: Bool

    func makeUIView(context: Context) -> PlaybackLivePhotoView {
        let view = PlaybackLivePhotoView()
        view.contentMode = .scaleAspectFit
        return view
    }

    func updateUIView(_ uiView: PlaybackLivePhotoView, context: Context) {
        if uiView.livePhoto !== livePhoto {
            uiView.livePhoto = livePhoto
            uiView.livePhotoDidChange()
        }
        uiView.wantsPlayback = isPlaying
    }
}
struct ControlButton: View {
    let icon: String
    var color: Color = .primary
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .padding(12)
                .background(.ultraThinMaterial)
                .foregroundColor(color)
                .clipShape(Circle())
        }
    }
}
import SwiftUI

// MARK: - 可缩放图片视图
/// 特点：
/// - 以手指为中心缩放
/// - 放大后可拖动平移
/// - 支持外部重置缩放状态
/// - 避免与外层手势冲突
struct ZoomableImageView: UIViewRepresentable {
    let image: UIImage
    @Binding var zoomScale: CGFloat
    var minScale: CGFloat = 1.0
    var maxScale: CGFloat = 4.0
    var resetToken: UUID
    /// Called when user pans past the horizontal edge while zoomed in.
    /// Positive = swiped right (go previous), negative = swiped left (go next).
    var onEdgeSwipe: ((CGFloat) -> Void)?
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.delegate = context.coordinator
        scrollView.minimumZoomScale = minScale
        scrollView.maximumZoomScale = maxScale
        scrollView.zoomScale = minScale
        scrollView.bouncesZoom = true
        scrollView.bounces = true
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.decelerationRate = .fast
        scrollView.backgroundColor = .clear
        
        // 重要：默认不允许滚动（避免抢外层 swipe）
        scrollView.isScrollEnabled = false
        
        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFit
        imageView.frame = scrollView.bounds
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        imageView.isUserInteractionEnabled = true
        scrollView.addSubview(imageView)
        
        context.coordinator.imageView = imageView
        return scrollView
    }
    
    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        // Keep coordinator in sync with latest closures and bindings
        context.coordinator.parent = self

        // 更新图片
        context.coordinator.imageView?.image = image
        
        // 外部触发 reset
        if context.coordinator.lastResetToken != resetToken {
            context.coordinator.lastResetToken = resetToken
            scrollView.setZoomScale(minScale, animated: false)
            scrollView.setContentOffset(.zero, animated: false)
            scrollView.isScrollEnabled = false
            DispatchQueue.main.async {
                self.zoomScale = minScale
            }
        }
        
        // 外部设 zoomScale（一般用不到，但保留同步）
        if abs(scrollView.zoomScale - zoomScale) > 0.02 {
            scrollView.setZoomScale(zoomScale, animated: false)
        }
    }
    
    // MARK: - Coordinator
    final class Coordinator: NSObject, UIScrollViewDelegate {
        var parent: ZoomableImageView
        weak var imageView: UIImageView?
        var lastResetToken: UUID?

        init(_ parent: ZoomableImageView) {
            self.parent = parent
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            imageView
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            // 只有放大后才允许 scrollView 滚动（图片平移）
            let enable = scrollView.zoomScale > 1.01
            if scrollView.isScrollEnabled != enable {
                scrollView.isScrollEnabled = enable
            }
            DispatchQueue.main.async {
                self.parent.zoomScale = scrollView.zoomScale
            }
        }

        func scrollViewDidEndZooming(_ scrollView: UIScrollView,
                                     with view: UIView?,
                                     atScale scale: CGFloat) {
            let enable = scale > 1.01
            scrollView.isScrollEnabled = enable
            DispatchQueue.main.async {
                self.parent.zoomScale = scale
            }
        }

        func scrollViewDidEndDragging(_ scrollView: UIScrollView,
                                      willDecelerate decelerate: Bool) {
            guard scrollView.zoomScale > 1.01 else { return }

            let offsetX = scrollView.contentOffset.x
            let maxOffsetX = scrollView.contentSize.width - scrollView.bounds.width
            let edgeThreshold: CGFloat = 15

            if offsetX < -edgeThreshold {
                parent.onEdgeSwipe?(abs(offsetX))
            } else if maxOffsetX > 0, offsetX > maxOffsetX + edgeThreshold {
                parent.onEdgeSwipe?(-(offsetX - maxOffsetX))
            }
        }
    }
}


struct ActionButton: View {
    let icon: String
    let color: Color
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundColor(.white)
                .frame(width: 52, height: 52)
                .background(color)
                .clipShape(Circle())
        }
    }
}
import Foundation

enum L10n {
    static func fmt(_ key: String, _ args: CVarArg...) -> String {
        let format = NSLocalizedString(key, comment: "")
        return String(format: format, locale: Locale.current, arguments: args)
    }
}

// MARK: - StableVideoPlayerView
/// 使用系统 AVPlayerViewController，提供可拖拽进度条与系统播放控件。
/// 通过 Representable 承载，仍由外层控制 player 生命周期。
struct StableVideoPlayerView: UIViewControllerRepresentable {
    let player: AVPlayer
    var isMuted: Bool
    /// Fired when the current item reaches `.readyToPlay` (a frame is decodable),
    /// so the caller can drop the poster cover instead of flashing a black frame.
    var onReadyForDisplay: (() -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.videoGravity = .resizeAspect
        controller.showsPlaybackControls = true
        controller.entersFullScreenWhenPlaybackBegins = false
        controller.exitsFullScreenWhenPlaybackEnds = false
        controller.canStartPictureInPictureAutomaticallyFromInline = false
        controller.allowsPictureInPicturePlayback = false
        controller.updatesNowPlayingInfoCenter = false
        controller.view.backgroundColor = .clear
        player.isMuted = isMuted
        context.coordinator.onReady = onReadyForDisplay
        context.coordinator.observe(player: player)
        return controller
    }

    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {
        context.coordinator.onReady = onReadyForDisplay
        if uiViewController.player !== player {
            uiViewController.player = player
            context.coordinator.observe(player: player)
        }
        uiViewController.player?.isMuted = isMuted
    }

    final class Coordinator {
        var onReady: (() -> Void)?
        private var currentItemObs: NSKeyValueObservation?
        private var statusObs: NSKeyValueObservation?

        func observe(player: AVPlayer) {
            currentItemObs = player.observe(\.currentItem, options: [.initial, .new]) { [weak self] p, _ in
                self?.attach(to: p.currentItem)
            }
        }

        private func attach(to item: AVPlayerItem?) {
            statusObs?.invalidate()
            statusObs = nil
            guard let item else { return }
            if item.status == .readyToPlay {
                notifyReady()
                return
            }
            statusObs = item.observe(\.status, options: [.new]) { [weak self] it, _ in
                if it.status == .readyToPlay { self?.notifyReady() }
            }
        }

        private func notifyReady() {
            if Thread.isMainThread {
                onReady?()
            } else {
                DispatchQueue.main.async { [weak self] in self?.onReady?() }
            }
        }
    }
}

// MARK: - PhotoLibraryAuth
/// Centralized Photos library authorization for .readWrite (required to delete assets).
/// iOS defaults to .addOnly when the app never explicitly requests .readWrite — and
/// PHAssetChangeRequest.deleteAssets silently fails with success=false in that case.
enum PhotoLibraryAuth {
    static var canWrite: Bool {
        PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized
    }

    /// True when Photos access is blocked by Screen Time / MDM "Content & Privacy
    /// Restrictions". In this state iOS hides the per-app Photos toggle from
    /// Settings entirely, so sending the user to the app's settings page is
    /// useless — they must lift the restriction in Screen Time → Content &
    /// Privacy Restrictions → Photos instead.
    static var isRestricted: Bool {
        PHPhotoLibrary.authorizationStatus(for: .readWrite) == .restricted
    }

    /// Requests .readWrite access. Returns true only when the user grants full access.
    /// `.limited` returns false because deleteAssets is not honored under limited access.
    static func requestWriteAccess(_ completion: @escaping (Bool) -> Void) {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        switch status {
        case .authorized:
            completion(true)
        case .notDetermined:
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { newStatus in
                DispatchQueue.main.async { completion(newStatus == .authorized) }
            }
        default:
            completion(false)
        }
    }

    static func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

// MARK: - ForegroundGate
/// Gates work until the UI can actually present a system dialog.
///
/// PHAssetChangeRequest.deleteAssets makes iOS present its OWN "Delete N Photos?"
/// confirmation — we don't present it, the system does, on the active scene's key
/// window. UIKit silently drops that presentation in two situations:
///   1. The scene isn't foreground-active (the beat right after a permission
///      prompt dismisses, or the app was backgrounded during our async fetch) —
///      iOS then holds/drops the confirmation, which is how users get "nothing
///      happened" followed by a pile of dialogs on the next launch.
///   2. Another presentation is mid-transition — a Menu collapsing or an alert/
///      sheet animating away. Firing performChanges into that window makes UIKit
///      refuse the confirmation, so it never appears and the completion never runs.
///
/// runWhenReady waits out both: it fires only once the app is active AND nothing
/// is mid-transition. Must be called on the main thread.
enum ForegroundGate {
    /// Key window of the foreground-active scene.
    private static var keyWindow: UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }?
            .windows.first { $0.isKeyWindow }
    }

    /// True while any controller in the presentation chain is being presented or
    /// dismissed (Menu collapsing, alert/sheet appearing or going away).
    private static var isPresentationSettling: Bool {
        guard var vc = keyWindow?.rootViewController else { return false }
        while true {
            if vc.isBeingPresented || vc.isBeingDismissed { return true }
            guard let next = vc.presentedViewController else { return false }
            vc = next
        }
    }

    /// Runs `block` once the app is foreground-active and no presentation
    /// transition is in flight, retrying frame by frame until ready (capped at
    /// ~3s). If it never settles in time, falls back to firing on the next
    /// activation so the work is deferred rather than dropped.
    static func runWhenReady(_ block: @escaping () -> Void, remainingFrames: Int = 180) {
        if UIApplication.shared.applicationState == .active && !isPresentationSettling {
            block()
            return
        }
        guard remainingFrames > 0 else {
            runWhenActive(block)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 60.0) {
            runWhenReady(block, remainingFrames: remainingFrames - 1)
        }
    }

    /// Runs `block` immediately if foreground-active, otherwise exactly once the
    /// next time the app becomes active.
    static func runWhenActive(_ block: @escaping () -> Void) {
        if UIApplication.shared.applicationState == .active {
            block()
            return
        }
        var token: NSObjectProtocol?
        token = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            if let token { NotificationCenter.default.removeObserver(token) }
            block()
        }
    }
}
