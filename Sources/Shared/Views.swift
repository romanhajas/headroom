// Views.swift - the ring, meters and layouts, shared by the widget and the menu bar popover.

import AppKit
import SwiftUI

func percent(_ value: Double?) -> String {
    value.map { "\(Int(($0 * 100).rounded()))%" } ?? "–"
}

enum Tone {
    /// Green with room to spare, orange past half, red near the limit.
    static func color(for used: Double?) -> Color {
        guard let used else { return .secondary }
        return used < 0.5 ? .green : used < 0.8 ? .orange : .red
    }
}

enum When {
    static func clock(_ date: Date) -> String { date.formatted(date: .omitted, time: .shortened) }

    /// "3:13" until `date`, for the menu bar.
    static func left(until date: Date, from now: Date) -> String {
        let minutes = max(0, Int(date.timeIntervalSince(now) / 60))
        return String(format: "%d:%02d", minutes / 60, minutes % 60)
    }

    static func dayClock(_ date: Date) -> String {
        Calendar.current.isDateInToday(date) ? clock(date) : date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }
}

/// An optional personal badge in the corner. build.sh bundles it from
/// Support/Local/Badge.svg when that file exists; the folder is never committed.
struct Badge: View {
    static let image: NSImage? = Bundle.main.url(forResource: "Badge", withExtension: "svg").flatMap(NSImage.init(contentsOf:))
    var size: CGFloat = 16

    var body: some View {
        if let image = Self.image {
            Image(nsImage: image).resizable().aspectRatio(contentMode: .fit).frame(width: size, height: size)
        }
    }
}

/// The 5-hour session as a ring: how much is used around it, the time left inside.
struct SessionRing: View {
    let reading: Reading
    var lineWidth: CGFloat = 9

    var body: some View {
        let used = min(1, reading.sessionUsed ?? 0)
        ZStack {
            Circle().stroke(.quaternary, lineWidth: lineWidth)
            if used > 0 {
                Circle()
                    .trim(from: 0, to: used)
                    .stroke(Tone.color(for: used), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            VStack(spacing: 1) {
                if let ends = reading.sessionEnds {
                    Text(ends, style: .timer)
                        .font(.system(.title3, design: .rounded).weight(.semibold))
                        .monospacedDigit()
                        .multilineTextAlignment(.center)
                    Text("\(percent(reading.sessionUsed)) used")
                        .font(.caption2).foregroundStyle(.secondary)
                } else {
                    Text("Ready")
                        .font(.system(.title3, design: .rounded).weight(.semibold))
                    Text("no session").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .padding(lineWidth + 6)
        }
        .opacity(reading.note.map { $0.isCalm ? 0.75 : 0.5 } ?? 1)
    }
}

/// A labelled bar for one limit.
struct Meter: View {
    let title: String
    let used: Double?
    var detail: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title)
                Spacer(minLength: 4)
                Text(percent(used)).monospacedDigit().foregroundStyle(.secondary)
            }
            .font(.caption.weight(.medium))
            GeometryReader { box in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    if let used, used > 0 {
                        Capsule().fill(Tone.color(for: used)).frame(width: max(5, box.size.width * min(1, used)))
                    }
                }
            }
            .frame(height: 5)
            if let detail {
                Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }
}

/// "Session", or why the figures can't be trusted right now.
struct StatusLine: View {
    let reading: Reading
    var title = "Session"

    var body: some View {
        Group {
            if let note = reading.note {
                Label(note.text, systemImage: note.symbol)
                    .foregroundStyle(note.isCalm ? Color.secondary : Color.orange)
            } else {
                Text(title).foregroundStyle(.secondary)
            }
        }
        .font(.caption.weight(.semibold))
        .lineLimit(1)
        .minimumScaleFactor(0.7)
    }
}

struct SmallLimits: View {
    let reading: Reading

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                StatusLine(reading: reading)
                Spacer(minLength: 0)
                Badge(size: 14)
            }
            SessionRing(reading: reading)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Meter(title: "Week", used: reading.weekUsed)
        }
    }
}

struct MediumLimits: View {
    let reading: Reading

    var body: some View {
        HStack(spacing: 18) {
            SessionRing(reading: reading, lineWidth: 11)
                .aspectRatio(1, contentMode: .fit)
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 4) {
                    StatusLine(reading: reading, title: "Headroom")
                    Spacer(minLength: 0)
                    Badge()
                }
                Meter(title: "Session", used: reading.sessionUsed,
                      detail: reading.sessionEnds.map { "Resets \(When.clock($0))" } ?? "Starts with your next message")
                Meter(title: "This week", used: reading.weekUsed,
                      detail: reading.weekResets.map { "Resets \(When.dayClock($0))" })
            }
        }
    }
}
