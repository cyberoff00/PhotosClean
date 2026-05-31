import SwiftUI
import Photos

// MARK: - Filmstrip (Apple Photos-like thumbnail preview)
struct FilmstripView: View {
    let assets: [PHAsset]
    let selectedID: String?
    var onSelect: (PHAsset) -> Void

    // Tuning
    // Smaller, lighter thumbnails so the strip feels attached to the card
    // and doesn't compete with the primary content.
    var thumbSide: CGFloat = 32
    var spacing: CGFloat = 6
    // Show a compact window of thumbnails (default 5) so the strip doesn't
    // dominate the layout. Users can still scroll horizontally.
    var visibleCount: Int = 5

    @State private var centerWork: DispatchWorkItem?

    var body: some View {
        ScrollViewReader { proxy in
            // Constrain the visible width so ~5 thumbnails are shown.
            let stripWidth = thumbSide * CGFloat(visibleCount) + spacing * CGFloat(max(visibleCount - 1, 0))
            // Side padding allows the first/last item to also reach the center.
            let sidePadding = max(0, (stripWidth - thumbSide) / 2)

            ZStack {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: spacing) {
                        ForEach(assets, id: \.localIdentifier) { asset in
                            Button {
                                onSelect(asset)
                            } label: {
                                FilmstripThumb(asset: asset, side: thumbSide)
                            }
                            .buttonStyle(.plain)
                            .id(asset.localIdentifier)
                        }
                    }
                    // Keep the strip visually light and avoid "container" styling.
                    // Outer layout should own padding/position so the whole page doesn't reflow.
                    .padding(.vertical, 4)
                    .padding(.horizontal, sidePadding)
                }
                .overlay {
                    // Keep a fixed center focus frame so selection feels stable:
                    // only the strip scrolls, the frame itself doesn't "jump".
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.primary.opacity(0.85), lineWidth: 2)
                        .frame(width: thumbSide, height: thumbSide)
                        .allowsHitTesting(false)
                }
                .frame(width: stripWidth)
                .frame(maxWidth: .infinity, alignment: .center)
                .scrollBounceBehavior(.basedOnSize)
                .onAppear {
                    scheduleCenter(in: proxy)
                }
                // Re-center on selection change or when the strip's contents change.
                // Using assets.count (O(1)) instead of mapping every id each render,
                // and coalescing both triggers into a single scrollTo per runloop.
                .onChange(of: selectedID) { _, _ in
                    scheduleCenter(in: proxy)
                }
                .onChange(of: assets.count) { _, _ in
                    scheduleCenter(in: proxy)
                }
            }
        }
    }

    private func scheduleCenter(in proxy: ScrollViewProxy) {
        centerWork?.cancel()
        guard let id = selectedID else { return }
        let work = DispatchWorkItem {
            proxy.scrollTo(id, anchor: .center)
        }
        centerWork = work
        DispatchQueue.main.async(execute: work)
    }
}

private struct FilmstripThumb: View {
    let asset: PHAsset
    let side: CGFloat

    @State private var image: UIImage?
    @State private var requestID: PHImageRequestID = PHInvalidImageRequestID

    var body: some View {
        ZStack {
            Rectangle()
                .fill(Color.gray.opacity(0.18))

            if let img = image {
                Image(uiImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: side, height: side)
                    .clipped()
            } else {
                Image(systemName: "photo")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.secondary.opacity(0.6))
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .onAppear { request() }
        .onChange(of: asset.localIdentifier) { _, _ in request() }
        .onDisappear { PHAssetThumbnailLoader.shared.cancel(requestID) }
    }

    private func request() {
        PHAssetThumbnailLoader.shared.cancel(requestID)
        requestID = PHInvalidImageRequestID

        let scale = UIScreen.main.scale
        let target = CGSize(width: side * scale * 1.2, height: side * scale * 1.2)

        if let cached = PHAssetThumbnailLoader.shared.cachedImage(for: asset.localIdentifier, targetSize: target) {
            image = cached
            return
        }

        requestID = PHAssetThumbnailLoader.shared.requestThumbnail(asset: asset, targetSize: target) { img, _ in
            guard asset.localIdentifier == self.asset.localIdentifier else { return }
            self.image = img
        }
    }
}
