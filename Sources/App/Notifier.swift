// Notifier.swift - macOS notifications when the limits need your attention.
//
// Each kind is sent at most once per window (the session's 5 hours, or the week), and
// each group can be switched off in Settings.

import Foundation
import UserNotifications

enum Notifier {
    static func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Looks at a new reading next to the one before it and sends what's newly true.
    static func check(old: Limits?, new: Limits, now: Date = Date()) {
        guard new.status == .ok else { return }
        let defaults = UserDefaults.standard
        let r = Reading(new, at: now)

        if defaults.object(forKey: Prefs.notifySession) as? Bool ?? true, let ends = r.sessionEnds, let used = r.sessionUsed {
            if used >= 0.95 {
                send(.session95, window: ends, title: "Session almost used up (\(percent(used)))",
                     body: "It resets at \(When.clock(ends)).")
            } else if used >= 0.8 {
                send(.session80, window: ends, title: "\(percent(used)) of your session used",
                     body: "It resets at \(When.clock(ends)).")
            }
        }
        // A heavy session (80% or more) that has now reset.
        if defaults.object(forKey: Prefs.notifySession) as? Bool ?? true,
           let last = old?.session, let lastEnds = last.resetsAt, lastEnds <= now, last.used >= 0.8 {
            send(.sessionReset, window: lastEnds, title: "Your session limit has reset",
                 body: "You're back to the full 5 hours.")
        }
        if defaults.object(forKey: Prefs.notifyPace) as? Bool ?? true {
            if let out = r.runsOutAt, let ends = r.sessionEnds {
                send(.sessionPace, window: ends, title: "Session limit at \(When.clock(out)) at this pace",
                     body: "That's before it resets at \(When.clock(ends)).")
            }
            if let out = r.weekRunsOutAt, let resets = r.weekResets {
                send(.weekPace, window: resets, title: "Weekly limit by \(When.dayClock(out)) at this pace",
                     body: "The week resets \(When.dayClock(resets)).")
            }
        }
        if defaults.object(forKey: Prefs.notifyWeek) as? Bool ?? true, let resets = r.weekResets, let used = r.weekUsed {
            if used >= 0.95 {
                send(.week95, window: resets, title: "Weekly limit almost used up (\(percent(used)))",
                     body: "The week resets \(When.dayClock(resets)).")
            } else if used >= 0.8 {
                send(.week80, window: resets, title: "\(percent(used)) of your weekly limit used",
                     body: "The week resets \(When.dayClock(resets)).")
            }
        }
    }

    private enum Kind: String { case session80, session95, sessionReset, sessionPace, week80, week95, weekPace }

    /// Sends a notification unless this kind was already sent for this window.
    private static func send(_ kind: Kind, window: Date, title: String, body: String) {
        let key = "notified.\(kind.rawValue)"
        let stamp = window.timeIntervalSince1970.rounded()
        guard UserDefaults.standard.double(forKey: key) != stamp else { return }
        UserDefaults.standard.set(stamp, forKey: key)

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "\(kind.rawValue)-\(stamp)", content: content, trigger: nil))
    }
}
