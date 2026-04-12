import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @EnvironmentObject var configStore: ConfigStore
    @EnvironmentObject var obsManager: OBSWebSocketManager
    @ObservedObject private var activityLog = ActivityLog.shared
    @ObservedObject private var updater = UpdaterManager.shared

    @State private var obsHost: String = ""
    @State private var obsPort: String = ""
    @State private var obsPassword: String = ""
    @State private var isConnecting = false

    @State private var launchAtLogin: Bool = ProcessInfo.processInfo.environment["OBSCENE_RENDER_SETTINGS"] != nil
    @State private var launchAtLoginError: String? = nil

    var body: some View {
        // ViewThatFits collapses to the single-column layout when the window
        // is too narrow for the side-by-side variant. Users on small displays
        // can shrink the window all the way down without breaking the layout.
        ViewThatFits(in: .horizontal) {
            twoColumnLayout
            singleColumnLayout
        }
        .frame(minWidth: 560, minHeight: 400)
        .onAppear {
            obsHost = configStore.config.obsHost
            obsPort = String(configStore.config.obsPort)
            obsPassword = configStore.config.obsPassword
            if ProcessInfo.processInfo.environment["OBSCENE_RENDER_SETTINGS"] == nil {
                refreshLaunchAtLoginStatus()
            }
        }
    }

    /// Wide layout: operational settings on the left (fixed — fits without
    /// scrolling at the default 980x660 window size), secondary/meta settings
    /// (Updates, General, Testing) stacked in the right column above a
    /// scrollable Activity log. Only the Activity panel scrolls.
    private var twoColumnLayout: some View {
        HStack(alignment: .top, spacing: 0) {
            leftColumn
                .frame(minWidth: 440, idealWidth: 560, maxWidth: .infinity)

            Divider()

            rightColumn
                .frame(minWidth: 300, idealWidth: 360, maxWidth: 420)
        }
        .frame(minWidth: 760)
    }

    /// Left column: the four "primary" operational settings groups. Plain
    /// VStack — no ScrollView — so it must fit at the default window height.
    private var leftColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            // First-run / welcome banner. Shown until the user has saved a
            // working configuration once — after that it disappears so the
            // window isn't cluttered on repeat visits.
            if !configStore.config.hasBeenConfigured {
                welcomeBanner
            }

            obsConnectionGroup
            displayTriggerGroup
            obsConfigurationGroup
            triggerActionsGroup

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    /// Right column: Updates, General, Testing pinned at the top; Activity
    /// log scrolls in the remaining space. Only the Activity panel scrolls.
    private var rightColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            updatesGroup
            generalGroup
            testingGroup

            // Activity takes whatever vertical space remains and is the only
            // element in the window that scrolls independently.
            ScrollView(.vertical, showsIndicators: true) {
                activitySection
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(maxHeight: .infinity)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    /// Narrow fallback: everything stacked vertically in a single scroll view.
    /// Used when the window is shrunk below ~760pt of width.
    private var singleColumnLayout: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 12) {
                if !configStore.config.hasBeenConfigured {
                    welcomeBanner
                }

                updatesGroup
                generalGroup
                obsConnectionGroup
                displayTriggerGroup
                obsConfigurationGroup
                triggerActionsGroup
                testingGroup
                activitySection
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    // MARK: - Section views

    private var updatesGroup: some View {
        GroupBox(label: Label("Updates", systemImage: "arrow.down.circle")) {
            updatesSection
                .padding(.vertical, 2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var generalGroup: some View {
        GroupBox(label: Label("General", systemImage: "gearshape")) {
            VStack(alignment: .leading, spacing: 6) {
                Toggle("Launch at Login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { newValue in
                        setLaunchAtLogin(newValue)
                    }
                if let error = launchAtLoginError {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                } else {
                    Text("Automatically start OBScene when you log in.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Divider().padding(.vertical, 1)

                Toggle("Auto-launch OBS if not running",
                       isOn: $configStore.config.autoLaunchOBS)
                Text("When a trigger fires and OBS isn't running, OBScene will start OBS Studio and wait for its WebSocket.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack {
                    Text("Wait up to")
                    Stepper(value: $configStore.config.obsLaunchTimeoutSeconds,
                            in: 5...120, step: 5) {
                        Text("\(configStore.config.obsLaunchTimeoutSeconds)s")
                            .monospacedDigit()
                    }
                    Spacer(minLength: 0)
                }
                .disabled(!configStore.config.autoLaunchOBS)
            }
            .padding(.vertical, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var obsConnectionGroup: some View {
        GroupBox(label: Label("OBS WebSocket Connection", systemImage: "network")) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Host:")
                        .frame(width: 80, alignment: .trailing)
                    TextField("localhost", text: $obsHost)
                        .textFieldStyle(.roundedBorder)
                }
                HStack {
                    Text("Port:")
                        .frame(width: 80, alignment: .trailing)
                    TextField("4455", text: $obsPort)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 100)
                    Spacer()
                }
                HStack {
                    Text("Password:")
                        .frame(width: 80, alignment: .trailing)
                    SecureField("Optional", text: $obsPassword)
                        .textFieldStyle(.roundedBorder)
                }

                HStack {
                    connectionStatusView
                    Spacer()
                    Button(action: connectToOBS) {
                        Text(obsManager.isConnected ? "Reconnect" : "Connect")
                    }
                    .disabled(isConnecting)
                }
            }
            .padding(.vertical, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var displayTriggerGroup: some View {
        GroupBox(label: Label("Display Trigger", systemImage: "display.2")) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Trigger when external displays reach:")
                    Picker("", selection: $configStore.config.requiredExternalDisplays) {
                        ForEach(1...8, id: \.self) { count in
                            Text("\(count)").tag(count)
                        }
                    }
                    .frame(width: 60)
                    Spacer()
                }

                HStack {
                    Text("Delay before triggering:")
                    TextField("15", value: $configStore.config.triggerDelay, formatter: NumberFormatter())
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 60)
                    Text("seconds")
                    Spacer()
                }

                HStack {
                    Text("Current external displays:")
                        .foregroundColor(.secondary)
                    Text("\(DisplayMonitor.shared.externalDisplayCount)")
                        .fontWeight(.medium)
                    Spacer()
                }
            }
            .padding(.vertical, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var obsConfigurationGroup: some View {
        GroupBox(label: Label("OBS Configuration", systemImage: "film")) {
            VStack(alignment: .leading, spacing: 8) {
                if !obsManager.isConnected {
                    Text("Connect to OBS to configure scenes and profiles.")
                        .foregroundColor(.secondary)
                        .italic()
                } else {
                    HStack {
                        Text("Scene Collection:")
                            .frame(width: 120, alignment: .trailing)
                        Picker("", selection: $configStore.config.selectedSceneCollection) {
                            Text("(Don't change)").tag("")
                            ForEach(obsManager.sceneCollections, id: \.self) { collection in
                                Text(collection).tag(collection)
                            }
                        }
                    }

                    HStack {
                        Text("Profile:")
                            .frame(width: 120, alignment: .trailing)
                        Picker("", selection: $configStore.config.selectedProfile) {
                            Text("(Don't change)").tag("")
                            ForEach(obsManager.profiles, id: \.self) { profile in
                                Text(profile).tag(profile)
                            }
                        }
                    }

                    HStack {
                        Text("Scene:")
                            .frame(width: 120, alignment: .trailing)
                        Picker("", selection: $configStore.config.selectedScene) {
                            Text("(Don't change)").tag("")
                            ForEach(obsManager.scenes, id: \.self) { scene in
                                Text(scene).tag(scene)
                            }
                        }
                    }

                    HStack {
                        Spacer()
                        Button("Refresh") {
                            obsManager.fetchSceneCollections()
                            obsManager.fetchProfiles()
                            obsManager.fetchScenes()
                        }
                    }
                }
            }
            .padding(.vertical, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var triggerActionsGroup: some View {
        GroupBox(label: Label("Trigger Actions", systemImage: "bolt.fill")) {
            VStack(alignment: .leading, spacing: 4) {
                VStack(alignment: .leading, spacing: 2) {
                    Toggle("Start Recording", isOn: $configStore.config.startRecording)
                    Toggle("Also stop recording when displays are unplugged",
                           isOn: $configStore.config.stopRecordingOnUnplug)
                        .disabled(!configStore.config.startRecording)
                        .padding(.leading, 20)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Toggle("Start Streaming", isOn: $configStore.config.startStreaming)
                    Toggle("Also stop streaming when displays are unplugged",
                           isOn: $configStore.config.stopStreamingOnUnplug)
                        .disabled(!configStore.config.startStreaming)
                        .padding(.leading, 20)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Toggle("Start Virtual Camera", isOn: $configStore.config.startVirtualCam)
                    Toggle("Also stop virtual camera when displays are unplugged",
                           isOn: $configStore.config.stopVirtualCamOnUnplug)
                        .disabled(!configStore.config.startVirtualCam)
                        .padding(.leading, 20)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Toggle("Start Replay Buffer", isOn: $configStore.config.startReplayBuffer)
                    Toggle("Also stop replay buffer when displays are unplugged",
                           isOn: $configStore.config.stopReplayBufferOnUnplug)
                        .disabled(!configStore.config.startReplayBuffer)
                        .padding(.leading, 20)
                }

                Divider().padding(.vertical, 1)

                VStack(alignment: .leading, spacing: 2) {
                    Toggle("Refresh all browsers", isOn: $configStore.config.refreshBrowsersOnTrigger)
                    Text("Reloads all tabs in Chrome, Safari, Arc, and Firefox")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Toggle("Refresh OBS browser sources", isOn: $configStore.config.refreshOBSBrowserSourcesOnTrigger)
                    Text("Reloads all browser sources in OBS (chat overlays, widgets, etc.)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.vertical, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var testingGroup: some View {
        GroupBox(label: Label("Testing", systemImage: "play.circle")) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Dry-run the full trigger as if an external display had just been plugged in — the configured delay is skipped.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack {
                    Spacer()
                    Button("Simulate Display Connection") {
                        DisplayMonitor.shared.runTestTrigger()
                    }
                }
            }
            .padding(.vertical, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Activity log — lives in the right column in the wide layout, and falls
    /// back to the bottom of the single column when collapsed. Shows up to 12
    /// recent events; the column itself is wrapped in a ScrollView upstream.
    private var activitySection: some View {
        GroupBox(label: Label("Activity", systemImage: "clock.arrow.circlepath")) {
            VStack(alignment: .leading, spacing: 8) {
                if activityLog.events.isEmpty {
                    Text("No activity yet. Connect a display or run a test action.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .italic()
                        .padding(.vertical, 4)
                } else {
                    ForEach(activityLog.events.prefix(12)) { event in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: event.kind.symbol)
                                .foregroundColor(.accentColor)
                                .frame(width: 16)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(event.message)
                                    .font(.caption)
                                    .fixedSize(horizontal: false, vertical: true)
                                Text(Self.activityFormatter.string(from: event.timestamp))
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                    .monospacedDigit()
                            }
                            Spacer(minLength: 0)
                        }
                    }
                }
            }
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private static let activityFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .medium
        return f
    }()

    private func refreshLaunchAtLoginStatus() {
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        let service = SMAppService.mainApp
        let currentlyEnabled = service.status == .enabled
        guard enabled != currentlyEnabled else { return }

        do {
            if enabled {
                try service.register()
            } else {
                try service.unregister()
            }
            launchAtLoginError = nil
            // Status may not flip immediately when the user has to approve in
            // System Settings, so reflect the actual status rather than intent.
            DispatchQueue.main.async {
                let actual = SMAppService.mainApp.status == .enabled
                if actual != enabled {
                    launchAtLogin = actual
                    if enabled && SMAppService.mainApp.status == .requiresApproval {
                        launchAtLoginError = "Approve OBScene in System Settings > General > Login Items."
                    }
                }
            }
        } catch {
            launchAtLoginError = "Failed to update: \(error.localizedDescription)"
            // Revert toggle to reflect actual status.
            DispatchQueue.main.async {
                launchAtLogin = SMAppService.mainApp.status == .enabled
            }
        }
    }

    private var updatesSection: some View {
        // Pull the bundle's short version string — this matches the value
        // Sparkle compares against the appcast and the one shown on the
        // landing page / GitHub release page.
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        // feedURL removed from UI — not useful to end users

        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("OBScene v\(version)")
                    .font(.callout)
                    .fontWeight(.medium)
                Spacer()
                Text(formattedLastCheck)
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            // Inline status line — mirrors Sparkle's internal state in the
            // Settings UI so the user can see "up to date" / "update
            // available: vX.Y" at a glance without digging through a modal.
            updateStatusLine
                .font(.caption)
                .animation(.easeInOut(duration: 0.18), value: updater.isChecking)
                .animation(.easeInOut(duration: 0.18), value: updater.lastCheckResult)

            // Recheck queries the appcast. If an update is found, the
            // UpdaterManager immediately hands off to Sparkle's standard
            // download+install dialog. The "Install & Restart" button is
            // really just a way to re-open Sparkle's dialog if the user
            // dismissed it mid-download.
            HStack(spacing: 8) {
                Button {
                    UpdaterManager.shared.recheck()
                } label: {
                    Text("Recheck")
                }
                .disabled(updater.isChecking)

                Button {
                    UpdaterManager.shared.installPendingUpdate()
                } label: {
                    Text("Install & Restart")
                }
                .disabled(updater.pendingUpdate == nil)

                Spacer()
            }
            .animation(.easeInOut(duration: 0.18), value: updater.pendingUpdate != nil)

            Divider().padding(.vertical, 1)

            // Binding<Bool> wrappers onto the UpdaterManager properties so
            // SwiftUI drives Sparkle directly without us caching state here.
            Toggle("Automatically check for updates", isOn: Binding(
                get: { updater.automaticallyChecksForUpdates },
                set: { updater.automaticallyChecksForUpdates = $0 }
            ))
            Toggle("Automatically download and install", isOn: Binding(
                get: { updater.automaticallyDownloadsUpdates },
                set: { updater.automaticallyDownloadsUpdates = $0 }
            ))
            .disabled(!updater.automaticallyChecksForUpdates)

            // Feed URL removed — not useful to end users
        }
    }

    @ViewBuilder
    private var updateStatusLine: some View {
        if updater.isChecking {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.7)
                    .frame(width: 12, height: 12)
                Text("Checking for updates…")
                    .foregroundColor(.secondary)
            }
        } else if let result = updater.lastCheckResult {
            switch result {
            case .upToDate(let currentVersion):
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Text("You're up to date on v\(currentVersion).")
                        .foregroundColor(.secondary)
                }
            case .updateAvailable(let currentVersion, let latestVersion, let releaseNotesURL):
                HStack(spacing: 6) {
                    Image(systemName: "arrow.down.circle.fill")
                        .foregroundColor(.accentColor)
                    Text("Update available: v\(latestVersion) (you're on v\(currentVersion)).")
                        .foregroundColor(.primary)
                    if let url = releaseNotesURL {
                        Link("Release notes", destination: url)
                            .font(.caption)
                    }
                }
            case .failed(let error):
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.red)
                    Text("Check failed: \(error)")
                        .foregroundColor(.red)
                        .lineLimit(2)
                        .truncationMode(.tail)
                }
            }
        } else {
            HStack(spacing: 6) {
                Image(systemName: "circle.dashed")
                    .foregroundColor(.secondary)
                Text("Press Recheck to query the update feed.")
                    .foregroundColor(.secondary)
            }
        }
    }

    private var formattedLastCheck: String {
        // Screenshot-render subprocess never boots Sparkle, so surface a
        // plausible placeholder instead of "Never" — otherwise the captured
        // PNG shows an empty "Last check" row which looks broken.
        if ProcessInfo.processInfo.environment["OBSCENE_RENDER_SETTINGS"] != nil {
            return "Today, checked in the background"
        }
        guard let date = updater.lastUpdateCheckDate else {
            return "Never"
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private var welcomeBanner: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "sparkles")
                .font(.system(size: 22, weight: .semibold))
                .foregroundColor(.accentColor)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text("Welcome to OBScene")
                    .font(.headline)
                Text("Connect to OBS below, choose the scene/profile to switch to, and pick the trigger actions. When your external displays come online, OBScene will switch OBS and (optionally) start recording or streaming automatically.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Tip: in OBS, enable Tools → WebSocket Server Settings, then paste the password below.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.accentColor.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(0.28), lineWidth: 1)
        )
    }

    private var connectionStatusView: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(obsManager.isConnected ? Color.green : (obsManager.connectionError != nil ? Color.orange : Color.red))
                .frame(width: 8, height: 8)
            if let error = obsManager.connectionError, !error.isEmpty {
                // Show the error inline but truncated — the window can be
                // narrow, and the full error is in the log anyway.
                Text("Error: \(error)")
                    .font(.caption)
                    .foregroundColor(.red)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .help(error)
            } else if obsManager.isConnected {
                Text("Connected")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                Text("Disconnected")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    private func connectToOBS() {
        let port = Int(obsPort) ?? 4455

        configStore.config.obsHost = obsHost
        configStore.config.obsPort = port
        configStore.config.obsPassword = obsPassword
        configStore.config.hasBeenConfigured = true

        isConnecting = true

        obsManager.connect(host: obsHost, port: port, password: obsPassword)

        // Reset connecting state after a moment
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            isConnecting = false
        }
    }
}
