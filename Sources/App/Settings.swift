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
            w.setContentSize(NSSize(width: 460, height: 420))
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
                if !showInMenuBar {
                    Text("Headroom keeps running for the widget. To get back here, open it again from Applications or Spotlight.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Updates") {
                Picker("Check every", selection: $refreshMinutes) {
                    ForEach([3, 5, 10, 15], id: \.self) { Text("\($0) minutes").tag($0) }
                }
                .onChange(of: refreshMinutes) { _, _ in monitor.reschedule() }
                Toggle("Open at login", isOn: $opensAtLogin)
                    .onChange(of: opensAtLogin) { _, on in
                        if on { try? SMAppService.mainApp.register() } else { try? SMAppService.mainApp.unregister() }
                        opensAtLogin = SMAppService.mainApp.status == .enabled
                    }
            }
            Section("Widget") {
                Text("Right-click the desktop, choose Edit Widgets, and search for Headroom. Click the widget to refresh it.")
                    .foregroundStyle(.secondary)
            }
            Section {
                HStack {
                    Text("Headroom \(version)").foregroundStyle(.secondary)
                    Spacer()
                    Link("GitHub", destination: URL(string: "https://github.com/romanhajas/headroom")!)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 420)
    }
}
