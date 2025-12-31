//
//  Paywallgate.swift
//  PhotosClean
//
//  Created by Claire Yang on 09/01/2026.
//

import SwiftUI
import Combine

@MainActor
final class PaywallGate: ObservableObject {
    @Published var showPaywall: Bool = false

    // 你想要的免费次数
    let freeSwipesLimit: Int = 10

    // 用 AppStorage 做持久化（跨页面共享）
    @AppStorage("free_swipes_used") private var used: Int = 0

    func reset() {
        used = 0
    }

    /// 每次成功“完成一次滑动判定（keep/delete/maybe）”后调用
    func recordSwipeAndCheckIfNeedPaywall(isPremium: Bool) {
        guard !isPremium else {
            showPaywall = false
            return
        }

        used += 1
        if used >= freeSwipesLimit {
            showPaywall = true
        }
    }

    /// 有些地方你想“进入页面就检查”
    func checkIfNeedPaywall(isPremium: Bool) {
        guard !isPremium else {
            showPaywall = false
            return
        }
        if used >= freeSwipesLimit {
            showPaywall = true
        }
    }
}
