//
//  LocalizedString+Extension.swift
//  PhotosClean
//
//  Created by Claire Yang on 09/01/2026.
//

import SwiftUI

extension String {
    // 简化调用方式
    var localized: String {
        NSLocalizedString(self, comment: "")
    }
    
    // 支持参数替换
    func localized(with arguments: CVarArg...) -> String {
        let format = NSLocalizedString(self, comment: "")
        return String(format: format, arguments: arguments)
    }
}
