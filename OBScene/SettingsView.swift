import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var configStore: ConfigStore
    @EnvironmentObject var obsManager: OBSWebSocketManager

    @State private var obsHost: String = ""
    @State private var obsPort: String = ""
    @State private var obsPassword: String = ""
    @State private var isConnecting = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
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
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Start Recording", isOn: $configStore.config.startRecording)
                        Toggle("Start Streaming", isOn: $configStore.config.startStreaming)
                    }
                    .padding(.vertical, 4)
                }

                Spacer()
            }
            .padding()
        }
        .frame(minWidth: 480, minHeight: 560)
        .onAppear {
            obsHost = configStore.config.obsHost
            obsPort = String(configStore.config.obsPort)
            obsPassword = configStore.config.obsPassword
        }
    }

    private var connectionStatusView: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(obsManager.isConnected ? Color.green : Color.red)
                .frame(width: 8, height: 8)
            if let error = obsManager.connectionError {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
                    .lineLimit(1)
            } else {
                Text(obsManager.isConnected ? "Connected" : "Disconnected")
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
