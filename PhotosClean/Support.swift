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
struct LivePhotoView: UIViewRepresentable {
    let livePhoto: PHLivePhoto
    @Binding var isPlaying: Bool
    
    func makeUIView(context: Context) -> PHLivePhotoView {
        let view = PHLivePhotoView()
        view.contentMode = .scaleAspectFit
        return view
    }
    
    func updateUIView(_ uiView: PHLivePhotoView, context: Context) {
        uiView.livePhoto = livePhoto
        
        if isPlaying {
            uiView.startPlayback(with: .full)
        } else {
            uiView.stopPlayback()
        }
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
            let edgeThreshold: CGFloat = 60

            if offsetX < -edgeThreshold {
                // 拖过左边缘 → 向右划 → 上一张
                parent.onEdgeSwipe?(abs(offsetX))
            } else if maxOffsetX > 0, offsetX > maxOffsetX + edgeThreshold {
                // 拖过右边缘 → 向左划 → 下一张
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
        return controller
    }

    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {
        if uiViewController.player !== player {
            uiViewController.player = player
        }
        uiViewController.player?.isMuted = isMuted
    }
}
