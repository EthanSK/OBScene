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
        VStack(alignment: .leading, spacing: 12) {
                // First-run / welcome banner. Shown until the user has saved
                // a working configuration once — after that it disappears so
                // the window isn't cluttered on repeat visits.
                if !configStore.config.hasBeenConfigured {
                    welcomeBanner
                }

                // General
                GroupBox(label: Label("General", systemImage: "gearshape")) {
                    VStack(alignment: .leading, spacing: 8) {
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

                        Divider().padding(.vertical, 2)

                        Toggle("Auto-launch OBS if not running",
                               isOn: $configStore.config.autoLaunchOBS)
                        Text("When a trigger fires and OBS isn't running, OBScene will start OBS Studio and wait for its WebSocket server.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        HStack {
                            Text("Wait up to")
                            Stepper(value: $configStore.config.obsLaunchTimeoutSeconds,
                                    in: 5...120, step: 5) {
                                Text("\(configStore.config.obsLaunchTimeoutSeconds) seconds")
                                    .monospacedDigit()
                            }
                            Text("for OBS to be ready")
                                .foregroundColor(.secondary)
                        }
                        .disabled(!configStore.config.autoLaunchOBS)
                    }
                    .padding(.vertical, 4)
                }

                // OBS Connection
                GroupBox(label: Label("OBS WebSocket Connection", systemImage: "network")) {
                    VStack(alignment: .leading, spacing: 12) {
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
                        }
                        HStack {
                            Text("Password:")
                                .frame(width: 80, alignment: .trailing)
                            SecureField("Optional", text: $obsPassword)
                                .textFieldStyle(.roundedBorder)
                        }

                        HStack {
                            Spacer()
                            connectionStatusView
                            Button(action: connectToOBS) {
                                Text(obsManager.isConnected ? "Reconnect" : "Connect")
                            }
                            .disabled(isConnecting)
                        }
                    }
                    .padding(.vertical, 4)
                }

                // Display Trigger
                GroupBox(label: Label("Display Trigger", systemImage: "display.2")) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Trigger when external displays reach:")
                            Picker("", selection: $configStore.config.requiredExternalDisplays) {
                                ForEach(1...8, id: \.self) { count in
                                    Text("\(count)").tag(count)
                                }
                            }
                            .frame(width: 60)
                        }

                        HStack {
                            Text("Delay before triggering:")
                            TextField("15", value: $configStore.config.triggerDelay, formatter: NumberFormatter())
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 60)
                            Text("seconds")
                        }

                        HStack {
                            Text("Current external displays:")
                                .foregroundColor(.secondary)
                            Text("\(DisplayMonitor.shared.externalDisplayCount)")
                                .fontWeight(.medium)
                        }
                    }
                    .padding(.vertical, 4)
                }

                // OBS Scene Configuration
                GroupBox(label: Label("OBS Configuration", systemImage: "film")) {
                    VStack(alignment: .leading, spacing: 12) {
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
                    .padding(.vertical, 4)
                }

                // Actions
                GroupBox(label: Label("Trigger Actions", systemImage: "bolt.fill")) {
                    VStack(alignment: .leading, spacing: 6) {
                        VStack(alignment: .leading, spacing: 4) {
                            Toggle("Start Recording", isOn: $configStore.config.startRecording)
                            Toggle("Also stop recording when displays are unplugged",
                                   isOn: $configStore.config.stopRecordingOnUnplug)
                                .disabled(!configStore.config.startRecording)
                                .padding(.leading, 20)
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Toggle("Start Streaming", isOn: $configStore.config.startStreaming)
                            Toggle("Also stop streaming when displays are unplugged",
                                   isOn: $configStore.config.stopStreamingOnUnplug)
                                .disabled(!configStore.config.startStreaming)
                                .padding(.leading, 20)
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Toggle("Start Virtual Camera", isOn: $configStore.config.startVirtualCam)
                            Toggle("Also stop virtual camera when displays are unplugged",
                                   isOn: $configStore.config.stopVirtualCamOnUnplug)
                                .disabled(!configStore.config.startVirtualCam)
                                .padding(.leading, 20)
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Toggle("Start Replay Buffer", isOn: $configStore.config.startReplayBuffer)
                            Toggle("Also stop replay buffer when displays are unplugged",
                                   isOn: $configStore.config.stopReplayBufferOnUnplug)
                                .disabled(!configStore.config.startReplayBuffer)
                                .padding(.leading, 20)
                        }
                    }
                    .padding(.vertical, 4)
                }

                // Testing — standalone section so it's obvious the button
                // runs the entire trigger (scene collection + profile + scene
                // switch + all 4 start actions), not just one action from the
                // Trigger Actions box above.
                GroupBox(label: Label("Testing", systemImage: "play.circle")) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Dry-run the full trigger exactly as if an external display had just been plugged in. Switches scene collection, profile and scene, and runs every enabled start action. The configured trigger delay is skipped.")
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
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                // Updates — Sparkle auto-update controls. Placed between
                // Testing and Activity so it's visible without interrupting
                // the main trigger-configuration flow above.
                GroupBox(label: Label("Updates", systemImage: "arrow.down.circle")) {
                    updatesSection
                        .padding(.vertical, 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                // Activity
                GroupBox(label: Label("Activity", systemImage: "clock.arrow.circlepath")) {
                    VStack(alignment: .leading, spacing: 6) {
                        if activityLog.events.isEmpty {
                            Text("No activity yet. Connect a display or run a test action.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .italic()
                                .padding(.vertical, 4)
                        } else {
                            ForEach(activityLog.events.prefix(8)) { event in
                                HStack(spacing: 8) {
                                    Image(systemName: event.kind.symbol)
                                        .foregroundColor(.accentColor)
                                        .frame(width: 16)
                                    Text(event.message)
                                        .font(.caption)
                                    Spacer()
                                    Text(Self.activityFormatter.string(from: event.timestamp))
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                    }
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
        }
        .padding()
        .frame(minWidth: 680)
        .onAppear {
            obsHost = configStore.config.obsHost
            obsPort = String(configStore.config.obsPort)
            obsPassword = configStore.config.obsPassword
            if ProcessInfo.processInfo.environment["OBSCENE_RENDER_SETTINGS"] == nil {
                refreshLaunchAtLoginStatus()
            }
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
        let feedURLString = updater.feedURL?.absoluteString ?? "https://ethansk.github.io/OBScene/appcast.xml"

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("OBScene v\(version)")
                    .font(.callout)
                    .fontWeight(.medium)
                Spacer()
            }

            // Inline status line — mirrors Sparkle's internal state in the
            // Settings UI so the user can see "up to date" / "update
            // available: vX.Y" at a glance without digging through a modal.
            updateStatusLine
                .font(.caption)
                .animation(.easeInOut(duration: 0.18), value: updater.isChecking)
                .animation(.easeInOut(duration: 0.18), value: updater.lastCheckResult)

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("Last check:")
                    .foregroundColor(.secondary)
                Text(formattedLastCheck)
                    .monospacedDigit()
                    .foregroundColor(.secondary)
            }
            .font(.caption)

            // Split flow: Recheck queries the appcast silently, Download
            // and Install drives Sparkle's standard install dialog for the
            // pending update. Download is disabled until a recheck has
            // detected one — prevents clicking Download in an unknown
            // state and getting Sparkle's generic "up to date" modal.
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
                    Text("Download and Install")
                }
                .disabled(updater.pendingUpdate == nil)

                Spacer()
            }
            .animation(.easeInOut(duration: 0.18), value: updater.pendingUpdate != nil)

            Divider().padding(.vertical, 2)

            // Binding<Bool> wrappers onto the UpdaterManager properties so
            // SwiftUI drives Sparkle directly without us caching state here.
            Toggle("Automatically check for updates", isOn: Binding(
                get: { updater.automaticallyChecksForUpdates },
                set: { updater.automaticallyChecksForUpdates = $0 }
            ))
            Toggle("Automatically download and install updates", isOn: Binding(
                get: { updater.automaticallyDownloadsUpdates },
                set: { updater.automaticallyDownloadsUpdates = $0 }
            ))
            .disabled(!updater.automaticallyChecksForUpdates)

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("Feed:")
                    .foregroundColor(.secondary)
                Text(feedURLString)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            .font(.caption)

            Text("Use Recheck to query the feed without downloading. Download and Install becomes available once an update has been detected. The toggles below control background behaviour independently.")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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
