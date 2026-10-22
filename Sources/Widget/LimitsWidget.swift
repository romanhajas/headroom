// LimitsWidget.swift - the desktop and Notification Center widget.

import SwiftUI
import WidgetKit

@main
struct HeadroomWidgets: WidgetBundle {
    var body: some Widget { LimitsWidget() }
}

struct LimitsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "io.github.romanhajas.headroom.limits", provider: LimitsProvider()) { entry in
            LimitsWidgetView(entry: entry)
                .containerBackground(.background, for: .widget)
                .widgetURL(URL(string: "headroom://refresh"))
        }
        .configurationDisplayName("Headroom")
        .description("Time left in your Claude session and how much of your limits you've used.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct LimitsEntry: TimelineEntry {
    let date: Date
    let limits: Limits?
    var days: [History.Day] = []
}

/// Reads what the app saved, and adds an entry for every moment the picture changes
/// on its own (a window resetting, the figures getting old) so the widget stays right
/// even when macOS reloads it late. The countdown itself ticks without reloads.
struct LimitsProvider: TimelineProvider {
    func placeholder(in context: Context) -> LimitsEntry {
        LimitsEntry(date: .now, limits: .sample)
    }

    func getSnapshot(in context: Context, completion: @escaping (LimitsEntry) -> Void) {
        let saved = LimitsStore.load()
        completion(LimitsEntry(date: .now, limits: context.isPreview ? (saved ?? .sample) : saved,
                               days: History.perDay(History.load())))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<LimitsEntry>) -> Void) {
        let now = Date(), limits = LimitsStore.load()
        let days = context.family == .systemLarge ? History.perDay(History.load(), now: now) : []
        var moments = [now] + Reading.changes(of: limits, after: now, staleAfter: Reading.widgetStaleAfter)
        // The inner ring moves with the clock: an entry every 2 minutes while a session runs.
        // Planned entries don't count against the widget's reload allowance.
        if let ends = limits?.session?.resetsAt, ends > now {
            moments += Array(stride(from: now.addingTimeInterval(120), to: ends, by: 120))
        }
        completion(Timeline(entries: Set(moments).sorted().map { LimitsEntry(date: $0, limits: limits, days: days) },
                            policy: .after(now.addingTimeInterval(15 * 60))))
    }
}

struct LimitsWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: LimitsEntry

    var body: some View {
        let reading = Reading(entry.limits, at: entry.date, staleAfter: Reading.widgetStaleAfter)
        switch family {
        case .systemLarge: LargeLimits(reading: reading, days: entry.days)
        case .systemMedium: MediumLimits(reading: reading)
        default: SmallLimits(reading: reading)
        }
    }
}
