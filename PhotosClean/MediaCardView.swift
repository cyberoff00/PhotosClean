import SwiftUI
import Photos
import AVKit
import UIKit
import PhotosUI

// MARK: - MediaCardView (Display-only, no swipe gesture)
struct MediaCardView: View {
    let asset: PHAsset
    let displayImage: UIImage?

    @Binding var livePhoto: PHLivePhoto?
    @Binding var isPlayingLivePhoto: Bool

    // Zoom (outer uses zoomScale to disable swipe)
    @Binding var zoomScale: CGFloat
    let zoomResetToken: UUID

    @Binding var player: AVPlayer?
    @Binding var isMuted: Bool
    let videoCloudProgress: Double?

    // hints from outer
    let isDragging: Bool
    let isAnimatingOut: Bool

    // actions
    let onLoadVideo: () -> Void
    let onToggleLive: () -> Void
    let onShare: () -> Void
    let onOpenNote: () -> Void
    let hasNote: Bool

    @State private var isVideoLoaded = false

    private let cardWidth = UIScreen.main.bounds.width - 40
    private var cardHeight: CGFloat { (UIScreen.main.bounds.width - 40) * 4 / 3 }

    private var isHeavyPhase: Bool { isAnimatingOut || isDragging }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 20)
                .fill(Color(.systemGray6))

            // 1) 重内容永远保留：ZoomableImageView / VideoPlayer 不销毁
            interactiveLayer
                .opacity(isHeavyPhase ? 0.001 : 1)
                .allowsHitTesting(!isHeavyPhase)

            // 2) 拖动时只盖静态预览（轻量）
            staticPreviewLayer
                .opacity(isHeavyPhase ? 1 : 0)
                .allowsHitTesting(false)

            // 3) 控件只在非 heavy phase 显示
            if !isHeavyPhase {
                liveBadgeBottomLeft
                controlsTopRight
                videoMuteBottomRight
            }
        }
        .frame(width: cardWidth, height: cardHeight)
        .background(Color(.systemGray6).cornerRadius(20))
        .shadow(color: Color.black.opacity(0.1),
                radius: isHeavyPhase ? 0 : 10, x: 0, y: 5)
        .onChange(of: asset.localIdentifier) { _, _ in
            isVideoLoaded = false
        }
    }

    // MARK: - Interactive layer (always alive)
    @ViewBuilder
    private var interactiveLayer: some View {
        Group {
            if asset.mediaType == .video {
                videoLayer
            } else if let img = displayImage {
                photoLayer(image: img)
            } else {
                ProgressView()
            }
        }
        .frame(width: cardWidth, height: cardHeight)
        .clipped()
        .overlay {
            if isPlayingLivePhoto, let live = livePhoto {
                LivePhotoView(livePhoto: live, isPlaying: $isPlayingLivePhoto)
                    .allowsHitTesting(false)
            }
        }
    }

    // MARK: - Static preview (for heavy phase overlay)
    @ViewBuilder
    private var staticPreviewLayer: some View {
        if let img = displayImage {
            Image(uiImage: img)
                .resizable()
                .interpolation(.medium)
                .antialiased(true)
                .aspectRatio(contentMode: .fit)
                .padding(12)
                .frame(width: cardWidth, height: cardHeight)
                .clipped()
        } else {
            ZStack {
                Color(.systemGray5)
                ProgressView()
            }
            .padding(12)
            .frame(width: cardWidth, height: cardHeight)
            .clipped()
        }
    }

    // MARK: - Video
    @ViewBuilder
    private var videoLayer: some View {
        if let p = player {
            StableVideoPlayerView(player: p, isMuted: isMuted)
            .padding(12)
        } else {
            ZStack {
                Color(.systemGray5)
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
            .padding(12)
            .onAppear {
                if !isVideoLoaded {
                    isVideoLoaded = true
                    onLoadVideo()
                }
            }
        }
    }

    // MARK: - Photo
    private func photoLayer(image: UIImage) -> some View {
        ZoomableImageView(
            image: image,
            zoomScale: $zoomScale,
            minScale: 1.0,
            maxScale: 4.0,
            resetToken: zoomResetToken
        )
        .padding(12)
    }

    // MARK: - Controls
    private var controlsTopRight: some View {
        VStack {
            HStack(spacing: 10) {
                Spacer()

                ControlButton(
                    icon: "note.text",
                    color: hasNote ? .orange : .primary,
                    action: onOpenNote
                )

                ControlButton(
                    icon: "square.and.arrow.up",
                    action: onShare
                )
            }
            .padding(12)
            Spacer()
        }
    }

    private var liveBadgeBottomLeft: some View {
        VStack {
            Spacer()
            HStack {
                if asset.mediaSubtypes.contains(.photoLive) {
                    Button(action: onToggleLive) {
                        Image(systemName: isPlayingLivePhoto ? "stop.circle.fill" : "livephoto")
                            .padding(10)
                            .background(.ultraThinMaterial)
                            .clipShape(Circle())
                    }
                }
                Spacer()
            }
            .padding(12)
        }
    }

    private var videoMuteBottomRight: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                if asset.mediaType == .video {
                    ControlButton(icon: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill") {
                        isMuted.toggle()
                        player?.isMuted = isMuted

                        // If the user toggles mute while playing, update audio focus accordingly.
                        if let player, player.timeControlStatus == .playing {
                            if isMuted {
                                AudioSessionManager.endVideoAudio()
                            } else {
                                AudioSessionManager.beginVideoAudio()
                            }
                        }
                    }
                }
            }
            .padding(12)
        }
    }

}
