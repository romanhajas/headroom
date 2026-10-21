// Fetcher.swift - asks Anthropic's usage endpoint for your plan's limits.
//
// It signs in the way Claude Code does, with Claude Code's own sign-in, and calls
// the read-only endpoint behind the usage page in Claude's settings. That call
// uses no tokens and doesn't start a session. The sign-in is never saved.

import Foundation

enum Fetcher {
    struct Result {
        var limits: Limits
        /// Set when the server asked us to slow down.
        var retryAfter: TimeInterval?
    }

    static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    static func fetch(previous: Limits?) async -> Result {
        let now = Date()
        /// Keeps the last figures, with a new status.
        func keep(_ status: Limits.Status, retryAfter: TimeInterval? = nil) -> Result {
            var limits = previous ?? Limits(checkedAt: now, status: status)
            limits.checkedAt = now
            limits.status = status
            return Result(limits: limits, retryAfter: retryAfter)
        }

        guard let signIn = SignIn.current() else { return keep(.signedOut) }
        // Claude Code renews its sign-in whenever it runs; until then the server would refuse it.
        if let expires = signIn.expiresAt, expires < now.addingTimeInterval(60) { return keep(.paused) }

        var request = URLRequest(url: usageURL, timeoutInterval: 20)
        request.setValue("Bearer \(signIn.token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("claude-code/\(SignIn.claudeCodeVersion())", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let http = response as? HTTPURLResponse
            switch http?.statusCode ?? 0 {
            case 200:
                guard let limits = parse(data, at: now) else { return keep(.failed) }
                return Result(limits: limits)
            case 401:
                return keep(.signedOut)
            case 429:
                let wait = http?.value(forHTTPHeaderField: "retry-after").flatMap(Double.init) ?? 0
                return keep(.rateLimited, retryAfter: wait)
            default:
                return keep(.failed)
            }
        } catch {
            return keep(.offline)
        }
    }

    /// {"five_hour": {"utilization": 33.0, "resets_at": "2026-10-22T03:30:00.12+00:00"}, "seven_day": {...}, ...}
    /// utilization is a percentage; resets_at is null when no window is open.
    static func parse(_ data: Data, at now: Date) -> Limits? {
        guard let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], body["five_hour"] != nil else { return nil }
        func window(_ key: String) -> Limits.Window? {
            guard let w = body[key] as? [String: Any], let utilization = (w["utilization"] as? NSNumber)?.doubleValue else { return nil }
            return Limits.Window(used: utilization / 100, resetsAt: (w["resets_at"] as? String).flatMap(date))
        }
        return Limits(session: window("five_hour"), week: window("seven_day"),
                      weekOpus: window("seven_day_opus"), weekSonnet: window("seven_day_sonnet"),
                      measuredAt: now, checkedAt: now, status: .ok)
    }

    private static func date(_ text: String) -> Date? {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: text) { return d }
        iso.formatOptions = [.withInternetDateTime]
        return iso.date(from: text)
    }
}

/// Claude Code's sign-in: its environment variable, the login keychain, or its credentials file.
struct SignIn {
    let token: String
    let expiresAt: Date?

    static func current() -> SignIn? {
        if let token = ProcessInfo.processInfo.environment["CLAUDE_CODE_OAUTH_TOKEN"], token.hasPrefix("sk-ant-oat") {
            return SignIn(token: token, expiresAt: nil)
        }
        if let data = keychainItem(), let signIn = parse(data) { return signIn }
        let file = LimitsStore.home.appendingPathComponent(".claude/.credentials.json")
        if let data = try? Data(contentsOf: file), let signIn = parse(data) { return signIn }
        return nil
    }

    /// Read through /usr/bin/security, so the keychain's "Always Allow" outlives app updates.
    private static func keychainItem() -> Data? {
        let security = Process()
        security.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        security.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        let out = Pipe()
        security.standardOutput = out
        security.standardError = FileHandle.nullDevice
        do { try security.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        security.waitUntilExit()
        return security.terminationStatus == 0 ? data : nil
    }

    /// The item holds more than one sign-in; the Claude subscription's is under claudeAiOauth.
    private static func parse(_ data: Data) -> SignIn? {
        guard let item = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let oauth = item["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, token.hasPrefix("sk-ant-oat") else { return nil }
        let expires = (oauth["expiresAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
        return SignIn(token: token, expiresAt: expires)
    }

    /// Claude Code's version, from the folder its launcher points into (…/versions/2.1.280).
    static func claudeCodeVersion() -> String {
        let launchers = [LimitsStore.home.appendingPathComponent(".local/bin/claude").path, "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
        for launcher in launchers {
            let real = URL(fileURLWithPath: launcher).resolvingSymlinksInPath().path
            if let version = real.split(separator: "/").last(where: { $0.range(of: #"^\d+\.\d+\.\d+$"#, options: .regularExpression) != nil }) {
                return String(version)
            }
        }
        return "2.1.0"
    }
}
