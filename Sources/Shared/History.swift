// History.swift - a light history of readings, for the chart of usage per day.

import Foundation

struct Sample: Codable {
    var t: Date      // when it was measured
    var s: Double?   // session used, 0...1
    var w: Double?   // week used, 0...1
}

enum History {
    static let file = LimitsStore.folder.appendingPathComponent("history.json")
    /// Kept for a little over a month.
    static let keep: TimeInterval = 35 * 86400

    static func load() -> [Sample] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        return (try? decoder.decode([Sample].self, from: data)) ?? []
    }

    /// Adds a reading when it differs from the last one kept, or every 15 minutes.
    static func record(_ limits: Limits) {
        guard limits.status == .ok, let t = limits.measuredAt else { return }
        var samples = load()
        let s = limits.session?.used, w = limits.week?.used
        if let last = samples.last, last.s == s, last.w == w, t.timeIntervalSince(last.t) < 15 * 60 { return }
        samples.append(Sample(t: t, s: s, w: w))
        samples.removeAll { t.timeIntervalSince($0.t) > keep }
        try? FileManager.default.createDirectory(at: LimitsStore.folder, withIntermediateDirectories: true)
        try? encoder.encode(samples).write(to: file, options: .atomic)
    }

    struct Day: Identifiable {
        var date: Date
        var used: Double   // share of the weekly limit used that day
        var id: Date { date }
    }

    /// How much of the weekly limit was used on each of the last `days` days, today last.
    /// Each rise of the weekly figure counts for the day it happened; when the figure
    /// drops, the week has reset and it counts again from zero.
    static func perDay(_ samples: [Sample], days: Int = 7, now: Date = Date(), calendar: Calendar = .current) -> [Day] {
        var totals: [Date: Double] = [:]
        var previous: Double?
        for sample in samples.sorted(by: { $0.t < $1.t }) {
            guard let w = sample.w else { continue }
            if let p = previous {
                totals[calendar.startOfDay(for: sample.t), default: 0] += w >= p ? w - p : w
            }
            previous = w
        }
        let today = calendar.startOfDay(for: now)
        return (0..<days).reversed().compactMap { back in
            calendar.date(byAdding: .day, value: -back, to: today).map { Day(date: $0, used: totals[$0] ?? 0) }
        }
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        return e
    }()
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }()
}
