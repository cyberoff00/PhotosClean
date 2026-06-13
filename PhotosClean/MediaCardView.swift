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
    let isLoadingLivePhoto: Bool

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
    var onEdgeSwipe: ((CGFloat) -> Void)?

    @State private var isVideoLoaded = false
    @State private var isVideoReady = false

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

            // Video badge stays visible during the swipe (heavy phase) too, so a
            // video is identifiable at a glance — its static preview is otherwise
            // indistinguishable from a photo until the system controls load.
            if asset.mediaType == .video {
                videoBadgeTopLeft
            }

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
            isVideoReady = false
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
            // Mount as soon as the Live Photo is loaded so PHLivePhotoView has time
            // to prepare; keep it invisible until playing. Tapping then plays
            // instantly instead of stalling on a freshly-created view.
            if let live = livePhoto {
                // Constrain + clip the Live Photo view to the card. The earlier
                // `.clipped()` only clips the still image *above* this overlay in
                // the chain, NOT the overlay itself — so without an explicit
                // frame/clip here, iOS 18's `.full` PHLivePhotoView playback
                // renders past the card bounds and balloons to full screen. That
                // overflow also pushed the play area outside the card's gesture
                // frame, which is why swiping stopped working while it played.
                LivePhotoView(livePhoto: live, isPlaying: $isPlayingLivePhoto)
                    .padding(12)
                    .frame(width: cardWidth, height: cardHeight)
                    .clipped()
                    .opacity(isPlayingLivePhoto ? 1 : 0)
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
        ZStack {
            if let p = player {
                StableVideoPlayerView(player: p, isMuted: isMuted) {
                    // First frame is decodable — uncover with a quick fade so the
                    // poster blends into the video instead of a gray→black jump.
                    withAnimation(.easeOut(duration: 0.2)) { isVideoReady = true }
                }

                // Hold the poster still over the freshly-mounted player until its
                // first frame is ready; otherwise AVPlayerViewController shows a
                // black frame for a beat — the "flash" users hit on slow loads.
                if !isVideoReady {
                    videoPoster
                        .transition(.opacity)
                }
            } else {
                // Loading: cover with the poster (not gray) plus a spinner /
                // iCloud progress, so swiping in never reveals a gray block.
                videoPoster
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
        }
        .padding(12)
        .onAppear {
            if player == nil, !isVideoLoaded {
                isVideoLoaded = true
                onLoadVideo()
            }
        }
    }

    @ViewBuilder
    private var videoPoster: some View {
        if let img = displayImage {
            Image(uiImage: img)
                .resizable()
                .interpolation(.medium)
                .aspectRatio(contentMode: .fit)
        } else {
            Color(.systemGray5)
        }
    }

    // MARK: - Photo
    private func photoLayer(image: UIImage) -> some View {
        ZoomableImageView(
            image: image,
            zoomScale: $zoomScale,
            minScale: 1.0,
            maxScale: 4.0,
            resetToken: zoomResetToken,
            onEdgeSwipe: onEdgeSwipe
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

    private var videoBadgeTopLeft: some View {
        VStack {
            HStack {
                HStack(spacing: 5) {
                    Image(systemName: "video.fill")
                        .font(.system(size: 11, weight: .bold))
                    Text(formattedDuration(asset.duration))
                        .font(.system(size: 12, weight: .semibold))
                        .monospacedDigit()
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.ultraThinMaterial)
                .environment(\.colorScheme, .dark)
                .clipShape(Capsule())
                Spacer()
            }
            Spacer()
        }
        .padding(12)
        .allowsHitTesting(false)
    }

    private func formattedDuration(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }

    private var liveBadgeBottomLeft: some View {
        VStack {
            Spacer()
            HStack {
                if asset.mediaSubtypes.contains(.photoLive) {
                    Button(action: onToggleLive) {
                        Group {
                            if isLoadingLivePhoto {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Image(systemName: isPlayingLivePhoto ? "stop.circle.fill" : "livephoto")
                            }
                        }
                        .frame(width: 20, height: 20)
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
