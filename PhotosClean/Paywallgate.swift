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

    /// Daily free quota for non-premium users
    let dailyFreeLimit: Int = 36

    // Persistent storage
    @AppStorage("daily_swipes_used") private var used: Int = 0
    @AppStorage("daily_swipes_date") private var storedDateString: String = ""

    /// How many swipes used today (read-only for UI)
    var usedToday: Int {
        resetIfNewDay()
        return used
    }

    /// Remaining free swipes today
    var remaining: Int {
        max(0, dailyFreeLimit - usedToday)
    }

    /// Whether the daily quota is exhausted
    var isQuotaExhausted: Bool {
        usedToday >= dailyFreeLimit
    }

    func reset() {
        objectWillChange.send()
        used = 0
        storedDateString = todayString()
    }

    /// Record a swipe. Returns true if the swipe is allowed, false if quota exhausted.
    @discardableResult
    func recordSwipe(isPremium: Bool) -> Bool {
        guard !isPremium else { return true }

        resetIfNewDay()

        if used >= dailyFreeLimit {
            return false
        }

        // @AppStorage in an ObservableObject doesn't publish, and the send must
        // precede the mutation for SwiftUI to pick it up.
        objectWillChange.send()
        used += 1
        return true
    }

    /// Check quota without recording (e.g. on page appear)
    func checkQuota(isPremium: Bool) -> Bool {
        guard !isPremium else { return true }
        resetIfNewDay()
        return used < dailyFreeLimit
    }

    // MARK: - Private

    private func resetIfNewDay() {
        let today = todayString()
        if storedDateString != today {
            // Publish before mutating so views observing the gate refresh.
            objectWillChange.send()
            used = 0
            storedDateString = today
        }
    }

    /// Fixed POSIX locale + Gregorian calendar so the stored day key is stable
    /// regardless of the user's calendar (e.g. Buddhist) or locale settings.
    private static let dayFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.calendar = Calendar(identifier: .gregorian)
        fmt.timeZone = .current
        fmt.dateFormat = "yyyy-MM-dd"
        return fmt
    }()

    private func todayString() -> String {
        Self.dayFormatter.string(from: Date())
    }
}
