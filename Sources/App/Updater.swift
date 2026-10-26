// Updater.swift - keeps Headroom up to date from its GitHub releases.
//
// Once a day (if allowed in Settings) it asks GitHub for the latest release. When
// there's a newer one it downloads Headroom.zip, checks that the app inside is signed
// by the same developer as this copy, swaps it in and restarts. With automatic
// installs off, or where it can't replace itself, it offers the update instead.

import AppKit
import Security

@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()
    static let latest = URL(string: "https://api.github.com/repos/romanhajas/headroom/releases/latest")!

    struct Release { let version: String; let page: URL; let download: URL? }

    @Published private(set) var available: Release?
    @Published private(set) var checking = false
    @Published private(set) var installing = false
    @Published private(set) var lastResult: String?

    private var waiting: NSObjectProtocol?

    static var current: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }

    /// What this copy was signed to: its bundle ID and developer. An update must meet
    /// the same. Nil for a build signed ad hoc, which only tells you about new versions.
    nonisolated static let requirement: SecRequirement? = {
        var me: SecCode?, code: SecStaticCode?, requirement: SecRequirement?, text: CFString?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me,
              SecCodeCopyStaticCode(me, [], &code) == errSecSuccess, let code,
              SecCodeCopyDesignatedRequirement(code, [], &requirement) == errSecSuccess, let requirement,
              SecRequirementCopyString(requirement, [], &text) == errSecSuccess,
              (text as String?)?.contains("anchor apple generic") == true else { return nil }
        return requirement
    }()

    /// Whether Headroom can replace itself here: a signed copy, in a folder you can write to.
    var canInstall: Bool {
        Self.requirement != nil
            && FileManager.default.isWritableFile(atPath: Bundle.main.bundleURL.deletingLastPathComponent().path)
    }

    /// Checks if automatic checks are on and the last one was over a day ago.
    func checkIfDue() {
        guard UserDefaults.standard.object(forKey: Prefs.checkUpdates) as? Bool ?? true else { return }
        let last = UserDefaults.standard.double(forKey: Prefs.lastUpdateCheck)
        if Date().timeIntervalSince1970 - last > 86400 { check() }
    }

    /// `asked`: from the Check Now button, so an update installs right away rather
    /// than waiting until you've clicked away from Headroom.
    func check(asked: Bool = false) {
        guard !checking, !installing else { return }
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
            guard Self.isNewer(version, than: Self.current) else {
                available = nil
                lastResult = "You have the latest version."
                return
            }
            let assets = release["assets"] as? [[String: Any]] ?? []
            let zip = assets.first { $0["name"] as? String == "Headroom.zip" }?["browser_download_url"] as? String
            let found = Release(version: version, page: page, download: zip.flatMap(URL.init(string:)))
            available = found
            lastResult = "Headroom \(version) is available."
            if UserDefaults.standard.object(forKey: Prefs.installUpdates) as? Bool ?? true, canInstall {
                install(found, now: asked)
            }
        }
    }

    /// Downloads and checks the update, then swaps it in and restarts: at once when
    /// `now`, otherwise as soon as you're not using Headroom.
    func install(_ release: Release, now: Bool) {
        guard !installing, canInstall, let download = release.download, let requirement = Self.requirement else { return }
        installing = true
        lastResult = "Downloading Headroom \(release.version)…"
        Task {
            do {
                let (zip, response) = try await URLSession.shared.download(from: download)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Failure("the download didn't arrive") }
                let app = try await Task.detached {
                    try Self.unpack(zip, version: release.version, requirement: requirement)
                }.value
                if now || !(NSApp.isActive && NSApp.keyWindow != nil) {
                    swapIn(app)
                } else {
                    // The popover or Settings is open: restart once you click away.
                    lastResult = "Headroom \(release.version) installs when you click away."
                    waiting = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification,
                                                                     object: nil, queue: .main) { _ in
                        Task { @MainActor in Updater.shared.swapIn(app) }
                    }
                }
            } catch {
                installing = false
                lastResult = "Couldn't install the update: \((error as? Failure)?.reason ?? error.localizedDescription)."
            }
        }
    }

    /// Unzips the download next to this copy (same disk, so the swap is a rename) and
    /// makes sure it's Headroom, intact, from the same developer, and the version expected.
    nonisolated private static func unpack(_ zip: URL, version: String, requirement: SecRequirement) throws -> URL {
        let files = FileManager.default
        defer { try? files.removeItem(at: zip) }
        let work = try files.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                 appropriateFor: Bundle.main.bundleURL, create: true)
        let app = work.appendingPathComponent("Headroom.app")
        do {
            let ditto = Process()
            ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            ditto.arguments = ["-x", "-k", zip.path, work.path]
            try ditto.run()
            ditto.waitUntilExit()
            guard ditto.terminationStatus == 0, files.fileExists(atPath: app.path) else {
                throw Failure("the download wasn't a Headroom app")
            }
            var code: SecStaticCode?
            let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)
            guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code,
                  SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess else {
                throw Failure("the download isn't signed by Headroom's developer")
            }
            let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
            guard info?["CFBundleShortVersionString"] as? String == version else {
                throw Failure("the download is a different version")
            }
            return app
        } catch {
            try? files.removeItem(at: work)
            throw error
        }
    }

    /// Puts the checked app where this one is, then quits; a small script opens the
    /// new copy once this one has gone, and clears away the old.
    private func swapIn(_ app: URL) {
        if let waiting { NotificationCenter.default.removeObserver(waiting) }
        waiting = nil
        let files = FileManager.default, target = Bundle.main.bundleURL
        let work = app.deletingLastPathComponent(), old = work.appendingPathComponent("Previous.app")
        do {
            try files.moveItem(at: target, to: old)
            do { try files.moveItem(at: app, to: target) } catch {
                try? files.moveItem(at: old, to: target)
                throw error
            }
        } catch {
            // Only once the old copy is back in place.
            if files.fileExists(atPath: target.path) { try? files.removeItem(at: work) }
            installing = false
            lastResult = "Couldn't install the update: \(error.localizedDescription)"
            return
        }
        let lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
        let script = """
            while /bin/kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do /bin/sleep 0.2; done
            \(lsregister) -f "$0"; /usr/bin/open "$0"; /bin/rm -rf "$1"
            """
        let relaunch = Process()
        relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
        relaunch.arguments = ["-c", script, target.path, work.path]
        try? relaunch.run()
        NSApp.terminate(nil)
    }

    private struct Failure: Error {
        let reason: String
        init(_ reason: String) { self.reason = reason }
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
