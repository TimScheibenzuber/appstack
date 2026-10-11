import SwiftUI
import Charts

struct OverviewView: View {
    @Environment(Store.self) private var store
    @State private var hoveredDay: Date?
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    private func columns(_ count: Int) -> [GridItem] {
        #if os(iOS)
        let count = sizeClass == .compact ? max(1, count / 2) : count
        #endif
        return Array(repeating: GridItem(.flexible(), spacing: 14, alignment: .top), count: count)
    }

    var body: some View {
        let live = store.items.values.filter { !$0.trashed }
        let days = activity(live)
        let weekAgo = Date.now.addingTimeInterval(-7 * 86_400)
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(greeting).font(.system(size: 34, weight: .bold, design: .rounded))
                    Text(Date.now.formatted(date: .complete, time: .omitted)).foregroundStyle(.secondary)
                }

                LazyVGrid(columns: columns(4), spacing: 14) {
                    StatTile(value: live.count, label: "Items", icon: "square.stack.3d.up.fill", tint: .blue)
                    StatTile(value: store.count(.questions), label: "Open questions", icon: "questionmark.bubble.fill", tint: .orange)
                    StatTile(value: live.count { $0.created > weekAgo }, label: "Added this week", icon: "sparkles", tint: .purple)
                    StatTile(value: store.count(.inbox), label: "Unsorted in Inbox", icon: "tray.fill", tint: .teal)
                }

                LazyVGrid(columns: columns(2), spacing: 14) {
                    Card(title: "Captured per day", subtitle: "Last 30 days · \(days.reduce(0) { $0 + $1.count }) items") {
                        activityChart(days)
                    }
                    Card(title: "Items per space", subtitle: "Where your work lives") {
                        spaceChart(live)
                    }
                    Card(title: "Continue where you left off") {
                        list(Array(live.sorted { $0.updated > $1.updated }.prefix(6)), empty: "Nothing yet. Press ⌘N.")
                    }
                    Card(title: "Open questions") {
                        list(Array(live.filter { $0.kind == .question && $0.status != .done }.sorted { $0.updated > $1.updated }.prefix(6)),
                             empty: "No open questions.")
                    }
                }

                if store.count(.inbox) > 0 {
                    HStack(spacing: 14) {
                        Image(systemName: "wand.and.sparkles").font(.title2).foregroundStyle(.purple)
                        VStack(alignment: .leading) {
                            Text("\(store.count(.inbox)) items wait in your Inbox").font(.headline)
                            Text("On-device AI files them into spaces where similar items already live.").font(.callout).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Auto-Sort") { store.autoSort() }.buttonStyle(.glassProminent)
                    }
                    .padding(18)
                    .glassEffect(.regular.tint(.purple.opacity(0.12)), in: .rect(cornerRadius: 20))
                }
            }
            .padding(28)
            .frame(maxWidth: 1180)
            .frame(maxWidth: .infinity)
        }
        .background(alignment: .top) {
            OrbitBackground().frame(height: 260).mask(LinearGradient(colors: [.black.opacity(0.35), .clear], startPoint: .top, endPoint: .bottom))
        }
    }

    private var greeting: String {
        switch Calendar.current.component(.hour, from: .now) {
        case 5..<12: "Good morning"
        case 12..<18: "Good afternoon"
        default: "Good evening"
        }
    }

    // MARK: Charts

    private struct Day: Identifiable {
        let date: Date
        let count: Int
        var id: Date { date }
    }

    private func activity(_ items: [Item]) -> [Day] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let counts = Dictionary(grouping: items, by: { calendar.startOfDay(for: $0.created) }).mapValues(\.count)
        return (0..<30).reversed().compactMap { offset in
            calendar.date(byAdding: .day, value: -offset, to: today).map { Day(date: $0, count: counts[$0] ?? 0) }
        }
    }

    private func activityChart(_ days: [Day]) -> some View {
        Chart {
            ForEach(days) { day in
                BarMark(x: .value("Day", day.date, unit: .day), y: .value("Items", day.count))
                    .foregroundStyle(Color.accentColor.opacity(hoveredDay == nil || hoveredDay == day.date ? 1 : 0.45))
                    .cornerRadius(3)
            }
            if let hoveredDay, let day = days.first(where: { $0.date == hoveredDay }) {
                RuleMark(x: .value("Day", day.date, unit: .day))
                    .foregroundStyle(.secondary.opacity(0.3))
                    .annotation(position: .top, overflowResolution: .init(x: .fit, y: .disabled)) {
                        VStack(spacing: 2) {
                            Text(day.date.formatted(.dateTime.weekday().day().month())).font(.caption2).foregroundStyle(.secondary)
                            Text("\(day.count) item\(day.count == 1 ? "" : "s")").font(.caption.weight(.semibold))
                        }
                        .padding(6)
                        .background(.background, in: .rect(cornerRadius: 8))
                        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
                    }
            }
        }
        .chartXSelection(value: Binding(get: { hoveredDay }, set: { hoveredDay = $0.map { Calendar.current.startOfDay(for: $0) } }))
        .chartXAxis {
            AxisMarks(values: .stride(by: .day, count: 7)) { _ in
                AxisValueLabel(format: .dateTime.day().month(.abbreviated))
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { _ in
                AxisGridLine().foregroundStyle(.quaternary)
                AxisValueLabel()
            }
        }
        .frame(height: 180)
    }

    private func spaceChart(_ items: [Item]) -> some View {
        let rows: [(Space?, Int)] = store.meta.spaces.map { space -> (Space?, Int) in (space, items.count { $0.space == space.id }) }
            + [(nil, items.count { $0.space == nil })]
        let top = max(rows.map(\.1).max() ?? 1, 1)
        return VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                let space = row.0, count = row.1
                HStack(spacing: 10) {
                    Label(space?.name ?? "Inbox", systemImage: space?.icon ?? "tray")
                        .font(.callout)
                        .frame(width: 120, alignment: .leading)
                        .lineLimit(1)
                    GeometryReader { geo in
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(space?.color ?? .gray)
                            .frame(width: max(4, geo.size.width * CGFloat(count) / CGFloat(top)))
                            .animation(.smooth, value: count)
                    }
                    .frame(height: 12)
                    Text("\(count)").font(.callout.monospacedDigit()).foregroundStyle(.secondary).frame(width: 36, alignment: .trailing)
                }
            }
        }
    }

    private func list(_ items: [Item], empty: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if items.isEmpty { Text(empty).font(.callout).foregroundStyle(.tertiary) }
            ForEach(items) { item in
                Button {
                    store.selection = [item.id]
                    if item.kind == .mindmap { store.focused = item.id }
                } label: {
                    HStack(spacing: 10) {
                        Thumb(item: item, size: 26)
                        Text(item.display).lineLimit(1)
                        Spacer()
                        Text(item.updated.formatted(.relative(presentation: .named))).font(.caption).foregroundStyle(.tertiary)
                    }
                    .contentShape(.rect)
                    .padding(.vertical, 3)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

struct StatTile: View {
    let value: Int
    let label: String
    let icon: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: icon).font(.title3).foregroundStyle(tint)
            Text("\(value)")
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .contentTransition(.numericText(value: Double(value)))
                .animation(.snappy, value: value)
            Text(label).font(.callout).foregroundStyle(.secondary)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: .rect(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(.separator.opacity(0.5)))
        .hoverLift()
    }
}
