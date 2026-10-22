// Limits.swift - one reading of your plan's usage limits, shared by the app and its widget.

import Foundation

struct Limits: Codable, Equatable {
    struct Window: Codable, Equatable {
        /// Share of the limit used, 0...1.
        var used: Double
        /// When the window resets; nil when none is open.
        var resetsAt: Date?
    }

    enum Status: String, Codable {
        case ok
        case paused       // Claude Code's sign-in lapsed because it hasn't run lately
        case signedOut    // no sign-in found, or the server turned it down
        case rateLimited
        case offline
        case failed
    }

    var session: Window?
    var week: Window?
    var weekOpus: Window?
    var weekSonnet: Window?
    /// When these figures came from the server.
    var measuredAt: Date?
    /// When the app last asked.
    var checkedAt: Date
    var status: Status

    static let sample = Limits(session: Window(used: 0.32, resetsAt: Date().addingTimeInterval(2.6 * 3600)),
                               week: Window(used: 0.18, resetsAt: Date().addingTimeInterval(4 * 86400)),
                               measuredAt: Date(), checkedAt: Date(), status: .ok)
}

/// The app writes the latest reading here; the widget reads it.
enum LimitsStore {
    /// Your real home folder. Inside the widget's sandbox, NSHomeDirectory() is its container.
    static let home: URL = {
        if let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
        }
        return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    }()
    static let folder = home.appendingPathComponent("Library/Application Support/Headroom", isDirectory: true)
    static let file = folder.appendingPathComponent("limits.json")

    static func load() -> Limits? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? decoder.decode(Limits.self, from: data)
    }

    static func save(_ limits: Limits) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try encoder.encode(limits).write(to: file, options: .atomic)
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

/// What to show at one moment, worked out from the last reading. A window whose
/// reset time has passed shows as reset, so the widget is right even between readings.
struct Reading {
    enum Note: Equatable {
        case paused, signedOut, rateLimited, offline, failed, notUpdating, noData

        var text: String {
            switch self {
            case .paused: "Paused · open Claude Code"
            case .signedOut: "Sign in to Claude Code"
            case .rateLimited: "Server busy · will retry"
            case .offline: "Offline"
            case .failed: "Couldn't read usage"
            case .notUpdating: "Not updating"
            case .noData: "Waiting for a reading"
            }
        }

        var symbol: String {
            switch self {
            case .paused: "pause.circle.fill"
            case .signedOut: "person.crop.circle.badge.exclamationmark"
            case .rateLimited: "hourglass"
            case .offline: "wifi.slash"
            case .failed, .notUpdating: "exclamationmark.triangle.fill"
            case .noData: "clock"
            }
        }

        /// Nothing is wrong, the figures just aren't moving: shown in grey, not as a warning.
        var isCalm: Bool { self == .paused || self == .noData }
    }

    var sessionUsed: Double?
    var sessionEnds: Date?
    var weekUsed: Double?
    var weekResets: Date?
    var weekOpusUsed: Double?
    var weekSonnetUsed: Double?
    var measuredAt: Date?
    var note: Note?
    /// When the session limit will be hit at the pace used so far, if that's before
    /// the session resets; nil while there's room to spare.
    var runsOutAt: Date?

    /// Figures older than this are flagged: the app isn't getting new ones.
    static let staleAfter: TimeInterval = 40 * 60
    /// The session window's length.
    static let window: TimeInterval = 5 * 3600
    /// Too early in a session to judge its pace.
    static let paceAfter: TimeInterval = 15 * 60

    init(_ limits: Limits?, at now: Date) {
        guard let limits else { note = .noData; return }
        func current(_ window: Limits.Window?) -> (Double?, Date?) {
            guard let window else { return (nil, nil) }
            guard let resets = window.resetsAt else { return (window.used, nil) }
            return resets > now ? (window.used, resets) : (0, nil)
        }
        (sessionUsed, sessionEnds) = current(limits.session)
        (weekUsed, weekResets) = current(limits.week)
        weekOpusUsed = current(limits.weekOpus).0
        weekSonnetUsed = current(limits.weekSonnet).0
        measuredAt = limits.measuredAt

        // Pace: the share used per second so far, as of the reading, run forward.
        if let used = sessionUsed, used > 0, used < 1, let ends = sessionEnds, let measured = limits.measuredAt {
            let elapsed = Self.window - ends.timeIntervalSince(measured)
            if elapsed >= Self.paceAfter {
                let out = measured.addingTimeInterval((1 - used) / (used / elapsed))
                if out > now && out < ends { runsOutAt = out }
            }
        }

        let stale = limits.measuredAt.map { now.timeIntervalSince($0) > Self.staleAfter } ?? true
        guard stale else { return }
        switch limits.status {
        case .ok: note = limits.measuredAt == nil ? .noData : .notUpdating
        case .paused: note = .paused
        case .signedOut: note = .signedOut
        case .rateLimited: note = .rateLimited
        case .offline: note = .offline
        case .failed: note = .failed
        }
    }

    /// Moments after `now` when the reading changes with no new data: a window
    /// resets, or the figures get old enough to flag.
    static func changes(of limits: Limits?, after now: Date) -> [Date] {
        guard let limits else { return [] }
        let moments = [limits.session?.resetsAt, limits.week?.resetsAt, limits.measuredAt?.addingTimeInterval(staleAfter),
                       Reading(limits, at: now).runsOutAt]
        return moments.compactMap { $0?.addingTimeInterval(1) }.filter { $0 > now }.sorted()
    }
}
