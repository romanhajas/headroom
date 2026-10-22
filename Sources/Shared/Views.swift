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
    static let image = load("Badge")
    /// Two optional poses (Badge-walk-1.svg, Badge-walk-2.svg) that make it walk in the popover.
    static let walkPoses = ["Badge-walk-1", "Badge-walk-2"].compactMap(load)
    /// An optional eyes-closed pose (Badge-sleep.svg) for while Headroom is paused.
    static let sleepPose = load("Badge-sleep")

    static func load(_ name: String) -> NSImage? {
        Bundle.main.url(forResource: name, withExtension: "svg").flatMap(NSImage.init(contentsOf:))
    }

    var size: CGFloat = 16
    var sleeping = false

    var body: some View {
        if let image = sleeping ? (Self.sleepPose ?? Self.image) : Self.image {
            Image(nsImage: image).resizable().aspectRatio(contentMode: .fit).frame(width: size, height: size)
                .overlay(alignment: .topTrailing) {
                    if sleeping {
                        Text("z").font(.system(size: size * 0.5, weight: .bold)).foregroundStyle(.secondary)
                            .offset(x: size * 0.35, y: -size * 0.35)
                    }
                }
        }
    }
}

/// A percentage that counts to its value when that value is animated.
struct CountingPercent: View, Animatable {
    var value: Double
    var suffix = ""
    var animatableData: Double {
        get { value }
        set { value = newValue }
    }

    var body: some View { Text(percent(value) + suffix) }
}

/// The 5-hour session as a ring: how much is used around it, the time left inside.
/// `animated` sweeps it in and counts the percentage up when it appears (the popover);
/// a widget can only show each reading, rolling the numbers when one changes.
struct SessionRing: View {
    let reading: Reading
    var lineWidth: CGFloat = 9
    var animated = false
    @State private var shown: Double?

    var body: some View {
        let used = min(1, reading.sessionUsed ?? 0)
        let drawn = animated ? (shown ?? 0) : used
        ZStack {
            // Inset by half the line, so the stroke stays inside the ring's frame.
            ZStack {
                Circle().stroke(.quaternary, lineWidth: lineWidth)
                Circle()
                    .trim(from: 0, to: drawn)
                    .stroke(Tone.color(for: used), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .opacity(drawn > 0 ? 1 : 0)
            }
            .padding(lineWidth / 2)
            VStack(spacing: 1) {
                if let ends = reading.sessionEnds {
                    Text(ends, style: .timer)
                        .font(.system(.title3, design: .rounded).weight(.semibold))
                        .monospacedDigit()
                        .multilineTextAlignment(.center)
                    Group {
                        if animated {
                            CountingPercent(value: drawn, suffix: " used")
                        } else {
                            Text("\(percent(reading.sessionUsed)) used").contentTransition(.numericText(value: used))
                        }
                    }
                    .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                } else {
                    Text("Ready")
                        .font(.system(.title3, design: .rounded).weight(.semibold))
                    Text("no session").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .padding(lineWidth + 10)
        }
        .opacity(reading.note.map { $0.isCalm ? 0.75 : 0.5 } ?? 1)
        .animation(.smooth, value: used)
        .onAppear { if animated { withAnimation(.easeOut(duration: 0.9)) { shown = used } } }
        .onChange(of: used) { _, new in if animated { withAnimation(.easeOut(duration: 0.6)) { shown = new } } }
    }
}

/// A labelled bar for one limit. `animated` works as for SessionRing.
struct Meter: View {
    let title: String
    let used: Double?
    var detail: String? = nil
    var animated = false
    @State private var shown: Double?

    var body: some View {
        let target = min(1, used ?? 0)
        let drawn = animated ? (shown ?? 0) : target
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title)
                Spacer(minLength: 4)
                Group {
                    if animated && used != nil {
                        CountingPercent(value: drawn)
                    } else {
                        Text(percent(used)).contentTransition(.numericText(value: target))
                    }
                }
                .monospacedDigit().foregroundStyle(.secondary)
            }
            .font(.caption.weight(.medium))
            GeometryReader { box in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(Tone.color(for: used))
                        .frame(width: max(5, box.size.width * drawn))
                        .opacity(drawn > 0 ? 1 : 0)
                }
            }
            .frame(height: 5)
            if let detail {
                Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .animation(.smooth, value: target)
        .onAppear { if animated { withAnimation(.easeOut(duration: 0.9)) { shown = target } } }
        .onChange(of: target) { _, new in if animated { withAnimation(.easeOut(duration: 0.6)) { shown = new } } }
    }
}

/// "Session", or why the figures can't be trusted right now, or when you'll hit the
/// limit if you keep going at this pace.
struct StatusLine: View {
    let reading: Reading
    var title = "Session"

    var body: some View {
        Group {
            if let note = reading.note {
                Label(note.text, systemImage: note.symbol)
                    .foregroundStyle(note.isCalm ? Color.secondary : Color.orange)
            } else if let out = reading.runsOutAt {
                Label("Limit at \(When.clock(out)) at this pace", systemImage: "gauge.with.dots.needle.100percent")
                    .foregroundStyle(.orange)
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
                Badge(size: 14, sleeping: reading.note == .paused)
            }
            SessionRing(reading: reading)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Meter(title: "Week", used: reading.weekUsed)
        }
    }
}

/// The badge living along the rest of a row. It walks, bonks into each end (squashes,
/// bounces back, sees a spark), slows down and sweats past 80% of the session, sits
/// down at 100%, sleeps while Headroom is paused, hops while a refresh runs, stops and
/// leans toward the pointer when you hover, celebrates a fresh session, and jumps with
/// a spin and a heart when clicked. Needs the two walking poses; widgets can't run it.
struct BadgeWalker: View {
    let busy: Bool
    var sleeping = false
    var used: Double? = nil
    var sessionEnds: Date? = nil
    var size: CGFloat = 16
    @State private var clickedAt: Date?
    @State private var celebratedAt: Date?
    /// Hovering stops the walk; time spent stopped is left out, so it carries on from where it was.
    @State private var stoppedAt: Date?
    @State private var stoppedFor = 0.0
    @State private var pointerX: CGFloat?
    /// The end of the session window seen last time, to notice a reset even while closed.
    @AppStorage("lastSessionEnd") private var lastSessionEnd = 0.0

    private static let bonk = 0.7       // seconds spent bumping into each end
    private static let jump = 0.9       // seconds a click's jump lasts
    private static let party = 1.4      // seconds a celebration lasts
    private static let notice = 0.8     // seconds the "!" shows after you hover

    private enum Extra { case none, spark(Double, Double), heart(Double), sweat, zzz, notice(Double), confetti(Double) }

    /// Everything about one frame of the figure.
    private struct Frame {
        var pose: NSImage
        var x: Double
        var lift = 0.0
        var spin = 0.0
        var scale = CGSize(width: 1, height: 1)
        var anchor = UnitPoint.bottom
        var extra = Extra.none
    }

    /// Where the walk is at time `t`: position, how far into a bonk (0...1) if bonking,
    /// and which wall it's heading for (1 right, -1 left).
    private static func walk(at t: Double, span: Double, speed: Double) -> (x: Double, bonk: Double?, wall: Double) {
        let leg = span / speed
        let phase = t.truncatingRemainder(dividingBy: 2 * (leg + bonk))
        if phase < leg { return (phase * speed, nil, 1) }
        if phase < leg + bonk { return (span, (phase - leg) / bonk, 1) }
        if phase < 2 * leg + bonk { return (span - (phase - leg - bonk) * speed, nil, -1) }
        return (0, (phase - 2 * leg - bonk) / bonk, -1)
    }

    /// How far into a short effect (0..<1) that started at `start`, or nil once it's over.
    private static func progress(since start: Date?, at now: Date, lasting: Double) -> Double? {
        guard let start else { return nil }
        let p = now.timeIntervalSince(start) / lasting
        return p < 1 ? p : nil
    }

    private func frame(at now: Date, span: Double) -> Frame {
        let t = now.timeIntervalSinceReferenceDate
        let stand = Badge.image ?? Badge.walkPoses[0]
        let load = used ?? 0
        var f = Frame(pose: stand, x: span / 2)
        if sleeping {
            f.pose = Badge.sleepPose ?? stand
            f.scale.height = 1 + 0.05 * sin(t * 2)  // breathing
            f.extra = .zzz
        } else if load >= 1 {
            f.scale = CGSize(width: 1.1, height: 0.8)  // sat down, worn out
            f.extra = .sweat
        } else {
            let tired = load >= 0.8
            // Walk time stands still while you hover.
            let walkT = (stoppedAt ?? now).timeIntervalSinceReferenceDate - stoppedFor
            let (x, bonk, wall) = Self.walk(at: walkT, span: span, speed: tired ? 9 : 18)
            let squash = bonk.map { sin($0 * .pi) } ?? 0
            f.x = x - wall * 3 * squash
            f.scale = CGSize(width: 1 - 0.22 * squash, height: 1 + 0.14 * squash)
            f.anchor = wall > 0 ? .trailing : .leading
            if let pointerX {
                // Stopped, leaning toward the pointer.
                f.spin = pointerX > f.x + size / 2 ? 10 : -10
                if let p = Self.progress(since: stoppedAt, at: now, lasting: Self.notice) { f.extra = .notice(p) }
            } else {
                // Legs move while walking (slower when tired); standing still while bonking.
                f.pose = bonk == nil ? Badge.walkPoses[Int(t * (tired ? 3 : 5)) % 2] : stand
                if let bonk { f.extra = .spark(bonk, wall) } else if tired { f.extra = .sweat }
            }
            if busy { f.lift = abs(sin(t * 9)) * 4 }
        }
        if let p = Self.progress(since: celebratedAt, at: now, lasting: Self.party) {
            f.pose = stand
            f.lift = abs(sin(p * .pi * 2)) * 14
            f.spin = 0
            f.extra = .confetti(p)
        }
        if let p = Self.progress(since: clickedAt, at: now, lasting: Self.jump) {
            f.pose = stand
            f.lift = sin(p * .pi) * 11
            f.spin = p * 360
            f.extra = .heart(p)
        }
        return f
    }

    /// Celebrates when the window seen last time has ended: a fresh session.
    private func checkForFreshSession() {
        if lastSessionEnd > 0 && lastSessionEnd < Date().timeIntervalSince1970 { celebratedAt = Date() }
        lastSessionEnd = sessionEnds?.timeIntervalSince1970 ?? 0
    }

    var body: some View {
        GeometryReader { box in
            TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                let f = frame(at: context.date, span: max(1, Double(box.size.width - size)))
                Image(nsImage: f.pose)
                    .resizable()
                    .frame(width: size, height: size)
                    .scaleEffect(x: f.scale.width, y: f.scale.height, anchor: f.anchor)
                    .rotationEffect(.degrees(f.spin))
                    .overlay(alignment: .top) { extra(f.extra, t: t) }
                    .contentShape(Rectangle())
                    .onTapGesture { clickedAt = Date() }
                    .offset(x: f.x, y: -f.lift)
            }
        }
        .frame(height: size)
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            switch phase {
            case .active(let location):
                pointerX = location.x
                if stoppedAt == nil { stoppedAt = Date() }
            case .ended:
                if let stoppedAt { stoppedFor += Date().timeIntervalSince(stoppedAt) }
                stoppedAt = nil
                pointerX = nil
            }
        }
        .onAppear(perform: checkForFreshSession)
        .onChange(of: sessionEnds) { _, _ in checkForFreshSession() }
    }

    @ViewBuilder
    private func extra(_ extra: Extra, t: Double) -> some View {
        switch extra {
        case .none:
            EmptyView()
        case .spark(let p, let wall):
            Text("✦").font(.system(size: 7, weight: .bold)).foregroundStyle(.orange)
                .offset(x: -wall * 3, y: -7 - 4 * p).opacity(sin(p * .pi))
        case .heart(let p):
            Text("♥").font(.system(size: 8)).foregroundStyle(.pink)
                .offset(y: -8 - 10 * p).opacity(1 - p)
        case .sweat:
            Text("💧").font(.system(size: 6))
                .offset(x: -size * 0.45, y: -2 + sin(t * 5)).opacity(0.6 + 0.4 * sin(t * 3))
        case .zzz:
            ZStack {
                ForEach(0..<3, id: \.self) { i in
                    let p = (t * 0.5 + Double(i) / 3).truncatingRemainder(dividingBy: 1)
                    Text("z").font(.system(size: 5 + 3 * p, weight: .bold)).foregroundStyle(.secondary)
                        .offset(x: size * 0.4 + 6 * p, y: -4 - 12 * p).opacity(sin(p * .pi))
                }
            }
        case .notice(let p):
            Text("!").font(.system(size: 9, weight: .heavy)).foregroundStyle(.orange)
                .offset(y: -9 - 3 * min(1, p * 4)).opacity(1 - p * p)
        case .confetti(let p):
            ZStack {
                ForEach(0..<5, id: \.self) { i in
                    let angle = Double(i) / 5 * 2 * .pi + 0.3
                    Text("✦").font(.system(size: 6, weight: .bold))
                        .foregroundStyle([Color.orange, .pink, .yellow, .green, .blue][i])
                        .offset(x: cos(angle) * 14 * p, y: -6 - sin(angle) * 10 * p - 4 * p)
                        .opacity(1 - p)
                }
            }
        }
    }
}

struct MediumLimits: View {
    let reading: Reading
    /// In the popover: the ring and bars sweep in, and the badge lives along the title row
    /// when its walking poses are installed. A widget can't animate like that.
    var live = false
    var busy = false

    var body: some View {
        HStack(spacing: 18) {
            SessionRing(reading: reading, lineWidth: 11, animated: live)
                .aspectRatio(1, contentMode: .fit)
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 6) {
                    StatusLine(reading: reading, title: "Headroom").fixedSize()
                    if live && Badge.walkPoses.count >= 2 {
                        BadgeWalker(busy: busy, sleeping: reading.note == .paused,
                                    used: reading.sessionUsed, sessionEnds: reading.sessionEnds)
                    } else {
                        Spacer(minLength: 0)
                        Badge(sleeping: reading.note == .paused)
                    }
                }
                Meter(title: "Session", used: reading.sessionUsed,
                      detail: reading.sessionEnds.map { "Resets \(When.clock($0))" } ?? "Starts with your next message",
                      animated: live)
                Meter(title: "This week", used: reading.weekUsed,
                      detail: reading.weekResets.map { "Resets \(When.dayClock($0))" }, animated: live)
            }
        }
    }
}
