// HeadroomApp.swift - lives in the menu bar, keeps the reading fresh, and hosts the widget.

import AppKit
import ServiceManagement
import SwiftUI
import WidgetKit

@main
struct HeadroomApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @ObservedObject private var monitor = Monitor.shared
    @AppStorage(Prefs.showInMenuBar) private var showInMenuBar = true

    var body: some Scene {
        MenuBarExtra(isInserted: $showInMenuBar) {
            DetailView().environmentObject(monitor)
        } label: {
            MenuBarLabel(monitor: monitor)
        }
        .menuBarExtraStyle(.window)
    }
}

enum Prefs {
    static let showInMenuBar = "showInMenuBar"
    static let menuBarText = "menuBarText"
    static let refreshMinutes = "refreshMinutes"
    static let animations = "animations"
    static let setUpLoginItem = "setUpLoginItem"
    static let notifySession = "notifySession"
    static let notifyPace = "notifyPace"
    static let notifyWeek = "notifyWeek"
    static let checkUpdates = "checkUpdates"
    static let lastUpdateCheck = "lastUpdateCheck"
}

/// What the menu bar shows next to the gauge.
enum MenuBarText: String, CaseIterable {
    case percent, timeLeft, nothing

    var title: String {
        switch self {
        case .percent: "Session used (33%)"
        case .timeLeft: "Time left (3:13)"
        case .nothing: "Nothing, just the icon"
        }
    }
}

struct MenuBarLabel: View {
    @ObservedObject var monitor: Monitor
    @AppStorage(Prefs.menuBarText) private var text = MenuBarText.percent.rawValue

    var body: some View {
        let reading = Reading(monitor.limits, at: monitor.now)
        Image(nsImage: MenuBarIcon.image(used: reading.sessionUsed))
        switch MenuBarText(rawValue: text) ?? .percent {
        case .percent: Text(percent(reading.sessionUsed))
        case .timeLeft: Text(reading.sessionEnds.map { When.left(until: $0, from: monitor.now) } ?? "–")
        case .nothing: EmptyView()
        }
    }
}

/// The app icon's ring, as a menu bar template image: the arc fills as the session is used.
enum MenuBarIcon {
    static func image(used: Double?) -> NSImage {
        let image = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
            let center = NSPoint(x: rect.midX, y: rect.midY), radius: CGFloat = 6, width: CGFloat = 2.2
            let track = NSBezierPath()
            track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
            track.lineWidth = width
            NSColor.black.withAlphaComponent(0.3).setStroke()
            track.stroke()

            let fraction = min(1, max(0, used ?? 0))
            if fraction > 0 {
                let arc = NSBezierPath()
                arc.appendArc(withCenter: center, radius: radius, startAngle: 90, endAngle: 90 - 360 * fraction, clockwise: true)
                arc.lineWidth = width
                arc.lineCapStyle = .round
                NSColor.black.setStroke()
                arc.stroke()
            }

            let dot: CGFloat = 3.2
            NSColor.black.setFill()
            NSBezierPath(ovalIn: NSRect(x: center.x - dot / 2, y: center.y - dot / 2, width: dot, height: dot)).fill()
            return true
        }
        image.isTemplate = true  // drawn in the menu bar's own colour, light or dark
        return image
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Notifier.requestPermission()
        Monitor.shared.start()
        Updater.shared.checkIfDue()
        // Start with the Mac by default, once; Settings has the switch.
        if !UserDefaults.standard.bool(forKey: Prefs.setUpLoginItem) {
            UserDefaults.standard.set(true, forKey: Prefs.setUpLoginItem)
            try? SMAppService.mainApp.register()
        }
    }

    /// Opening Headroom again (Finder, Spotlight) shows Settings, so it stays
    /// reachable with the menu bar item hidden.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        SettingsWindow.show()
        return false
    }

    /// Clicking the widget opens headroom://refresh.
    func application(_ application: NSApplication, open urls: [URL]) {
        if urls.contains(where: { $0.scheme == "headroom" }) { Monitor.shared.refresh() }
    }
}

@MainActor
final class Monitor: ObservableObject {
    static let shared = Monitor()

    @Published private(set) var limits = LimitsStore.load()
    @Published private(set) var busy = false
    /// The weekly limit used per day, for the chart.
    @Published private(set) var days = History.perDay(History.load())
    /// Ticks every 30 seconds, so the menu bar's "time left" keeps moving.
    @Published private(set) var now = Date()

    private var timer: Timer?
    private var clock: Timer?
    private var notBefore: Date?
    private var backoff: TimeInterval = 0
    private var widgetMatters: String?
    private var widgetFigures: String?
    private var widgetReloaded = Date.distantPast

    var interval: TimeInterval {
        let minutes = UserDefaults.standard.integer(forKey: Prefs.refreshMinutes)
        return TimeInterval((minutes == 0 ? 3 : minutes) * 60)
    }

    func start() {
        refresh()
        reschedule()
        clock = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            Task { @MainActor in Monitor.shared.now = Date() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in Monitor.shared.refresh() }
        }
    }

    /// Restarts the regular check, e.g. after the interval changed in Settings.
    func reschedule() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            Task { @MainActor in Monitor.shared.refresh() }
        }
    }

    func refresh() {
        guard !busy else { return }
        if let notBefore, notBefore > .now { return }
        busy = true
        let previous = limits
        Task {
            apply(await Fetcher.fetch(previous: previous))
        }
    }

    private func apply(_ result: Fetcher.Result) {
        busy = false
        now = Date()
        Notifier.check(old: limits, new: result.limits)
        limits = result.limits
        try? LimitsStore.save(result.limits)
        History.record(result.limits)
        days = History.perDay(History.load())
        Updater.shared.checkIfDue()
        if let wait = result.retryAfter {
            // Wait at least 3 minutes after the server pushes back, whatever the interval.
            backoff = min(30 * 60, max(3 * 60, interval, wait, backoff * 2))
            notBefore = .now.addingTimeInterval(backoff)
        } else {
            backoff = 0
            notBefore = nil
        }
        reloadWidget()
    }

    /// Reloads the widget when what it shows changes. macOS allows a widget only a few
    /// dozen reloads a day and silently drops the rest, so they're spent carefully:
    /// what matters (a new session, a warning, the status) goes out at once; the
    /// percentages at most every 10 minutes; and every 2 hours regardless, so the
    /// widget never takes fresh figures for old ones.
    private func reloadWidget() {
        let r = Reading(limits, at: .now)
        let matters = [r.sessionEnds.map { "\(Int($0.timeIntervalSince1970 / 60))" } ?? "-",
                       r.note?.text ?? "", limits?.status.rawValue ?? "",
                       r.runsOutAt == nil ? "" : "pace", r.weekRunsOutAt == nil ? "" : "week pace"].joined(separator: "|")
        let figures = percent(r.sessionUsed) + "|" + percent(r.weekUsed)
        let since = Date.now.timeIntervalSince(widgetReloaded)
        guard matters != widgetMatters || (figures != widgetFigures && since > 10 * 60) || since > 2 * 3600 else { return }
        widgetMatters = matters
        widgetFigures = figures
        widgetReloaded = .now
        WidgetCenter.shared.reloadAllTimelines()
    }
}

struct DetailView: View {
    @EnvironmentObject private var monitor: Monitor
    @ObservedObject private var updater = Updater.shared
    @AppStorage(Prefs.animations) private var animations = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let live = animations && !reduceMotion
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let reading = Reading(monitor.limits, at: context.date)
            VStack(alignment: .leading, spacing: 14) {
                if let release = updater.available {
                    HStack {
                        Label("Headroom \(release.version) is available", systemImage: "arrow.down.circle.fill")
                            .font(.callout.weight(.medium)).foregroundStyle(.blue)
                        Spacer()
                        Link("Download", destination: release.page)
                    }
                    .padding(8)
                    .background(Color.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                }
                MediumLimits(reading: reading, live: live, busy: monitor.busy)
                    .frame(height: 118)
                if reading.weekOpusUsed != nil || reading.weekSonnetUsed != nil {
                    HStack(spacing: 16) {
                        if let opus = reading.weekOpusUsed { Meter(title: "Opus this week", used: opus, animated: live) }
                        if let sonnet = reading.weekSonnetUsed { Meter(title: "Sonnet this week", used: sonnet, animated: live) }
                    }
                }
                WeekChart(days: monitor.days)
                    .frame(height: 84)
                Divider()
                HStack {
                    Text(reading.measuredAt.map { "Updated \(When.dayClock($0))" } ?? "No reading yet")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button { monitor.refresh() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                        .disabled(monitor.busy)
                }
                HStack {
                    Button("Settings…") { SettingsWindow.show() }
                    Spacer()
                    Button("Quit Headroom") { NSApp.terminate(nil) }
                }
            }
            .padding(16)
            .frame(width: 360)
        }
    }
}
