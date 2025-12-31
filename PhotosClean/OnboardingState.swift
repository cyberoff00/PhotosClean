//
//  OnboardingState.swift
//  PhotosClean
//
//  Created by Claire Yang on 09/01/2026.
//

import SwiftUI
import Combine

@MainActor
final class OnboardingState: ObservableObject {

    enum TodayStep: Int {
        case none = 0
        case nudge = 1          // 进入 today 的提醒
        case swipeKeep = 2
        case swipeDelete = 3
        case swipeMaybe = 4
        case addNote = 5
        case done = 6
    }

    // Today 引导步骤（持久化）
    @AppStorage("onb_today_step") private var todayStepRaw: Int = TodayStep.nudge.rawValue
    @Published var todayStep: TodayStep = .nudge

    // Library 引导（持久化）
    @AppStorage("onb_library_seen") private var librarySeenRaw: Bool = false
    @Published var librarySeen: Bool = false

    // Today 空状态引导（持久化）
    @AppStorage("onb_today_empty_seen") private var todayEmptySeenRaw: Bool = false
    @Published var todayEmptySeen: Bool = false

    init() {
        todayStep = TodayStep(rawValue: todayStepRaw) ?? .nudge
        librarySeen = librarySeenRaw
        todayEmptySeen = todayEmptySeenRaw
    }

    func markTodayEmptySeen() {
        todayEmptySeen = true
        todayEmptySeenRaw = true
    }

    func advanceTodayIf(_ current: TodayStep) {
        guard todayStep == current else { return }
        let next = TodayStep(rawValue: current.rawValue + 1) ?? .done
        todayStep = next
        todayStepRaw = next.rawValue
    }

    func completeToday() {
        todayStep = .done
        todayStepRaw = TodayStep.done.rawValue
    }

    func markLibrarySeen() {
        librarySeen = true
        librarySeenRaw = true
    }
}
