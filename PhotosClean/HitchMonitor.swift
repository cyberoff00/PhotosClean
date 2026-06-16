import SwiftUI
import QuartzCore

/// Lightweight main-thread frame-time monitor. While attached to a visible view
/// it drives a CADisplayLink and logs any frame that took noticeably longer than
/// the display's refresh budget — i.e. a hitch the user feels as "卡".
///
/// Attach with `.trackFrameHitches("retro")` / `.trackFrameHitches("grid")`,
/// run the app from Xcode, reproduce the jank, then read the console. Output is
/// prefixed with `⏱️[tag]` so you can filter. Remove the modifiers once the
/// bottleneck is found — the monitor itself is cheap but not free.
final class FrameHitchMonitor {
    private var displayLink: CADisplayLink?
    private var lastTimestamp: CFTimeInterval = 0
    private let tag: String
    // 20ms ≈ a dropped frame at 60Hz (16.7ms budget). On 120Hz ProMotion the
    // budget is 8.3ms, but 20ms is a good "the user can feel this" threshold.
    private let slowFrameMS: Double = 20

    private var worstMS: Double = 0
    private var droppedCount = 0
    private var totalFrames = 0

    init(tag: String) { self.tag = tag }

    func start() {
        stop()
        lastTimestamp = 0
        worstMS = 0
        droppedCount = 0
        totalFrames = 0
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
        guard totalFrames > 0 else { return }
        let pct = Double(droppedCount) / Double(totalFrames) * 100
        print(String(format: "⏱️[%@] summary: %d frames, %d dropped (%.1f%%), worst %.1fms",
                     tag, totalFrames, droppedCount, pct, worstMS))
    }

    @objc private func tick(_ link: CADisplayLink) {
        if lastTimestamp == 0 { lastTimestamp = link.timestamp; return }
        let deltaMS = (link.timestamp - lastTimestamp) * 1000.0
        lastTimestamp = link.timestamp
        totalFrames += 1
        if deltaMS > worstMS { worstMS = deltaMS }
        if deltaMS > slowFrameMS {
            droppedCount += 1
            print(String(format: "⏱️[%@] slow frame %.1fms", tag, deltaMS))
        }
    }
}

private struct FrameHitchModifier: ViewModifier {
    @State private var monitor: FrameHitchMonitor

    init(tag: String) {
        _monitor = State(initialValue: FrameHitchMonitor(tag: tag))
    }

    func body(content: Content) -> some View {
        content
            .onAppear { monitor.start() }
            .onDisappear { monitor.stop() }
    }
}

extension View {
    /// Log main-thread frame hitches while this view is on screen. See `FrameHitchMonitor`.
    func trackFrameHitches(_ tag: String) -> some View {
        modifier(FrameHitchModifier(tag: tag))
    }
}

/// Time a synchronous block running on the main thread and log it if it's slow.
/// Temporary instrumentation — pair with `trackFrameHitches` to attribute which
/// work caused a hitch. Logs anything over ~8ms (half a 60Hz frame).
@discardableResult
func measureMain<T>(_ label: String, _ block: () -> T) -> T {
    let start = CACurrentMediaTime()
    let result = block()
    let ms = (CACurrentMediaTime() - start) * 1000.0
    if ms > 8 {
        print(String(format: "⏱️📌[%@] %.1fms", label, ms))
    }
    return result
}
