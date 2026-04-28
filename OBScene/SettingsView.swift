import SwiftUI
import ServiceManagement
import AppKit

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

    /// Permission-denial alert state. Populated when an `obscenePermissionDenied`
    /// notification arrives (e.g. an OBS-restart Apple Event was silently
    /// dropped because Automation TCC was denied). The alert offers a single
    /// "Open System Settings" affordance that deep-links to the relevant
    /// Privacy & Security pane.
    @State private var permissionAlert: PermissionAlertInfo?

    /// Snapshot of the data needed to render and act on the permission alert.
    /// Identifiable so SwiftUI's `.alert(item:)` re-fires when a fresh
    /// notification arrives even if a previous one was dismissed for the
    /// same `kind`.
    fileprivate struct PermissionAlertInfo: Identifiable {
        let id = UUID()
        let kind: OBScenePermissionKind
        let targetName: String
        let context: String

        var title: String {
            "OBScene needs \(kind.displayName) permission"
        }

        var message: String {
            switch kind {
            case .automation:
                return "macOS blocked OBScene from controlling \(targetName) (needed to \(context)). Open System Settings to grant permission, then try again."
            case .accessibility:
                return "macOS blocked OBScene from a request that needed Accessibility access (needed to \(context)). Open System Settings to grant permission, then try again."
            }
        }
    }

    /// Live snapshot of currently-connected USB devices. Seeded on first appear
    /// and refreshed whenever the USBMonitor posts a connect/disconnect
    /// notification, so the picker stays in sync while Settings is open.
    @State private var connectedUSBDevices: [USBDeviceInfo] = []

    /// Profile IDs whose USB picker the user explicitly switched into
    /// "Custom name…" mode. We need to track this separately from the saved
    /// `usbDeviceName` because the user may type a custom string that happens
    /// to match a connected device, and we still want the picker to stay in
    /// custom mode until they pick something else.
    @State private var customUSBModeProfileIDs: Set<UUID> = []

    /// Sentinel tag stored in the picker's selection state to mean
    /// "the user wants to type a custom device name". Chosen to be something
    /// a real device name can't collide with.
    private static let customDeviceSentinel = "__obscene_custom_usb_name__"

    /// Sentinel tag for the "Select a device…" / "(No USB devices detected)"
    /// placeholder row. Kept distinct from "" so we can early-return in the
    /// picker setter and avoid writing it to `usbDeviceName`, and kept
    /// distinct from any plausible real device name or volume label.
    private static let placeholderDeviceTag = "__obscene_usb_placeholder__"
    private static let deviceTagPrefix = "__obscene_usb_device__:"

    /// Map a stored `usbDeviceName` to the exact tag SwiftUI will find on one
    /// of the device rows. Device rows use internal per-device tags so volume
    /// labels that collide with each other or with sentinels don't confuse the
    /// Picker; the binding setter maps those tags back to stored labels/names.
    ///
    /// Search order:
    ///   1. Exact match on the current stored row value.
    ///   2. Some device's `volumeLabels` contains the stored name.
    ///   3. Some device's `name` equals the stored name (so old configs with
    ///      the raw "USB Flash Disk" hardware name find the current row).
    ///   4. No match -> return the placeholder sentinel, forcing the user to
    ///      re-pick.
    fileprivate static func tagForDevice(currentName: String,
                                         devices: [USBDeviceInfo]) -> String {
        if let storedValueMatch = devices.first(where: { storedName(for: $0) == currentName }) {
            return pickerTag(for: storedValueMatch)
        }
        if let labelMatch = devices.first(where: { $0.volumeLabels.contains(currentName) }) {
            return pickerTag(for: labelMatch)
        }
        if let nameMatch = devices.first(where: { $0.name == currentName }) {
            return pickerTag(for: nameMatch)
        }
        return placeholderDeviceTag
    }

    /// Internal SwiftUI tag for a concrete device row; never store this in
    /// config because trigger matching expects the user-facing label/name.
    fileprivate static func pickerTag(for device: USBDeviceInfo) -> String {
        return deviceTagPrefix + device.id
    }

    fileprivate static func storedName(for device: USBDeviceInfo) -> String {
        return device.volumeLabels.first ?? device.name
    }

    var body: some View {
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
            refreshConnectedUSBDevices()
        }
        .onReceive(NotificationCenter.default.publisher(for: .usbDeviceConnected)) { _ in
            refreshConnectedUSBDevices()
        }
        .onReceive(NotificationCenter.default.publisher(for: .usbDeviceDisconnected)) { _ in
            refreshConnectedUSBDevices()
        }
        .onReceive(NotificationCenter.default.publisher(for: .usbDeviceVolumeLabelsResolved)) { _ in
            refreshConnectedUSBDevices()
        }
        .onReceive(NotificationCenter.default.publisher(for: .obscenePermissionDenied)) { note in
            handlePermissionDenied(note)
        }
        .alert(item: $permissionAlert) { info in
            Alert(
                title: Text(info.title),
                message: Text(info.message),
                primaryButton: .default(Text("Open System Settings")) {
                    NSWorkspace.shared.open(info.kind.systemSettingsURL)
                },
                secondaryButton: .cancel(Text("Not Now"))
            )
        }
    }

    /// Translate an incoming permission-denied notification into the
    /// `permissionAlert` state. Defensive parsing — a malformed userInfo
    /// just falls back to the Automation pane (best guess) rather than
    /// crashing or silently dropping the alert.
    private func handlePermissionDenied(_ note: Notification) {
        let info = note.userInfo ?? [:]
        let kindRaw = info["obscenePermissionKind"] as? String ?? OBScenePermissionKind.automation.rawValue
        let kind = OBScenePermissionKind(rawValue: kindRaw) ?? .automation
        let target = info["obscenePermissionTarget"] as? String ?? "the target app"
        let context = info["obscenePermissionContext"] as? String ?? "complete the requested action"
        permissionAlert = PermissionAlertInfo(kind: kind, targetName: target, context: context)
    }

    // MARK: - Layouts

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

    private var leftColumn: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 8) {
                if !configStore.config.hasBeenConfigured {
                    welcomeBanner
                }

                obsConnectionGroup
                profilesSection

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private var rightColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            updatesGroup
            generalGroup
            testingGroup

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

    private var singleColumnLayout: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 12) {
                if !configStore.config.hasBeenConfigured {
                    welcomeBanner
                }

                updatesGroup
                generalGroup
                obsConnectionGroup
                profilesSection
                testingGroup
                activitySection
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    // MARK: - Profiles section (tabbed)

    private var profilesSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            profileTabBar
            selectedProfileContent
        }
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(NSColor.controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color(NSColor.separatorColor), lineWidth: 0.5)
        )
    }

    private var profileTabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(Array(configStore.config.profiles.enumerated()), id: \.element.id) { index, profile in
                    profileTab(for: profile, index: index)
                }

                // Add profile button
                Button(action: addProfile) {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .help("Add a new profile")
            }
            .padding(.horizontal, 4)
            .padding(.top, 4)
        }
    }

    private func profileTab(for profile: TriggerProfile, index: Int) -> some View {
        let isSelected = safeSelectedIndex == index

        return HStack(spacing: 4) {
            // On/off toggle
            Circle()
                .fill(profile.isEnabled ? Color.green : Color.gray.opacity(0.4))
                .frame(width: 7, height: 7)
                .onTapGesture {
                    configStore.config.profiles[index].isEnabled.toggle()
                }
                .help(profile.isEnabled ? "Enabled — click to disable" : "Disabled — click to enable")

            Image(systemName: profile.triggerType.symbol)
                .font(.system(size: 10))
                .foregroundColor(isSelected ? .primary : .secondary)

            Text(profile.name)
                .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                .lineLimit(1)

            // Remove button (only if more than one profile)
            if configStore.config.profiles.count > 1 {
                Button(action: { removeProfile(at: index) }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .opacity(isSelected ? 0.6 : 0.3)
                .help("Remove this profile")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(isSelected ? Color.accentColor.opacity(0.3) : Color.clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            configStore.config.selectedProfileIndex = index
        }
    }

    /// Safe index that clamps to valid range.
    private var safeSelectedIndex: Int {
        let count = configStore.config.profiles.count
        guard count > 0 else { return 0 }
        return min(max(configStore.config.selectedProfileIndex, 0), count - 1)
    }

    /// Binding to the currently selected profile.
    private var selectedProfileBinding: Binding<TriggerProfile> {
        let index = safeSelectedIndex
        return Binding(
            get: {
                guard index < configStore.config.profiles.count else {
                    return TriggerProfile()
                }
                return configStore.config.profiles[index]
            },
            set: { newValue in
                guard index < configStore.config.profiles.count else { return }
                configStore.config.profiles[index] = newValue
            }
        )
    }

    @ViewBuilder
    private var selectedProfileContent: some View {
        if configStore.config.profiles.isEmpty {
            Text("No profiles. Click + to add one.")
                .foregroundColor(.secondary)
                .italic()
                .padding()
        } else {
            let profile = selectedProfileBinding
            VStack(alignment: .leading, spacing: 8) {
                profileNameAndTriggerType(profile: profile)
                Divider().padding(.horizontal, 8)
                triggerSettingsGroup(profile: profile)
                Divider().padding(.horizontal, 8)
                obsConfigurationGroup(profile: profile)
                Divider().padding(.horizontal, 8)
                triggerActionsGroup(profile: profile)
            }
            .padding(10)
        }
    }

    private func profileNameAndTriggerType(profile: Binding<TriggerProfile>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                HStack(spacing: 4) {
                    Text("Name:")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    TextField("Profile name", text: profile.name)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 160)
                }

                HStack(spacing: 4) {
                    Text("Trigger:")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Picker("", selection: profile.triggerType) {
                        ForEach(TriggerProfile.TriggerType.allCases, id: \.self) { type in
                            Label(type.label, systemImage: type.symbol).tag(type)
                        }
                    }
                    .frame(width: 160)
                }

                Toggle("Enabled", isOn: profile.isEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.small)

                Spacer()
            }

            HStack(spacing: 6) {
                Text("Mode:")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Picker("", selection: profile.mode) {
                    ForEach(ProfileTriggerMode.allCases, id: \.self) { m in
                        Label(m.label, systemImage: m.symbol).tag(m)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 280)

                Text(profile.wrappedValue.mode == .plugIn
                     ? "Fires when the trigger condition becomes true."
                     : "Fires when the trigger condition stops being true.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer()
            }
        }
    }

    @ViewBuilder
    private func triggerSettingsGroup(profile: Binding<TriggerProfile>) -> some View {
        GroupBox(label: Label("Trigger Settings", systemImage: profile.wrappedValue.triggerType.symbol)) {
            VStack(alignment: .leading, spacing: 8) {
                if profile.wrappedValue.triggerType == .display {
                    displayTriggerSettings(profile: profile)
                } else {
                    usbTriggerSettings(profile: profile)
                }

                HStack {
                    Text("Delay before triggering:")
                    TextField("5", value: profile.triggerDelay, formatter: NumberFormatter())
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 60)
                    Text("seconds")
                    Spacer()
                }

                HStack {
                    Text("Delay between actions:")
                    TextField("0", value: profile.delayBetweenActions, formatter: Self.delayBetweenActionsFormatter)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 60)
                    Text("seconds")
                    Spacer()
                }
                Text("Seconds between each action when the profile fires. Leave at 0 to fire them all at once.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                // Run-on-activate shell hook. Optional; blank = no script.
                // Runs detached under the user's login shell ($SHELL -l -c,
                // falling back to /bin/bash) when the profile fires, with
                // stdout/stderr logged to ~/Library/Logs/OBScene/script-runs.log.
                Divider().padding(.vertical, 2)
                HStack(alignment: .firstTextBaseline) {
                    Text("Run on activate:")
                    TextField("e.g. restream-channel-switch --alias reeethan", text: profile.runScript)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                }
                Text("Shell command executed when this profile activates. Runs detached under your login shell (zsh/bash -l -c); output is logged to ~/Library/Logs/OBScene/script-runs.log. Leave blank to disable.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                // Restart-OBS-before-run hook. Workaround for the Custom Browser
                // Dock refresh limitation — OBS exposes no programmatic refresh
                // API for docks, so a full app restart is the only reliable way
                // to force them to reload with updated URLs / cookies. Skipped
                // automatically if OBS is currently recording or streaming.
                Toggle("Restart OBS before running", isOn: profile.restartOBSBeforeRun)
                    .padding(.top, 2)
                Text("Quits OBS gracefully, waits for it to relaunch, then runs the command. Useful for refreshing custom browser docks. Skipped if OBS is currently recording or streaming (won't kill a live session).")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                // Sub-toggle that flips the script/restart ordering. Only
                // meaningful when "Restart OBS before running" is on, so we
                // hide it when restart is off — having it always visible
                // would suggest it does something on its own when it doesn't.
                if profile.wrappedValue.restartOBSBeforeRun {
                    Toggle("Run script before restart", isOn: profile.runScriptBeforeRestart)
                        .padding(.leading, 18)
                        .padding(.top, 2)
                    Text("Fire the script BEFORE quitting OBS, instead of after the relaunch. OBScene waits for the script's process to exit (capped at 60s) before sending OBS the quit signal, so any side effects land first. If the script hangs past the cap it's left running in the background and the restart proceeds anyway.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.leading, 18)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func displayTriggerSettings(profile: Binding<TriggerProfile>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Trigger when external displays reach:")
                Picker("", selection: profile.requiredExternalDisplays) {
                    ForEach(1...8, id: \.self) { count in
                        Text("\(count)").tag(count)
                    }
                }
                .frame(width: 60)
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
    }

    private func usbTriggerSettings(profile: Binding<TriggerProfile>) -> some View {
        // Decide whether this profile's picker should be in "Custom name…" mode.
        //
        // Rules:
        //   1. If the user explicitly chose "Custom name…" in this session, stay
        //      in custom mode (tracked in `customUSBModeProfileIDs`).
        //   2. Otherwise, if the stored `usbDeviceName` is non-empty and does NOT
        //      match any currently-connected device (by hardware name OR by any
        //      mounted volume label), assume the saved value is free-text for a
        //      device that isn't plugged in right now.
        //   3. Otherwise (empty, or matches a connected device), show the
        //      device picker with the matching device selected (or the
        //      placeholder row if empty).
        let profileID = profile.wrappedValue.id
        let currentName = profile.wrappedValue.usbDeviceName
        let matchesConnectedDevice = connectedUSBDevices.contains { device in
            device.name == currentName || device.volumeLabels.contains(currentName)
        }
        let isCustomMode = customUSBModeProfileIDs.contains(profileID)
            || (!currentName.isEmpty && !matchesConnectedDevice)

        let pickerSelection = Binding<String>(
            get: {
                if isCustomMode { return Self.customDeviceSentinel }
                if currentName.isEmpty { return Self.placeholderDeviceTag }
                // Round-trip the stored label/name into the current row's
                // internal per-device tag.
                return Self.tagForDevice(currentName: currentName,
                                         devices: connectedUSBDevices)
            },
            set: { newValue in
                if newValue == Self.customDeviceSentinel {
                    // User explicitly switched to custom-name mode. Remember
                    // that choice and leave `usbDeviceName` untouched so any
                    // previously-typed string is preserved for editing.
                    customUSBModeProfileIDs.insert(profileID)
                    return
                }
                if newValue == Self.placeholderDeviceTag {
                    // The placeholder is `.disabled(true)` so this shouldn't
                    // happen, but if some accessibility path triggers it we
                    // MUST NOT overwrite `usbDeviceName` with the sentinel.
                    return
                }
                guard let selectedDevice = connectedUSBDevices.first(where: {
                    Self.pickerTag(for: $0) == newValue
                }) else {
                    // Unknown picker tags are UI-only state; don't persist
                    // them into the trigger matcher.
                    return
                }
                // User picked an actual device. Leave custom mode and write
                // the volume label if present, else the hardware name.
                customUSBModeProfileIDs.remove(profileID)
                profile.wrappedValue.usbDeviceName = Self.storedName(for: selectedDevice)
            }
        )

        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("USB device:")
                Picker("", selection: pickerSelection) {
                    // Always include a placeholder row so a blank
                    // `usbDeviceName` has a valid selection target and SwiftUI
                    // doesn't warn about an unmatched picker selection. The
                    // row is `.disabled` so the user can't actually pick it.
                    if connectedUSBDevices.isEmpty {
                        Text("(No USB devices detected)")
                            .tag(Self.placeholderDeviceTag)
                            .disabled(true)
                    } else {
                        Text("Select a device…")
                            .tag(Self.placeholderDeviceTag)
                            .disabled(true)
                        ForEach(connectedUSBDevices, id: \.id) { device in
                            // Use an internal tag so duplicate labels don't
                            // destabilize SwiftUI selection; the setter stores
                            // the user-recognisable label/name instead.
                            Text(device.displayLabel)
                                .tag(Self.pickerTag(for: device))
                        }
                    }
                    Divider()
                    Text("Custom name…").tag(Self.customDeviceSentinel)
                }
                .frame(maxWidth: 320)

                Button(action: refreshConnectedUSBDevices) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh the list of currently-connected USB devices.")

                Spacer()
            }

            if isCustomMode {
                HStack {
                    Text("Custom name:")
                    TextField("e.g. CalDigit TS4", text: profile.usbDeviceName)
                        .textFieldStyle(.roundedBorder)
                    Spacer()
                }
                Text("Triggers when a USB device whose name contains this text is plugged in (case-insensitive). Use this for devices that aren't currently plugged in.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Triggers when this USB device is plugged in. Pick \"Custom name…\" to match a device by name instead (useful when the device isn't currently connected).")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Refresh the cached snapshot of connected USB devices. Called on
    /// appear, on the manual Refresh button, and when the USBMonitor posts
    /// a connect/disconnect notification.
    private func refreshConnectedUSBDevices() {
        connectedUSBDevices = USBMonitor.shared.currentUSBDevices()
    }

    private func obsConfigurationGroup(profile: Binding<TriggerProfile>) -> some View {
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
                        Picker("", selection: profile.selectedSceneCollection) {
                            Text("(Don't change)").tag("")
                            ForEach(obsManager.sceneCollections, id: \.self) { collection in
                                Text(collection).tag(collection)
                            }
                        }
                    }

                    HStack {
                        Text("Profile:")
                            .frame(width: 120, alignment: .trailing)
                        Picker("", selection: profile.selectedProfile) {
                            Text("(Don't change)").tag("")
                            ForEach(obsManager.profiles, id: \.self) { obsProfile in
                                Text(obsProfile).tag(obsProfile)
                            }
                        }
                    }

                    HStack {
                        Text("Scene:")
                            .frame(width: 120, alignment: .trailing)
                        Picker("", selection: profile.selectedScene) {
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

    private func triggerActionsGroup(profile: Binding<TriggerProfile>) -> some View {
        let modeShort = profile.wrappedValue.mode.shortLabel
        return GroupBox(
            label: Label("Trigger Actions (on \(modeShort))", systemImage: "bolt.fill")
        ) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(TriggerActionKind.displayOrder, id: \.self) { kind in
                    actionRow(kind: kind, profile: profile)
                }
            }
            .padding(.vertical, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// One row in the Trigger Actions list. Checkbox toggles whether the
    /// action runs at all; the right-hand picker chooses start vs stop
    /// (hidden for one-shot refresh actions).
    private func actionRow(kind: TriggerActionKind,
                           profile: Binding<TriggerProfile>) -> some View {
        let isEnabled = profile.wrappedValue.actions.contains(where: { $0.kind == kind })
        return HStack(spacing: 8) {
            Toggle(isOn: Binding(
                get: { isEnabled },
                set: { newValue in
                    var updated = profile.wrappedValue.actions
                    if newValue {
                        if !updated.contains(where: { $0.kind == kind }) {
                            // Default mode: .start. Refresh kinds force .start
                            // in `TriggerActionConfig.init`.
                            updated.append(TriggerActionConfig(kind: kind, mode: .start))
                        }
                    } else {
                        updated.removeAll { $0.kind == kind }
                    }
                    profile.wrappedValue.actions = updated
                }
            )) {
                Label(kind.label, systemImage: kind.symbol)
                    .labelStyle(.titleAndIcon)
            }
            .toggleStyle(.checkbox)

            Spacer(minLength: 8)

            if kind.supportsStop {
                Picker("", selection: Binding(
                    get: {
                        profile.wrappedValue.actions.first(where: { $0.kind == kind })?.mode ?? .start
                    },
                    set: { newMode in
                        var updated = profile.wrappedValue.actions
                        if let idx = updated.firstIndex(where: { $0.kind == kind }) {
                            updated[idx].mode = newMode
                            profile.wrappedValue.actions = updated
                        }
                    }
                )) {
                    ForEach(TriggerActionMode.allCases, id: \.self) { m in
                        Text(m.label).tag(m)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 90)
                .disabled(!isEnabled)
            } else {
                // Reserve the same horizontal space so rows line up vertically.
                Text("Fire")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(width: 90, alignment: .center)
            }
        }
    }

    // MARK: - Profile management

    private func addProfile() {
        var newProfile = TriggerProfile()
        newProfile.name = "Profile \(configStore.config.profiles.count + 1)"
        newProfile.mode = .plugIn
        newProfile.migratedToModeSchema = true
        configStore.config.profiles.append(newProfile)
        configStore.config.selectedProfileIndex = configStore.config.profiles.count - 1
    }

    private func removeProfile(at index: Int) {
        guard configStore.config.profiles.count > 1 else { return }
        configStore.config.profiles.remove(at: index)
        if configStore.config.selectedProfileIndex >= configStore.config.profiles.count {
            configStore.config.selectedProfileIndex = max(0, configStore.config.profiles.count - 1)
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

                Divider().padding(.vertical, 1)

                Toggle("Restore Mission Control Space on OBS restart",
                       isOn: $configStore.config.restoreSpaceOnRestart)
                Text("When OBScene restarts OBS (via the per-profile \"Restart OBS before running\" toggle), capture the Space the OBS window was on before quitting and move OBS back to that Space after relaunch. Falls back gracefully on macOS versions where the required private API is unavailable.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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

    private var testingGroup: some View {
        GroupBox(label: Label("Testing", systemImage: "play.circle")) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Dry-run the selected profile's trigger as if the trigger condition was just met. The configured delay is skipped.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack {
                    Spacer()
                    Button("Simulate Trigger") {
                        let index = safeSelectedIndex
                        guard index < configStore.config.profiles.count else { return }
                        let profile = configStore.config.profiles[index]
                        DisplayMonitor.shared.runTestTrigger(for: profile)
                    }
                    .disabled(configStore.config.profiles.isEmpty)
                }
            }
            .padding(.vertical, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var activitySection: some View {
        GroupBox(label: Label("Activity", systemImage: "clock.arrow.circlepath")) {
            VStack(alignment: .leading, spacing: 8) {
                // "Open Logs" handed Ethan the script-runs.log file (the
                // same path mentioned in the per-profile script help text)
                // so he can audit shell output without spelunking through
                // ~/Library/Logs. We don't force Console.app — handing the
                // URL to NSWorkspace lets the user's default `.log` editor
                // open it (Console.app, BBEdit, VS Code, whatever).
                HStack {
                    Spacer()
                    Button {
                        openScriptRunsLog()
                    } label: {
                        Label("Open Logs", systemImage: "doc.text.magnifyingglass")
                    }
                    .help("Open ~/Library/Logs/OBScene/script-runs.log in your default .log editor.")
                }

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

    /// Open the script-runs log file in the user's default `.log` editor
    /// (typically Console.app on a fresh macOS install). Creates the file
    /// first if it doesn't exist yet — without this, NSWorkspace.open would
    /// fall back to Finder showing the empty Logs/OBScene directory.
    private func openScriptRunsLog() {
        ScriptRunner.ensureLogFileExists()
        let url = ScriptRunner.logFileURL
        if !NSWorkspace.shared.open(url) {
            // Fallback: reveal in Finder so the user can still see the file
            // exists, even if no .log handler is registered (rare but
            // possible if the user has unbound the extension).
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    private static let activityFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .medium
        return f
    }()

    /// Formatter for the per-profile "Delay between actions" field. Accepts
    /// fractional seconds (e.g. 0.5) with up to 3 decimal places, clamped at
    /// zero so the user can't enter a negative value.
    private static let delayBetweenActionsFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.minimum = 0
        f.minimumFractionDigits = 0
        f.maximumFractionDigits = 3
        f.allowsFloats = true
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
            DispatchQueue.main.async {
                launchAtLogin = SMAppService.mainApp.status == .enabled
            }
        }
    }

    private var updatesSection: some View {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"

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

            updateStatusLine
                .font(.caption)
                .animation(.easeInOut(duration: 0.18), value: updater.isChecking)
                .animation(.easeInOut(duration: 0.18), value: updater.lastCheckResult)

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
                    Text("Install")
                }
                .disabled(updater.pendingUpdate == nil)

                Spacer()
            }
            .animation(.easeInOut(duration: 0.18), value: updater.pendingUpdate != nil)

            Divider().padding(.vertical, 1)

            Toggle("Automatically check for updates", isOn: Binding(
                get: { updater.automaticallyChecksForUpdates },
                set: { updater.automaticallyChecksForUpdates = $0 }
            ))
            Toggle("Automatically download and install", isOn: Binding(
                get: { updater.automaticallyDownloadsUpdates },
                set: { updater.automaticallyDownloadsUpdates = $0 }
            ))
            .disabled(!updater.automaticallyChecksForUpdates)
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
                Text("Connect to OBS below, create profiles with trigger conditions, and pick the actions for each. When your trigger conditions are met, OBScene will switch OBS and (optionally) start recording or streaming automatically.")
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
        OBSConnectionStatusPill(obsManager: obsManager)
    }

    private func connectToOBS() {
        let port = Int(obsPort) ?? 4455

        configStore.config.obsHost = obsHost
        configStore.config.obsPort = port
        configStore.config.obsPassword = obsPassword
        configStore.config.hasBeenConfigured = true

        isConnecting = true

        obsManager.connect(host: obsHost, port: port, password: obsPassword)

        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            isConnecting = false
        }
    }
}
