import Foundation
import SwiftData

@Model
class PhotoTag {
    // ❌ 移除 @Attribute(.unique)，因为 CloudKit 不支持
    var assetID: String = ""
    
    // ✅ 确保所有非可选属性都有初始值
    var status: String = "unknown"
    var note: String?
    var createdAt: Date = Date()
    
    init(assetID: String, status: String, note: String? = nil) {
        self.assetID = assetID
        self.status = status
        self.note = note
        self.createdAt = Date()
    }
}
