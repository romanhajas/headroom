// Settings.swift - the Settings window: menu bar, how often to check, start at login.

import AppKit
import ServiceManagement
import SwiftUI

/// One Settings window, opened from the popover or by opening Headroom again.
@MainActor
enum SettingsWindow {
    private static var window: NSWindow?

    static func show() {
        if window == nil {
            // A fixed size: letting SwiftUI and AppKit size the window for each other
            // can loop until AppKit gives up and stops the app.
            let hosting = NSHostingController(rootView: SettingsView().environmentObject(Monitor.shared))
            hosting.sizingOptions = []
            let w = NSWindow(contentViewController: hosting)
            w.title = "Headroom Settings"
            w.styleMask = [.titled, .closable]
            w.setContentSize(NSSize(width: 460, height: 640))
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct SettingsView: View {
    @EnvironmentObject private var monitor: Monitor
    @AppStorage(Prefs.showInMenuBar) private var showInMenuBar = true
    @AppStorage(Prefs.menuBarText) private var menuBarText = MenuBarText.percent.rawValue
    @AppStorage(Prefs.refreshMinutes) private var refreshMinutes = 3
    @AppStorage(Prefs.animations) private var animations = true
    @AppStorage(Prefs.notifySession) private var notifySession = true
    @AppStorage(Prefs.notifyPace) private var notifyPace = true
    @AppStorage(Prefs.notifyWeek) private var notifyWeek = true
    @AppStorage(Prefs.checkUpdates) private var checkUpdates = true
    @ObservedObject private var updater = Updater.shared
    @State private var opensAtLogin = SMAppService.mainApp.status == .enabled

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    var body: some View {
        Form {
            Section("Menu bar") {
                Toggle("Show Headroom in the menu bar", isOn: $showInMenuBar)
                Picker("Next to the icon", selection: $menuBarText) {
                    ForEach(MenuBarText.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
                }
                .disabled(!showInMenuBar)
                Toggle(isOn: $animations) {
                    Text("Animations")
                    Text("The ring and bars sweep in when the menu opens, and your badge, if you've added one, comes alive. Also off while Reduce Motion is on in macOS.")
                }
                .disabled(!showInMenuBar)
                if !showInMenuBar {
                    Text("Headroom keeps running for the widget. To get back here, open it again from Applications or Spotlight.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Notifications") {
                Toggle("Session at 80% and 95%, and when a heavy one resets", isOn: $notifySession)
                Toggle("When you'd hit a limit early at your current pace", isOn: $notifyPace)
                Toggle("Weekly limit at 80% and 95%", isOn: $notifyWeek)
            }
            Section("Checking usage") {
                Picker("Check every", selection: $refreshMinutes) {
                    ForEach([1, 3, 5, 10, 15], id: \.self) { Text($0 == 1 ? "1 minute" : "\($0) minutes").tag($0) }
                }
                .onChange(of: refreshMinutes) { _, _ in monitor.reschedule() }
                if refreshMinutes == 1 {
                    Text("Checking every minute asks the server more often. If it pushes back, Headroom waits a few minutes on its own.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Toggle("Open at login", isOn: $opensAtLogin)
                    .onChange(of: opensAtLogin) { _, on in
                        if on { try? SMAppService.mainApp.register() } else { try? SMAppService.mainApp.unregister() }
                        opensAtLogin = SMAppService.mainApp.status == .enabled
                    }
            }
            Section("Widget") {
                Text("Right-click the desktop, choose Edit Widgets, and search for Headroom. It comes in three sizes; click it to refresh.")
                    .foregroundStyle(.secondary)
            }
            Section("Headroom \(version)") {
                Toggle("Check for new versions once a day", isOn: $checkUpdates)
                HStack {
                    if let release = updater.available {
                        Link("Download Headroom \(release.version)", destination: release.page)
                    } else {
                        Text(updater.lastResult ?? "").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(updater.checking ? "Checking…" : "Check Now") { updater.check() }
                        .disabled(updater.checking)
                    Link("GitHub", destination: URL(string: "https://github.com/romanhajas/headroom")!)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 640)
    }
}
