import WidgetKit
import SwiftUI

struct Provider: TimelineProvider {
    // 确保与主 App 里的 groupID 完全一致
    let appGroupID = "group.com.claire.TastyTidy"

    func placeholder(in context: Context) -> SimpleEntry {
        SimpleEntry(date: Date(), count: 0)
    }

    func getSnapshot(in context: Context, completion: @escaping (SimpleEntry) -> ()) {
        completion(SimpleEntry(date: Date(), count: fetchCount()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SimpleEntry>) -> ()) {
        let entry = SimpleEntry(date: Date(), count: fetchCount())
        let timeline = Timeline(entries: [entry], policy: .atEnd)
        completion(timeline)
    }

    private func fetchCount() -> Int {
        let defaults = UserDefaults(suiteName: appGroupID)
        return defaults?.integer(forKey: "finalDisplayCount") ?? 0
    }
}

struct SimpleEntry: TimelineEntry {
    let date: Date
    let count: Int
}

struct SnapSnackWidgetEntryView: View {
    var entry: Provider.Entry

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width

            // 用容器宽度算字号，避免不同机型 systemSmall 可用空间差异导致截断
            let big = clamp(w * 0.50, min: 26, max: 44)   // 大数字字号
            let cap = clamp(w * 0.16, min: 10, max: 13)   // 标题/说明字号

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
            .padding(12)
            // 限制动态字体范围，避免“更大字体”把小组件挤爆
            .dynamicTypeSize(.small ... .large)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .containerBackground(.background, for: .widget)
        }
    }

    private func clamp(_ value: CGFloat, min minValue: CGFloat, max maxValue: CGFloat) -> CGFloat {
        // ✅ 用 Swift 标准库的 min/max
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
