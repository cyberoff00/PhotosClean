//
//  RatingPrompt.swift
//  PhotosClean
//
//  "Rating gate": after the user has matured (a few days in + a couple of
//  successful cleanups), ask "Enjoying TastyTidy?" at a high point. Happy users
//  get routed to the native App Store review prompt; unhappy users get routed to
//  the in-app feedback page — so we never waste Apple's rate-limited review sheet
//  on someone about to leave a 1-star.
//

import SwiftUI
import Combine
import StoreKit

@MainActor
final class RatingPrompt: ObservableObject {

    // MARK: - Tunable thresholds

    /// Days the app must have been installed before we ever ask.
    private static let minDaysInstalled = 3
    /// Successful cleanups required before we ever ask.
    private static let minCleanups = 2
    /// Days to wait after a prompt before we may ask again.
    private static let cooldownDays = 60
    /// Hard cap on how many times we ever ask a user who keeps deferring.
    private static let maxPrompts = 3

    // MARK: - Persistent state

    /// "yyyy-MM-dd" of first launch. Seeded once on init.
    @AppStorage("rating_first_launch_date") private var firstLaunchDate: String = ""
    /// Lifetime count of successful cleanups (a positive-sentiment signal).
    @AppStorage("rating_cleanup_count") private var cleanupCount: Int = 0
    /// "yyyy-MM-dd" the ask dialog was last shown.
    @AppStorage("rating_last_prompt_date") private var lastPromptDate: String = ""
    /// How many times the ask dialog has been shown.
    @AppStorage("rating_prompt_count") private var promptCount: Int = 0
    /// Once true, the user said they like it (or rated) — never ask again.
    @AppStorage("rating_did_rate") private var didRate: Bool = false

    // MARK: - Published UI triggers

    /// Drives the "Enjoying TastyTidy?" alert.
    @Published var showAsk = false
    /// Drives the in-app feedback sheet (set when the user says "not really").
    @Published var showFeedback = false

    init() {
        if firstLaunchDate.isEmpty {
            firstLaunchDate = Self.todayString()
        }
    }

    // MARK: - Signals

    /// Call when the user successfully completes a cleanup. Bumps the positive
    /// signal and, if all gate conditions are met, queues the ask dialog.
    func registerCleanup() {
        cleanupCount += 1
        if isEligible {
            // Let the deletion UI settle before the dialog appears.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                guard let self, self.isEligible else { return }
                self.showAsk = true
            }
        }
    }

    // MARK: - Dialog outcomes

    /// User said they like it → route to the native App Store review prompt and
    /// never ask again.
    func userLikes(_ requestReview: RequestReviewAction) {
        markPromptShown()
        didRate = true
        requestReview()
    }

    /// User said "not really" → open the in-app feedback page. We mark the prompt
    /// as shown (cooldown applies) but do NOT set didRate, so a happy change of
    /// heart later can still surface the rating ask.
    func userDislikes() {
        markPromptShown()
        showFeedback = true
    }

    /// User dismissed without choosing — count it so we respect the cooldown and
    /// the max-prompts cap rather than re-asking on the next cleanup.
    func userDismissed() {
        markPromptShown()
    }

    // MARK: - Eligibility

    private var isEligible: Bool {
        guard !didRate else { return false }
        guard promptCount < Self.maxPrompts else { return false }
        guard cleanupCount >= Self.minCleanups else { return false }
        guard daysSince(firstLaunchDate) >= Self.minDaysInstalled else { return false }
        if !lastPromptDate.isEmpty, daysSince(lastPromptDate) < Self.cooldownDays {
            return false
        }
        return true
    }

    private func markPromptShown() {
        showAsk = false
        lastPromptDate = Self.todayString()
        promptCount += 1
    }

    // MARK: - Date helpers

    private static let dayFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd"
        return fmt
    }()

    private static func todayString() -> String {
        dayFormatter.string(from: Date())
    }

    /// Whole days between the given "yyyy-MM-dd" and today. Returns a large
    /// number if the string can't be parsed, so a corrupt value never blocks
    /// (for cooldown) or forces (for install age) the prompt incorrectly.
    private func daysSince(_ dateString: String) -> Int {
        guard let date = Self.dayFormatter.date(from: dateString) else { return Int.max }
        let days = Calendar.current.dateComponents([.day], from: date, to: Date()).day ?? 0
        return max(0, days)
    }
}
