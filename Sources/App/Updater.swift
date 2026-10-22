// Updater.swift - tells you when a newer Headroom is on GitHub.
//
// Once a day (if allowed in Settings) it asks GitHub for the latest release and
// compares its tag with this app's version. It never downloads anything itself.

import Foundation

@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()
    static let latest = URL(string: "https://api.github.com/repos/romanhajas/headroom/releases/latest")!

    struct Release { let version: String; let page: URL }

    @Published private(set) var available: Release?
    @Published private(set) var checking = false
    @Published private(set) var lastResult: String?

    static var current: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }

    /// Checks if automatic checks are on and the last one was over a day ago.
    func checkIfDue() {
        guard UserDefaults.standard.object(forKey: Prefs.checkUpdates) as? Bool ?? true else { return }
        let last = UserDefaults.standard.double(forKey: Prefs.lastUpdateCheck)
        if Date().timeIntervalSince1970 - last > 86400 { check() }
    }

    func check() {
        guard !checking else { return }
        checking = true
        Task {
            defer { checking = false }
            var request = URLRequest(url: Self.latest, timeoutInterval: 15)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            guard let (data, _) = try? await URLSession.shared.data(for: request),
                  let release = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let tag = release["tag_name"] as? String,
                  let page = (release["html_url"] as? String).flatMap(URL.init(string:)) else {
                lastResult = "Couldn't reach GitHub."
                return
            }
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Prefs.lastUpdateCheck)
            let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            if Self.isNewer(version, than: Self.current) {
                available = Release(version: version, page: page)
                lastResult = "Headroom \(version) is available."
            } else {
                available = nil
                lastResult = "You have the latest version."
            }
        }
    }

    /// "1.10" is newer than "1.9"; missing parts count as zero.
    static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let (p, q) = (i < x.count ? x[i] : 0, i < y.count ? y[i] : 0)
            if p != q { return p > q }
        }
        return false
    }
}
