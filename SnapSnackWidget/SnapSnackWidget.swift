import WidgetKit
import SwiftUI

struct Provider: TimelineProvider {
    let appGroupID = "group.com.claire.TastyTidy"

    func placeholder(in context: Context) -> SimpleEntry {
        SimpleEntry(
            date: Date(),
            count: 0,
            goalEnabled: false,
            goalHit: false,
            pendingLabel: "0 MB",
            remainingLabel: "0 MB",
            goalLabel: "",
            pendingBytes: 0,
            goalBytes: 0
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (SimpleEntry) -> ()) {
        completion(fetchEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SimpleEntry>) -> ()) {
        // The "pending today" count and goal progress are day-scoped, but the
        // app-group values are only rewritten when the app runs. A single
        // .atEnd entry therefore keeps showing yesterday's numbers across
        // midnight. Provide an extra entry at the next midnight that resets
        // the today-scoped fields, and refresh again right after midnight.
        let now = Date()
        let calendar = Calendar.current
        let nextMidnight = calendar.startOfDay(for: calendar.date(byAdding: .day, value: 1, to: now) ?? now)

        let current = fetchEntry(for: now)
        var entries = [current]
        if nextMidnight > now {
            entries.append(midnightResetEntry(from: current, at: nextMidnight))
        }

        completion(Timeline(entries: entries, policy: .after(nextMidnight)))
    }

    /// Entry shown from midnight on: a new day has no sorted/pending photos
    /// yet, so the day-scoped fields reset. Persistent settings (goal on/off,
    /// goal size) carry over; the remaining amount resets to the full goal.
    private func midnightResetEntry(from entry: SimpleEntry, at date: Date) -> SimpleEntry {
        SimpleEntry(
            date: date,
            count: 0,
            goalEnabled: entry.goalEnabled,
            goalHit: false,
            pendingLabel: "0 MB",
            remainingLabel: entry.goalLabel.isEmpty ? "0 MB" : entry.goalLabel,
            goalLabel: entry.goalLabel,
            pendingBytes: 0,
            goalBytes: entry.goalBytes
        )
    }

    private func fetchEntry(for date: Date = Date()) -> SimpleEntry {
        let d = UserDefaults(suiteName: appGroupID)
        return SimpleEntry(
            date: date,
            count: d?.integer(forKey: "finalDisplayCount") ?? 0,
            goalEnabled: d?.bool(forKey: "goal_enabled") ?? false,
            goalHit: d?.bool(forKey: "goal_hit") ?? false,
            pendingLabel: d?.string(forKey: "pending_label") ?? "0 MB",
            remainingLabel: d?.string(forKey: "remaining_label") ?? "0 MB",
            goalLabel: d?.string(forKey: "goal_label") ?? "",
            pendingBytes: (d?.object(forKey: "pending_bytes") as? NSNumber)?.int64Value ?? 0,
            goalBytes: (d?.object(forKey: "goal_bytes") as? NSNumber)?.int64Value ?? 0
        )
    }
}

struct SimpleEntry: TimelineEntry {
    let date: Date
    let count: Int
    let goalEnabled: Bool
    let goalHit: Bool
    let pendingLabel: String
    let remainingLabel: String
    let goalLabel: String
    let pendingBytes: Int64
    let goalBytes: Int64
}

struct SnapSnackWidgetEntryView: View {
    var entry: Provider.Entry

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let big = clamp(w * 0.50, min: 26, max: 44)
            let cap = clamp(w * 0.16, min: 10, max: 13)

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Text("🍪")
                        .font(.system(size: cap + 5))

                    Text("widget.display.name", tableName: "widgelocalizable")
                        .font(.system(size: cap, weight: .bold, design: .rounded))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .allowsTightening(true)
                }

                Spacer(minLength: 4)

                if entry.goalEnabled {
                    goalView(big: big, cap: cap)
                } else {
                    countView(big: big, cap: cap)
                }
            }
            .padding(12)
            .dynamicTypeSize(.small ... .large)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .containerBackground(.background, for: .widget)
        }
    }

    @ViewBuilder
    private func countView(big: CGFloat, cap: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(entry.count)")
                .font(.system(size: big, weight: .black, design: .rounded))
                .foregroundColor(entry.count > 0 ? .orange : .gray)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .allowsTightening(true)

            Text("widget.pending.today", tableName: "widgelocalizable")
                .font(.system(size: cap - 1, weight: .bold))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .allowsTightening(true)
        }
    }

    @ViewBuilder
    private func goalView(big: CGFloat, cap: CGFloat) -> some View {
        let progress: Double = {
            guard entry.goalBytes > 0 else { return 0 }
            return min(1, Double(entry.pendingBytes) / Double(entry.goalBytes))
        }()

        VStack(alignment: .leading, spacing: 4) {
            if entry.goalHit {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: big * 0.7, weight: .black))
                        .foregroundColor(.green)
                    Text("widget.goal.done.title", tableName: "widgelocalizable")
                        .font(.system(size: cap + 1, weight: .bold, design: .rounded))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }

                Text(String(format: NSLocalizedString("widget.goal.done.subtitle",
                                                      tableName: "widgelocalizable",
                                                      comment: ""),
                            entry.goalLabel))
                    .font(.system(size: cap - 1, weight: .semibold))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                    .allowsTightening(true)
            } else {
                Text(entry.remainingLabel)
                    .font(.system(size: big * 0.85, weight: .black, design: .rounded))
                    .foregroundColor(.orange)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .allowsTightening(true)

                Text(String(format: NSLocalizedString("widget.goal.remaining.subtitle",
                                                      tableName: "widgelocalizable",
                                                      comment: ""),
                            entry.goalLabel))
                    .font(.system(size: cap - 1, weight: .semibold))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                    .allowsTightening(true)

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.secondary.opacity(0.15))
                        Capsule().fill(Color.orange).frame(width: geo.size.width * progress)
                    }
                }
                .frame(height: 4)
            }
        }
    }

    private func clamp(_ value: CGFloat, min minValue: CGFloat, max maxValue: CGFloat) -> CGFloat {
        return min(max(value, minValue), maxValue)
    }
}

@main
struct SnapSnackWidget: Widget {
    let kind = "SnapSnackWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: Provider()) { entry in
            SnapSnackWidgetEntryView(entry: entry)
        }
        .configurationDisplayName(Text("widget.display.name", tableName: "widgelocalizable"))
        .description(Text("widget.description", tableName: "widgelocalizable"))
        .supportedFamilies([.systemSmall])
    }
}
