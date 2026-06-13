//
//  StorageStats.swift
//  PhotosClean
//
//  Tracks per-asset file sizes (estimated + precise) and the user's
//  daily cleanup progress against an optional goal.
//

import Foundation
import SwiftUI
import UIKit
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
    /// Last time each precise entry was written / re-requested, used for LRU
    /// trimming of the disk cache. Entries loaded from the legacy on-disk format
    /// have no timestamp and are treated as oldest.
    private var preciseLastTouch: [String: Date] = [:]
    private var inflightIDs: Set<String> = []
    private var lastKnownPendingBytes: Int64 = 0
    private var widgetReloadTask: Task<Void, Never>?
    private var pendingProgressDebounceTask: Task<Void, Never>?
    private var pendingProgressLatestBytes: Int64 = 0
    private var saveCacheDebounceTask: Task<Void, Never>?

    private static let appGroupID = "group.com.claire.TastyTidy"

    private let workQueue = DispatchQueue(label: "com.photosclean.storagestats", qos: .utility)
    private let cacheURL: URL = {
        let fm = FileManager.default
        let dir = (try? fm.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? fm.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return dir.appendingPathComponent("storage_stats_cache.json")
    }()

    /// Token for the foreground notification observer that drives day rollover.
    private var foregroundObserver: NSObjectProtocol?

    init() {
        loadCacheFromDisk()
        if let migrated = Self.legacyGoalMigration[Int64(dailyGoalRaw)] {
            dailyGoalRaw = Double(migrated)
        }
        // Day rollover happens at explicit times (init + returning to
        // foreground), never inside getters — getters stay pure reads.
        checkDayRollover()
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.checkDayRollover()
            }
        }
    }

    deinit {
        if let foregroundObserver {
            NotificationCenter.default.removeObserver(foregroundObserver)
        }
    }

    // MARK: - Daily progress

    /// Pure read: if the persisted value belongs to a previous day, report 0.
    /// The actual reset is performed by `checkDayRollover()` / `recordCleanup`.
    var dailyBytesCleaned: Int64 {
        guard dailyBytesDate == Self.todayString() else { return 0 }
        return Int64(dailyBytesCleanedRaw)
    }

    /// Resets the daily counter when the date has rolled over and notifies the
    /// UI. Called from init and on every return to foreground.
    func checkDayRollover() {
        if resetIfNewDay() {
            objectWillChange.send()
        }
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

        // Touch already-cached entries so recently used assets survive LRU trims.
        let now = Date()
        for a in assets where preciseSizes[a.localIdentifier] != nil {
            preciseLastTouch[a.localIdentifier] = now
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
                // Mutating @Published preciseSizes already emits objectWillChange,
                // so no explicit send() is needed (it would double the re-render).
                let stamp = Date()
                for (id, size) in batch {
                    self.preciseSizes[id] = size
                    self.preciseLastTouch[id] = stamp
                }
                missing.forEach { self.inflightIDs.remove($0.localIdentifier) }
                // Debounced + off-main: encoding up to 5000 entries and writing
                // atomically used to run on the main thread on every batch, which
                // froze the *whole* app periodically while marking deletes.
                self.scheduleSaveCacheToDisk()
            }
        }
    }

    // MARK: - Private

    nonisolated private static func preciseSizeSync(for asset: PHAsset) -> Int64 {
        let resources = PHAssetResource.assetResources(for: asset)
        var total: Int64 = 0
        for r in resources {
            // "fileSize" is a private (undocumented) KVC key. value(forKey:) on a
            // key the class doesn't expose raises NSUnknownKeyException and would
            // crash, so gate it behind responds(to:). If a future iOS drops the
            // accessor we return 0 and callers fall back to the pixel estimate
            // (precacheSizes only stores results > 0).
            guard r.responds(to: NSSelectorFromString("fileSize")) else { continue }
            if let n = r.value(forKey: "fileSize") as? NSNumber {
                total += n.int64Value
            }
        }
        return total
    }

    /// Performs the day rollover if needed. Returns true when a reset happened.
    /// Only called from explicit mutation points (init/foreground/recordCleanup),
    /// never from getters.
    @discardableResult
    private func resetIfNewDay() -> Bool {
        let today = Self.todayString()
        guard dailyBytesDate != today else { return false }
        dailyBytesCleanedRaw = 0
        dailyBytesDate = today
        return true
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

    /// On-disk entry: size + last-touch timestamp (for LRU trimming).
    /// `t` is optional so entries written by older builds (plain [String: Int64])
    /// can be represented after migration as "no timestamp = oldest".
    private struct PersistedSizeEntry: Codable {
        var s: Int64
        var t: Date?
    }

    private func loadCacheFromDisk() {
        guard let data = try? Data(contentsOf: cacheURL) else { return }
        if let decoded = try? JSONDecoder().decode([String: PersistedSizeEntry].self, from: data) {
            preciseSizes = decoded.mapValues { $0.s }
            preciseLastTouch = decoded.compactMapValues { $0.t }
        } else if let legacy = try? JSONDecoder().decode([String: Int64].self, from: data) {
            // Legacy format (pre-LRU): sizes only, treated as untouched/oldest.
            preciseSizes = legacy
        }
    }

    /// Coalesces rapid precache completions into at most one disk write per
    /// ~600ms, and performs the (expensive) JSON encode + atomic write off the
    /// main thread so it never stalls UI / button taps.
    private func scheduleSaveCacheToDisk() {
        saveCacheDebounceTask?.cancel()
        saveCacheDebounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard let self, !Task.isCancelled else { return }
            self.saveCacheToDisk()
        }
    }

    private func saveCacheToDisk() {
        // Trim mutates @Published preciseSizes, so it must stay on the main actor.
        // LRU: keep the 5000 most recently touched entries; legacy entries with
        // no timestamp count as oldest and get evicted first. (The previous
        // Dictionary.prefix trim kept an arbitrary, hash-order subset.)
        if preciseSizes.count > 5000 {
            let keep = Set(
                preciseSizes.keys
                    .sorted { (preciseLastTouch[$0] ?? .distantPast) > (preciseLastTouch[$1] ?? .distantPast) }
                    .prefix(5000)
            )
            preciseSizes = preciseSizes.filter { keep.contains($0.key) }
            preciseLastTouch = preciseLastTouch.filter { keep.contains($0.key) }
        }
        // Snapshot, then encode + write on the background work queue.
        let snap = preciseSizes
        let touchSnap = preciseLastTouch
        let url = cacheURL
        workQueue.async {
            var out: [String: PersistedSizeEntry] = [:]
            out.reserveCapacity(snap.count)
            for (id, size) in snap {
                out[id] = PersistedSizeEntry(s: size, t: touchSnap[id])
            }
            guard let data = try? JSONEncoder().encode(out) else { return }
            try? data.write(to: url, options: .atomic)
        }
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
