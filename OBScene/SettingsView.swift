import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @EnvironmentObject var configStore: ConfigStore
    @EnvironmentObject var obsManager: OBSWebSocketManager
    @ObservedObject private var activityLog = ActivityLog.shared

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

                        HStack {
                            Spacer()
                            Button("Test Action") {
                                DisplayMonitor.shared.executeTrigger()
                            }
                            .disabled(!obsManager.isConnected)
                        }
                    }
                    .padding(.vertical, 4)
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
