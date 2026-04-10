import Cocoa
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    private let displayMonitor = DisplayMonitor.shared
    private let obsManager = OBSWebSocketManager.shared
    private let configStore = ConfigStore.shared

    // Menu items that need to be updated live.
    private var obsStatusMenuItem: NSMenuItem!
    private var sceneMenuItem: NSMenuItem!
    private var displayCountMenuItem: NSMenuItem!
    private var lastTriggerMenuItem: NSMenuItem!
    private var recordingStatusMenuItem: NSMenuItem!

    /// Tokens for the closure-based NotificationCenter observers so we can
    /// remove exactly the registrations we added (and only those).
    private var notificationObservers: [NSObjectProtocol] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenuBar()
        // Ask for banner permission up-front so the first trigger fire has a
        // decided answer. Users who deny keep full functionality without
        // banners.
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
            center.addObserver(forName: .displayUnplugTriggerFired, object: nil, queue: .main) { [weak self] note in
                self?.displayUnplugTriggerFired(note)
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

        // Refresh menu state once up-front.
        refreshMenuState()

        // If the user has never configured OBS, open the settings window on
        // first launch so they know what to do. This is the only "first-run
        // experience" — no onboarding flow, just pop the settings.
        if !configStore.config.hasBeenConfigured {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.openSettings()
            }
        }
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

    // MARK: - Menu bar

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            // "rectangle.on.rectangle" reads cleaner in the menu bar than
            // "display.2" at 16pt — it's closer to a "scene switcher" mark.
            let image = NSImage(systemSymbolName: "rectangle.on.rectangle",
                                accessibilityDescription: "OBScene")
            image?.isTemplate = true
            button.image = image
        }

        let menu = NSMenu()
        menu.autoenablesItems = false

        // Section: status
        let header = NSMenuItem(title: "OBScene", action: nil, keyEquivalent: "")
        header.isEnabled = false
        header.attributedTitle = NSAttributedString(
            string: "OBScene",
            attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .bold)]
        )
        menu.addItem(header)

        obsStatusMenuItem = NSMenuItem(title: "OBS: Disconnected", action: nil, keyEquivalent: "")
        obsStatusMenuItem.isEnabled = false
        menu.addItem(obsStatusMenuItem)

        sceneMenuItem = NSMenuItem(title: "Scene: —", action: nil, keyEquivalent: "")
        sceneMenuItem.isEnabled = false
        menu.addItem(sceneMenuItem)

        displayCountMenuItem = NSMenuItem(title: "Displays: 0 / 2 external", action: nil, keyEquivalent: "")
        displayCountMenuItem.isEnabled = false
        menu.addItem(displayCountMenuItem)

        recordingStatusMenuItem = NSMenuItem(title: "Recording on connect: Off", action: nil, keyEquivalent: "")
        recordingStatusMenuItem.isEnabled = false
        menu.addItem(recordingStatusMenuItem)

        lastTriggerMenuItem = NSMenuItem(title: "Last trigger: Never", action: nil, keyEquivalent: "")
        lastTriggerMenuItem.isEnabled = false
        menu.addItem(lastTriggerMenuItem)

        menu.addItem(NSMenuItem.separator())

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let reconnectItem = NSMenuItem(title: "Reconnect to OBS", action: #selector(reconnectOBS), keyEquivalent: "r")
        reconnectItem.target = self
        menu.addItem(reconnectItem)

        menu.addItem(NSMenuItem.separator())

        let aboutItem = NSMenuItem(title: "About OBScene", action: #selector(showAbout), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)

        let githubItem = NSMenuItem(title: "OBScene on GitHub", action: #selector(openGitHub), keyEquivalent: "")
        githubItem.target = self
        menu.addItem(githubItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quit OBScene", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)

        menu.delegate = self
        statusItem.menu = menu
    }

    /// Recompute all of the live status menu items from current singletons.
    private func refreshMenuState() {
        let config = configStore.config
        let connected = obsManager.isConnected

        // OBS connection + scene
        if connected {
            obsStatusMenuItem.title = "OBS: Connected"
            if !obsManager.currentScene.isEmpty {
                sceneMenuItem.title = "Scene: \(obsManager.currentScene)"
            } else {
                sceneMenuItem.title = "Scene: —"
            }
        } else if let error = obsManager.connectionError, !error.isEmpty {
            obsStatusMenuItem.title = "OBS: \(truncate(error, limit: 50))"
            sceneMenuItem.title = "Scene: —"
        } else {
            obsStatusMenuItem.title = "OBS: Disconnected"
            sceneMenuItem.title = "Scene: —"
        }

        // External display status, shown as current / required.
        let current = displayMonitor.externalDisplayCount
        let required = config.requiredExternalDisplays
        let noun = required == 1 ? "display" : "displays"
        if current >= required {
            displayCountMenuItem.title = "Displays: \(current) / \(required) external (ready)"
        } else {
            displayCountMenuItem.title = "Displays: \(current) / \(required) external \(noun) (waiting)"
        }

        // Trigger-actions summary so users can see what'll happen at a glance.
        var actions: [String] = []
        if config.startRecording { actions.append("Record") }
        if config.startStreaming { actions.append("Stream") }
        if actions.isEmpty {
            recordingStatusMenuItem.title = "Trigger actions: scene switch only"
        } else {
            recordingStatusMenuItem.title = "Trigger actions: \(actions.joined(separator: " + "))"
        }

        // Status-item symbol reflects connection state.
        if let button = statusItem.button {
            let symbolName: String
            if connected && current >= required {
                symbolName = "rectangle.on.rectangle.circle.fill"
            } else if connected {
                symbolName = "rectangle.on.rectangle"
            } else {
                symbolName = "rectangle.on.rectangle.slash"
            }
            let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "OBScene")
            image?.isTemplate = true
            button.image = image
        }
    }

    private func truncate(_ s: String, limit: Int) -> String {
        if s.count <= limit { return s }
        return String(s.prefix(limit - 1)) + "…"
    }

    // MARK: - Menu actions

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
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 640),
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

    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)

        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"

        // Build a small credits string with a clickable GitHub link.
        let credits = NSMutableAttributedString()
        credits.append(NSAttributedString(
            string: "Automates OBS recording & streaming when external displays connect.\n\n",
            attributes: [.font: NSFont.systemFont(ofSize: 11)]
        ))
        let linkAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .link: URL(string: "https://github.com/EthanSK/OBScene")!,
            .foregroundColor: NSColor.linkColor
        ]
        credits.append(NSAttributedString(
            string: "github.com/EthanSK/OBScene",
            attributes: linkAttrs
        ))

        let options: [NSApplication.AboutPanelOptionKey: Any] = [
            .applicationName: "OBScene",
            .applicationVersion: version,
            .version: "Build \(build)",
            .credits: credits,
            .init(rawValue: "Copyright"): "Copyright © 2024 Ethan SK. MIT License."
        ]

        NSApp.orderFrontStandardAboutPanel(options: options)
    }

    @objc private func openGitHub() {
        if let url = URL(string: "https://github.com/EthanSK/OBScene") {
            NSWorkspace.shared.open(url)
        }
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

    // MARK: - Notification observers

    @objc private func displayTriggerFired(_ notification: Notification) {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .medium
        let timeString = formatter.string(from: Date())

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.lastTriggerMenuItem.title = "Last trigger: \(timeString)"
            self.refreshMenuState()

            // Build a human summary of what actually happened so the banner
            // is useful, not just "Trigger fired".
            let config = self.configStore.config
            var parts: [String] = []
            if !config.selectedSceneCollection.isEmpty {
                parts.append("Collection → \(config.selectedSceneCollection)")
            }
            if !config.selectedProfile.isEmpty {
                parts.append("Profile → \(config.selectedProfile)")
            }
            if !config.selectedScene.isEmpty {
                parts.append("Scene → \(config.selectedScene)")
            }
            if config.startRecording { parts.append("Started recording") }
            if config.startStreaming { parts.append("Started streaming") }
            let body = parts.isEmpty ? "Displays reached target count." : parts.joined(separator: "\n")

            UserNotifier.post(
                title: "OBScene trigger fired",
                body: body
            )
        }
    }

    @objc private func displayUnplugTriggerFired(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let config = self.configStore.config
            var parts: [String] = []
            if config.stopRecordingOnUnplug { parts.append("Stopped recording") }
            if config.stopStreamingOnUnplug { parts.append("Stopped streaming") }
            let body = parts.isEmpty ? "Displays disconnected." : parts.joined(separator: "\n")
            UserNotifier.post(
                title: "OBScene: displays unplugged",
                body: body
            )
            self.refreshMenuState()
        }
    }

    @objc private func obsConnectionChanged() {
        DispatchQueue.main.async { [weak self] in
            self?.refreshMenuState()
        }
    }

    @objc private func displayCountChanged(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            self?.refreshMenuState()
        }
    }
}

extension AppDelegate: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        settingsWindow = nil
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        // Pull the freshest state every time the menu drops down — cheap,
        // keeps scene/collection labels in sync with reality without needing
        // @Published subscriptions from AppKit land.
        refreshMenuState()
    }
}
