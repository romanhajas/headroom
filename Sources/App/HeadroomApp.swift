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
    static let setUpLoginItem = "setUpLoginItem"
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
        Image(systemName: "gauge.with.dots.needle.33percent")
        switch MenuBarText(rawValue: text) ?? .percent {
        case .percent: Text(percent(reading.sessionUsed))
        case .timeLeft: Text(reading.sessionEnds.map { When.left(until: $0, from: monitor.now) } ?? "–")
        case .nothing: EmptyView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Monitor.shared.start()
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
    /// Ticks every 30 seconds, so the menu bar's "time left" keeps moving.
    @Published private(set) var now = Date()

    private var timer: Timer?
    private var clock: Timer?
    private var notBefore: Date?
    private var backoff: TimeInterval = 0
    private var widgetShows: String?
    private var widgetReloaded = Date.distantPast

    var interval: TimeInterval {
        let minutes = UserDefaults.standard.integer(forKey: Prefs.refreshMinutes)
        return TimeInterval(max(3, minutes == 0 ? 3 : minutes) * 60)
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
        limits = result.limits
        try? LimitsStore.save(result.limits)
        if let wait = result.retryAfter {
            backoff = min(30 * 60, max(interval, wait, backoff * 2))
            notBefore = .now.addingTimeInterval(backoff)
        } else {
            backoff = 0
            notBefore = nil
        }
        reloadWidget()
    }

    /// Reloads the widget only when what it shows changes, plus every 20 minutes so it
    /// never flags fresh figures as old. macOS limits how often a widget may reload.
    private func reloadWidget() {
        let r = Reading(limits, at: .now)
        let shows = [percent(r.sessionUsed), percent(r.weekUsed),
                     r.sessionEnds.map { "\(Int($0.timeIntervalSince1970 / 60))" } ?? "-",
                     r.note?.text ?? "", limits?.status.rawValue ?? ""].joined(separator: "|")
        guard shows != widgetShows || Date.now.timeIntervalSince(widgetReloaded) > 20 * 60 else { return }
        widgetShows = shows
        widgetReloaded = .now
        WidgetCenter.shared.reloadAllTimelines()
    }
}

struct DetailView: View {
    @EnvironmentObject private var monitor: Monitor

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let reading = Reading(monitor.limits, at: context.date)
            VStack(alignment: .leading, spacing: 14) {
                MediumLimits(reading: reading)
                    .frame(height: 118)
                if reading.weekOpusUsed != nil || reading.weekSonnetUsed != nil {
                    HStack(spacing: 16) {
                        if let opus = reading.weekOpusUsed { Meter(title: "Opus this week", used: opus) }
                        if let sonnet = reading.weekSonnetUsed { Meter(title: "Sonnet this week", used: sonnet) }
                    }
                }
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
