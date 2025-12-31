import UIKit
import Photos

@MainActor
final class PHAssetThumbnailLoader {
    static let shared = PHAssetThumbnailLoader()

    // 用 asset.localIdentifier 作为 key
    private let cache = NSCache<NSString, UIImage>()

    private init() {
        cache.countLimit = 500
        cache.totalCostLimit = 40 * 1024 * 1024
    }

    private func cacheKey(assetID: String, targetSize: CGSize) -> NSString {
        let w = Int(targetSize.width.rounded())
        let h = Int(targetSize.height.rounded())
        return "\(assetID)#\(w)x\(h)" as NSString
    }

    func cachedImage(for assetID: String, targetSize: CGSize) -> UIImage? {
        cache.object(forKey: cacheKey(assetID: assetID, targetSize: targetSize))
    }

    func setCache(_ image: UIImage, for assetID: String, targetSize: CGSize) {
        let key = cacheKey(assetID: assetID, targetSize: targetSize)
        let cost: Int
        if let cg = image.cgImage {
            cost = max(cg.bytesPerRow * cg.height, 1)
        } else {
            cost = max(Int(image.size.width * image.size.height * 4), 1)
        }
        cache.setObject(image, forKey: key, cost: cost)
    }

    /// 请求缩略图：先可能返回 degraded，再返回高清（如果系统能拿到）
    /// 返回值：PHImageRequestID（用于取消）
    func requestThumbnail(
        asset: PHAsset,
        targetSize: CGSize,
        completion: @escaping (_ image: UIImage?, _ isDegraded: Bool) -> Void
    ) -> PHImageRequestID {

        // 先走缓存
        let assetID = asset.localIdentifier
        if let cached = cachedImage(for: assetID, targetSize: targetSize) {
            completion(cached, false)
            // 缓存命中就不一定要继续请求更高清；你想更高清也可继续请求
            // 这里选择直接返回一个“无效 id”
            return PHInvalidImageRequestID
        }

        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true
        // opportunistic：非常适合缩略图：先给快的（可能 degraded），再给好的
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        options.isSynchronous = false

        return PHImageManager.default().requestImage(
            for: asset,
            targetSize: targetSize,
            contentMode: .aspectFill,
            options: options
        ) { [weak self] image, info in
            guard let image else {
                completion(nil, false)
                return
            }

            let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false

            // ✅ 关键：degraded 也先给 UI 显示，避免模拟器永远空白
            completion(image, degraded)

            // 只缓存“非 degraded”更稳（避免缓存糊图）
            if degraded == false {
                self?.setCache(image, for: assetID, targetSize: targetSize)
            }
        }
    }

    func cancel(_ requestID: PHImageRequestID) {
        guard requestID != PHInvalidImageRequestID else { return }
        PHImageManager.default().cancelImageRequest(requestID)
    }
}
