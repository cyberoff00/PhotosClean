//
//  StorageStats.swift
//  PhotosClean
//
//  Tracks per-asset file sizes (estimated + precise) and the user's
//  daily cleanup progress against an optional goal.
//

import Foundation
import SwiftUI
import Photos
import Combine
import WidgetKit

@MainActor
final class StorageStats: ObservableObject {

    // MARK: - Goal options

    // Decimal units to match ByteCountFormatter(.file) on iOS:
    // mixing 2^30 with the formatter (which uses 10^9) caused
    // "1.06 GB / 1 GB" displays where pending was actually below goal.
    static let goalOptions: [Int64] = [
        0,                       // off
        50  * 1_000_000,
        200 * 1_000_000,
        500 * 1_000_000,
        1_000_000_000,
        2_000_000_000,
        5_000_000_000
    ]
    static let defaultGoalBytes: Int64 = 200 * 1_000_000

    static func goalLabel(_ bytes: Int64) -> String {
        bytes == 0 ? "" : bytes.byteCountShort
    }

    /// Map any persisted legacy binary-unit goal value to its decimal equivalent.
    private static let legacyGoalMigration: [Int64: Int64] = [
        50  * 1024 * 1024:         50  * 1_000_000,
        200 * 1024 * 1024:         200 * 1_000_000,
        500 * 1024 * 1024:         500 * 1_000_000,
        1024 * 1024 * 1024:        1_000_000_000,
        2 * 1024 * 1024 * 1024:    2_000_000_000,
        5 * 1024 * 1024 * 1024:    5_000_000_000
    ]

    // MARK: - Persistent state

    @AppStorage("daily_bytes_cleaned") private var dailyBytesCleanedRaw: Double = 0
    @AppStorage("daily_bytes_date")    private var dailyBytesDate: String = ""
    @AppStorage("daily_goal_bytes")    private var dailyGoalRaw: Double = Double(StorageStats.defaultGoalBytes)
    @AppStorage("goal_card_dismissed_date") private var goalCardDismissedDate: String = ""
    @AppStorage("total_bytes_cleaned") private var totalBytesCleanedRaw: Double = 0
    /// "yyyy-MM-dd" the day the user's pending-to-release total first hit the goal.
    @AppStorage("daily_goal_hit_date") private var dailyGoalHitDate: String = ""
    /// Peak pending-to-release bytes recorded today (sticky across deletions).
    @AppStorage("daily_pending_peak")  private var dailyPendingPeakRaw: Double = 0
    @AppStorage("daily_pending_peak_date") private var dailyPendingPeakDate: String = ""

    // MARK: - In-memory cache

    @Published private(set) var preciseSizes: [String: Int64] = [:]
    @Published private(set) var estimatedSizes: [String: Int64] = [:]
    private var inflightIDs: Set<String> = []
    private var lastKnownPendingBytes: Int64 = 0
    private var widgetReloadTask: Task<Void, Never>?
    private var pendingProgressDebounceTask: Task<Void, Never>?
    private var pendingProgressLatestBytes: Int64 = 0

    private static let appGroupID = "group.com.claire.TastyTidy"

    private let workQueue = DispatchQueue(label: "com.photosclean.storagestats", qos: .utility)
    private let cacheURL: URL = {
        let fm = FileManager.default
        let dir = (try? fm.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? fm.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return dir.appendingPathComponent("storage_stats_cache.json")
    }()

    init() {
        loadCacheFromDisk()
        if let migrated = Self.legacyGoalMigration[Int64(dailyGoalRaw)] {
            dailyGoalRaw = Double(migrated)
        }
    }

    // MARK: - Daily progress

    var dailyBytesCleaned: Int64 {
        resetIfNewDay()
        return Int64(dailyBytesCleanedRaw)
    }

    var totalBytesCleaned: Int64 {
        Int64(totalBytesCleanedRaw)
    }

    var dailyGoalBytes: Int64 {
        Int64(dailyGoalRaw)
    }

    func setDailyGoal(_ bytes: Int64) {
        dailyGoalRaw = Double(bytes)
        refreshGoalHitState()
        writeWidgetSnapshot()
        objectWillChange.send()
    }

    var goalEnabled: Bool { dailyGoalBytes > 0 }

    /// True once today's pending-to-release total has hit the goal at least once.
    var goalAchievedToday: Bool {
        guard goalEnabled else { return false }
        return dailyGoalHitDate == Self.todayString()
    }

    /// Peak pending bytes recorded today. Sticky across deletions
    /// so the celebration number doesn't drop after the user actually deletes.
    var dailyPendingPeak: Int64 {
        if dailyPendingPeakDate != Self.todayString() { return 0 }
        return Int64(dailyPendingPeakRaw)
    }

    var shouldShowCelebrationCard: Bool {
        guard goalAchievedToday else { return false }
        return goalCardDismissedDate != Self.todayString()
    }

    func dismissCelebrationToday() {
        goalCardDismissedDate = Self.todayString()
        objectWillChange.send()
    }

    /// Update sticky daily peak from the current pending-to-release total
    /// and re-derive goal-hit state from that peak.
    /// Debounced so rapid swipes don't trigger a UserDefaults+widget churn loop.
    func notePendingProgress(_ pendingBytes: Int64) {
        pendingProgressLatestBytes = pendingBytes
        pendingProgressDebounceTask?.cancel()
        pendingProgressDebounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard let self, !Task.isCancelled else { return }
            self.applyPendingProgress(self.pendingProgressLatestBytes)
        }
    }

    private func applyPendingProgress(_ pendingBytes: Int64) {
        lastKnownPendingBytes = pendingBytes
        let today = Self.todayString()
        var changed = false

        if dailyPendingPeakDate != today {
            dailyPendingPeakRaw = Double(pendingBytes)
            dailyPendingPeakDate = today
            changed = true
        } else if Double(pendingBytes) > dailyPendingPeakRaw {
            dailyPendingPeakRaw = Double(pendingBytes)
            changed = true
        }

        if refreshGoalHitState() { changed = true }

        writeWidgetSnapshot()

        if changed { objectWillChange.send() }
    }

    // MARK: - Widget bridge

    private func writeWidgetSnapshot() {
        guard let d = UserDefaults(suiteName: Self.appGroupID) else { return }
        let remaining = max(0, dailyGoalBytes - lastKnownPendingBytes)
        d.set(goalEnabled, forKey: "goal_enabled")
        d.set(Self.goalLabel(dailyGoalBytes), forKey: "goal_label")
        d.set(lastKnownPendingBytes.byteCountShort, forKey: "pending_label")
        d.set(remaining.byteCountShort, forKey: "remaining_label")
        d.set(NSNumber(value: lastKnownPendingBytes), forKey: "pending_bytes")
        d.set(NSNumber(value: dailyGoalBytes), forKey: "goal_bytes")
        d.set(goalAchievedToday, forKey: "goal_hit")
        scheduleWidgetReload()
    }

    private func scheduleWidgetReload() {
        widgetReloadTask?.cancel()
        widgetReloadTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    /// Reconcile `dailyGoalHitDate` with today's peak vs current goal.
    /// Returns true if state changed.
    @discardableResult
    private func refreshGoalHitState() -> Bool {
        let today = Self.todayString()
        let peakToday = (dailyPendingPeakDate == today) ? Int64(dailyPendingPeakRaw) : 0
        let shouldBeHit = goalEnabled && peakToday >= dailyGoalBytes
        let isMarkedHit = (dailyGoalHitDate == today)
        if shouldBeHit && !isMarkedHit {
            dailyGoalHitDate = today
            return true
        }
        if !shouldBeHit && isMarkedHit {
            dailyGoalHitDate = ""
            return true
        }
        return false
    }

    /// Record bytes that were actually deleted. Used only for the lifetime
    /// "all-time freed" stat; goal achievement is now driven by pending bytes.
    func recordCleanup(bytes: Int64) {
        guard bytes > 0 else { return }
        resetIfNewDay()
        dailyBytesCleanedRaw += Double(bytes)
        totalBytesCleanedRaw += Double(bytes)
        objectWillChange.send()
    }

    // MARK: - Size lookup

    /// Pixel-based estimate. Cheap, always available.
    func estimatedSize(for asset: PHAsset) -> Int64 {
        let pixels = Double(asset.pixelWidth) * Double(asset.pixelHeight)
        switch asset.mediaType {
        case .video:
            // Approximate HEVC at ~6 Mbps. Far from exact, but good enough as a placeholder.
            let secs = max(asset.duration, 0)
            return Int64(secs * 6_000_000.0 / 8.0)
        case .image:
            // HEIC ~0.20 bytes/pixel on modern iPhones; PNGs are larger but rare.
            return Int64(pixels * 0.20)
        default:
            return Int64(pixels * 0.20)
        }
    }

    /// Best-known size: precise if cached, otherwise estimated.
    func bestSize(for asset: PHAsset) -> Int64 {
        if let s = preciseSizes[asset.localIdentifier] { return s }
        return estimatedSize(for: asset)
    }

    /// Best-known size by ID. Returns 0 if neither precise nor estimate is cached.
    func bestSize(forID id: String) -> Int64 {
        preciseSizes[id] ?? estimatedSizes[id] ?? 0
    }

    func hasPrecise(for asset: PHAsset) -> Bool {
        preciseSizes[asset.localIdentifier] != nil
    }

    func hasPrecise(forID id: String) -> Bool {
        preciseSizes[id] != nil
    }

    func totalBestSize(for assets: [PHAsset]) -> Int64 {
        assets.reduce(0) { $0 + bestSize(for: $1) }
    }

    func totalBestSize(forIDs ids: [String]) -> Int64 {
        ids.reduce(0) { $0 + bestSize(forID: $1) }
    }

    func allPrecise(for assets: [PHAsset]) -> Bool {
        assets.allSatisfy { hasPrecise(for: $0) }
    }

    func allPrecise(forIDs ids: [String]) -> Bool {
        ids.allSatisfy { hasPrecise(forID: $0) }
    }

    /// Cache an estimate for this asset (so totals can be computed later by ID alone)
    /// and schedule a precise calculation.
    func noteAsset(_ asset: PHAsset) {
        let id = asset.localIdentifier
        if estimatedSizes[id] == nil {
            estimatedSizes[id] = estimatedSize(for: asset)
        }
        precacheSizes(for: [asset])
    }

    /// Kick off background calculation for missing entries. Idempotent.
    func precacheSizes(for assets: [PHAsset]) {
        // Always note the estimate so totals-by-ID work later.
        for a in assets where estimatedSizes[a.localIdentifier] == nil {
            estimatedSizes[a.localIdentifier] = estimatedSize(for: a)
        }

        let missing = assets.filter {
            preciseSizes[$0.localIdentifier] == nil &&
            !inflightIDs.contains($0.localIdentifier)
        }
        guard !missing.isEmpty else { return }

        missing.forEach { inflightIDs.insert($0.localIdentifier) }

        workQueue.async { [weak self] in
            guard let self else { return }
            var batch: [String: Int64] = [:]
            for asset in missing {
                let size = Self.preciseSizeSync(for: asset)
                if size > 0 {
                    batch[asset.localIdentifier] = size
                }
            }
            DispatchQueue.main.async {
                for (id, size) in batch { self.preciseSizes[id] = size }
                missing.forEach { self.inflightIDs.remove($0.localIdentifier) }
                self.saveCacheToDisk()
                self.objectWillChange.send()
            }
        }
    }

    // MARK: - Private

    nonisolated private static func preciseSizeSync(for asset: PHAsset) -> Int64 {
        let resources = PHAssetResource.assetResources(for: asset)
        var total: Int64 = 0
        for r in resources {
            if let n = r.value(forKey: "fileSize") as? NSNumber {
                total += n.int64Value
            }
        }
        return total
    }

    private func resetIfNewDay() {
        let today = Self.todayString()
        if dailyBytesDate != today {
            dailyBytesCleanedRaw = 0
            dailyBytesDate = today
        }
    }

    /// Static formatter — creating a `DateFormatter` per call is a known perf trap
    /// because ICU initialization is expensive. Reuse a single instance.
    private static let dayFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd"
        return fmt
    }()

    /// Cache today's "yyyy-MM-dd" so hot-path getters
    /// (called per-frame from SwiftUI body) skip formatting entirely.
    private static var cachedTodayString: String = ""
    private static var cachedTodayDay: Int = -1

    private static func todayString() -> String {
        let day = Calendar.current.ordinality(of: .day, in: .era, for: Date()) ?? 0
        if day == cachedTodayDay, !cachedTodayString.isEmpty {
            return cachedTodayString
        }
        let s = dayFormatter.string(from: Date())
        cachedTodayDay = day
        cachedTodayString = s
        return s
    }

    // MARK: - Disk cache

    private func loadCacheFromDisk() {
        guard let data = try? Data(contentsOf: cacheURL),
              let decoded = try? JSONDecoder().decode([String: Int64].self, from: data) else { return }
        preciseSizes = decoded
    }

    private func saveCacheToDisk() {
        var snap = preciseSizes
        if snap.count > 5000 {
            let trimmed = Array(snap.prefix(5000))
            snap = Dictionary(uniqueKeysWithValues: trimmed)
            preciseSizes = snap
        }
        guard let data = try? JSONEncoder().encode(snap) else { return }
        try? data.write(to: cacheURL, options: .atomic)
    }
}

// MARK: - Formatting helpers

extension Int64 {
    /// Compact byte string e.g. "342 MB", "1.2 GB".
    /// Reuses a single `ByteCountFormatter` — instantiating one per call
    /// burns measurable time on the swipe hot path.
    var byteCountShort: String {
        Self.sharedByteCountFormatter.string(fromByteCount: self)
    }

    private static let sharedByteCountFormatter: ByteCountFormatter = {
        let bcf = ByteCountFormatter()
        bcf.allowedUnits = [.useKB, .useMB, .useGB]
        bcf.countStyle = .file
        return bcf
    }()
}
