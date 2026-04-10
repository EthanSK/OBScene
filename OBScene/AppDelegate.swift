import Cocoa
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    private let displayMonitor = DisplayMonitor.shared
    private let obsManager = OBSWebSocketManager.shared
    private let configStore = ConfigStore.shared
    private var statusMenuItem: NSMenuItem!
    private var lastTriggerMenuItem: NSMenuItem!
    private var displayCountMenuItem: NSMenuItem!

    /// Tokens for the closure-based NotificationCenter observers so we can
    /// remove exactly the registrations we added (and only those).
    private var notificationObservers: [NSObjectProtocol] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenuBar()
        UserNotifier.requestPermission()
        displayMonitor.startMonitoring()
        connectToOBSIfConfigured()

        let center = NotificationCenter.default

        notificationObservers.append(
            center.addObserver(forName: .displayTriggerFired, object: nil, queue: .main) { [weak self] note in
                self?.displayTriggerFired(note)
            }
        )

        notificationObservers.append(
            center.addObserver(forName: .obsConnectionChanged, object: nil, queue: .main) { [weak self] _ in
                self?.obsConnectionChanged()
            }
        )

        notificationObservers.append(
            center.addObserver(forName: .externalDisplayCountChanged, object: nil, queue: .main) { [weak self] note in
                self?.displayCountChanged(note)
            }
        )
    }

    deinit {
        let center = NotificationCenter.default
        for token in notificationObservers {
            center.removeObserver(token)
        }
        notificationObservers.removeAll()
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Tidy up shared singletons so we don't leave a CG callback registered
        // or a WebSocket loop spinning if the process lingers (e.g. while
        // crash reporters or system services hold us alive briefly).
        displayMonitor.stopMonitoring()
        obsManager.disconnect()

        let center = NotificationCenter.default
        for token in notificationObservers {
            center.removeObserver(token)
        }
        notificationObservers.removeAll()
    }

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "display.2", accessibilityDescription: "OBScene")
            image?.isTemplate = true
            button.image = image
        }

        let menu = NSMenu()

        statusMenuItem = NSMenuItem(title: "OBS: Disconnected", action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)

        displayCountMenuItem = NSMenuItem(
            title: "External Displays: \(displayMonitor.externalDisplayCount)",
            action: nil,
            keyEquivalent: ""
        )
        displayCountMenuItem.isEnabled = false
        menu.addItem(displayCountMenuItem)

        lastTriggerMenuItem = NSMenuItem(title: "Last Trigger: Never", action: nil, keyEquivalent: "")
        lastTriggerMenuItem.isEnabled = false
        menu.addItem(lastTriggerMenuItem)

        menu.addItem(NSMenuItem.separator())

        let settingsItem = NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let reconnectItem = NSMenuItem(title: "Reconnect to OBS", action: #selector(reconnectOBS), keyEquivalent: "r")
        reconnectItem.target = self
        menu.addItem(reconnectItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quit OBScene", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    @objc private func openSettings() {
        if let window = settingsWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let settingsView = SettingsView()
            .environmentObject(configStore)
            .environmentObject(obsManager)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "OBScene Settings"
        window.contentView = NSHostingView(rootView: settingsView)
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        window.delegate = self

        NSApp.activate(ignoringOtherApps: true)

        settingsWindow = window
    }

    @objc private func reconnectOBS() {
        connectToOBSIfConfigured()
    }

    private func connectToOBSIfConfigured() {
        let config = configStore.config
        guard config.hasBeenConfigured, !config.obsHost.isEmpty else { return }
        obsManager.connect(
            host: config.obsHost,
            port: config.obsPort,
            password: config.obsPassword
        )
    }

    @objc private func displayTriggerFired(_ notification: Notification) {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .medium
        let timeString = formatter.string(from: Date())

        DispatchQueue.main.async { [weak self] in
            self?.lastTriggerMenuItem.title = "Last Trigger: \(timeString)"
        }
    }

    @objc private func obsConnectionChanged() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let connected = self.obsManager.isConnected
            self.statusMenuItem.title = connected ? "OBS: Connected" : "OBS: Disconnected"

            if let button = self.statusItem.button {
                let symbolName = connected ? "display.2" : "display.trianglebadge.exclamationmark"
                let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "OBScene")
                image?.isTemplate = true
                button.image = image
            }
        }
    }

    @objc private func displayCountChanged(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.displayCountMenuItem.title = "External Displays: \(self.displayMonitor.externalDisplayCount)"
        }
    }
}

extension AppDelegate: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        settingsWindow = nil
    }
}
