import AppKit
import SwiftUI

struct FileTransferSettingsView: View {
    @EnvironmentObject private var configStore: ConfigStore
    @ObservedObject private var transferManager = FileTransferManager.shared

    @State private var selectedRuleID: UUID?
    @State private var errorMessage: String?
    @State private var rulePendingRemovalID: UUID?

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            sidebar
                .frame(width: 250)
            Divider()
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .onAppear {
            if selectedRuleID == nil {
                selectedRuleID = configStore.config.fileTransferRules.first?.id
            }
        }
        .alert("File Transfer Setup", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .confirmationDialog(
            "Remove this automatic transfer?",
            isPresented: Binding(
                get: { rulePendingRemovalID != nil },
                set: { if !$0 { rulePendingRemovalID = nil } }
            )
        ) {
            Button("Remove Transfer", role: .destructive) {
                if let rulePendingRemovalID {
                    removeRule(id: rulePendingRemovalID)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the setup and its history from OBScene. It does not delete any recording or backup files.")
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Automatic Transfers")
                .font(.headline)
                .padding(.horizontal, 12)
                .padding(.top, 12)

            Text("Copy finished recordings when their backup drive appears.")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12)

            ScrollView {
                VStack(spacing: 4) {
                    ForEach(configStore.config.fileTransferRules) { rule in
                        ruleRow(rule)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }

            Divider()
            Button {
                addRule()
            } label: {
                Label("Set Up Transfer…", systemImage: "plus")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .padding(10)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color(NSColor.controlBackgroundColor))
    }

    private func ruleRow(_ rule: FileTransferRule) -> some View {
        let isSelected = selectedRuleID == rule.id
        let state = transferManager.states[rule.id] ?? .waiting
        return Button {
            selectedRuleID = rule.id
        } label: {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: state.phase.isWorking ? "arrow.triangle.2.circlepath" : "externaldrive")
                    .foregroundColor(statusColor(for: state.phase))
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 3) {
                    Text(rule.name)
                        .fontWeight(isSelected ? .semibold : .regular)
                        .lineLimit(1)
                    Text(rule.isEnabled ? state.phase.label : "Disabled")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .padding(9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.13) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var detail: some View {
        if let index = selectedRuleIndex {
            ruleEditor(index: index)
        } else {
            VStack(spacing: 16) {
                Image(systemName: "externaldrive.fill.badge.plus")
                    .font(.system(size: 52))
                    .foregroundColor(.accentColor)
                Text("Back up recordings automatically")
                    .font(.title2.bold())
                Text("Choose the folder where recordings land on this Mac, then choose a folder on the backup drive. OBScene will recognize that exact drive whenever it is connected.")
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 520)
                Button("Set Up Your First Transfer…") {
                    addRule()
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
            }
            .padding(40)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func ruleEditor(index: Int) -> some View {
        let rule = configStore.config.fileTransferRules[index]
        let state = transferManager.states[rule.id] ?? .waiting
        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 3) {
                        TextField("Transfer name", text: $configStore.config.fileTransferRules[index].name)
                            .textFieldStyle(.plain)
                            .font(.title2.bold())
                        Text(state.phase.label)
                            .font(.callout)
                            .foregroundColor(statusColor(for: state.phase))
                    }
                    Spacer()
                    Toggle("Enabled", isOn: $configStore.config.fileTransferRules[index].isEnabled)
                        .toggleStyle(.switch)
                        .onChange(of: configStore.config.fileTransferRules[index].isEnabled) { _ in
                            transferManager.runNow(ruleID: rule.id)
                        }
                }

                if state.phase.isWorking {
                    ProgressView()
                        .progressViewStyle(.linear)
                }

                GroupBox(label: Label("Folders", systemImage: "folder")) {
                    VStack(spacing: 0) {
                        folderRow(
                            title: "Recordings on this Mac",
                            path: rule.sourceFolderPath,
                            symbol: "laptopcomputer",
                            actionTitle: "Change…"
                        ) {
                            changeSource(index: index)
                        }
                        Divider().padding(.vertical, 10)
                        folderRow(
                            title: "Backup destination",
                            path: rule.destinationDisplayPath,
                            symbol: "externaldrive",
                            actionTitle: "Change…"
                        ) {
                            changeDestination(index: index)
                        }
                    }
                    .padding(.vertical, 5)
                }

                GroupBox(label: Label("Safe cleanup", systemImage: "checkmark.shield")) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Keep laptop originals for")
                            Stepper(
                                value: $configStore.config.fileTransferRules[index].retentionDays,
                                in: 1...365
                            ) {
                                Text("\(configStore.config.fileTransferRules[index].retentionDays) days")
                                    .monospacedDigit()
                                    .frame(minWidth: 58, alignment: .trailing)
                            }
                            Spacer()
                        }
                        safetyLine("Copies finish at a hidden temporary path, so interrupted transfers never look complete.")
                        safetyLine("The laptop and hard-drive files must have identical SHA-256 hashes before the retention clock begins.")
                        safetyLine("Before deleting, OBScene verifies both files again while the backup drive is present. Any mismatch keeps the laptop copy and restarts the transfer.")
                    }
                    .padding(.vertical, 5)
                }

                GroupBox(label: Label("Status", systemImage: "clock.arrow.circlepath")) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Circle()
                                .fill(statusColor(for: state.phase))
                                .frame(width: 8, height: 8)
                            Text(state.phase.label)
                            Spacer()
                            if let lastRunAt = state.lastRunAt {
                                Text("Checked \(lastRunAt.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        Text("Files changed within the last two minutes are treated as still recording and retried automatically.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        HStack {
                            Button {
                                transferManager.runNow(ruleID: rule.id)
                            } label: {
                                Label("Check and Transfer Now", systemImage: "arrow.clockwise")
                            }
                            .disabled(state.phase.isWorking || !rule.isEnabled)
                            Spacer()
                            Button("Show Source in Finder") {
                                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: rule.sourceFolderPath)
                            }
                        }
                    }
                    .padding(.vertical, 5)
                }

                HStack {
                    Spacer()
                    Button("Remove Transfer", role: .destructive) {
                        rulePendingRemovalID = rule.id
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: 760, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func folderRow(title: String,
                           path: String,
                           symbol: String,
                           actionTitle: String,
                           action: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundColor(.accentColor)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.weight(.medium))
                Text(path)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
            Spacer()
            Button(actionTitle, action: action)
        }
    }

    private func safetyLine(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.green)
            Text(text)
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var selectedRuleIndex: Int? {
        guard let selectedRuleID else { return nil }
        return configStore.config.fileTransferRules.firstIndex { $0.id == selectedRuleID }
    }

    private func addRule() {
        guard let source = chooseFolder(
            title: "Choose the recordings folder on this Mac",
            prompt: "Choose Recordings Folder"
        ) else { return }
        guard let destination = chooseFolder(
            title: "Choose a destination folder on the backup drive",
            prompt: "Choose Backup Folder"
        ) else { return }

        do {
            try validateFoldersDoNotOverlap(source: source, destination: destination)
            let identity = try FileTransferManager.destinationIdentity(for: destination)
            var rule = FileTransferRule()
            rule.name = "\(source.lastPathComponent) → \(identity.volumeName)"
            rule.sourceFolderPath = source.standardizedFileURL.path
            rule.destinationVolumeUUID = identity.volumeUUID
            rule.destinationVolumeName = identity.volumeName
            rule.destinationRelativePath = identity.relativePath
            configStore.config.fileTransferRules.append(rule)
            selectedRuleID = rule.id
            transferManager.runNow(ruleID: rule.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func changeSource(index: Int) {
        guard let source = chooseFolder(
            title: "Choose the recordings folder on this Mac",
            prompt: "Choose Recordings Folder",
            initialPath: configStore.config.fileTransferRules[index].sourceFolderPath
        ) else { return }
        configStore.config.fileTransferRules[index].sourceFolderPath = source.standardizedFileURL.path
        transferManager.runNow(ruleID: configStore.config.fileTransferRules[index].id)
    }

    private func changeDestination(index: Int) {
        guard let destination = chooseFolder(
            title: "Choose a destination folder on the backup drive",
            prompt: "Choose Backup Folder"
        ) else { return }
        do {
            let source = configStore.config.fileTransferRules[index].sourceFolderURL
            try validateFoldersDoNotOverlap(source: source, destination: destination)
            let identity = try FileTransferManager.destinationIdentity(for: destination)
            configStore.config.fileTransferRules[index].destinationVolumeUUID = identity.volumeUUID
            configStore.config.fileTransferRules[index].destinationVolumeName = identity.volumeName
            configStore.config.fileTransferRules[index].destinationRelativePath = identity.relativePath
            transferManager.runNow(ruleID: configStore.config.fileTransferRules[index].id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func removeRule(id: UUID) {
        guard let index = configStore.config.fileTransferRules.firstIndex(where: { $0.id == id }) else {
            return
        }
        configStore.config.fileTransferRules.remove(at: index)
        rulePendingRemovalID = nil
        if selectedRuleID == id {
            selectedRuleID = configStore.config.fileTransferRules.first?.id
        }
    }

    private func chooseFolder(title: String,
                              prompt: String,
                              initialPath: String? = nil) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.prompt = prompt
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        if let initialPath, !initialPath.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: initialPath, isDirectory: true)
        }
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func validateFoldersDoNotOverlap(source: URL, destination: URL) throws {
        let sourcePath = source.standardizedFileURL.path
        let destinationPath = destination.standardizedFileURL.path
        guard sourcePath != destinationPath,
              !destinationPath.hasPrefix(sourcePath + "/"),
              !sourcePath.hasPrefix(destinationPath + "/")
        else {
            throw FileTransferError.invalidFolderSelection(
                "The recordings folder and backup folder cannot contain each other."
            )
        }
    }

    private func statusColor(for phase: FileTransferPhase) -> Color {
        switch phase {
        case .disabled:
            return .secondary
        case .waitingForDrive:
            return .orange
        case .scanning, .copying, .verifying:
            return .accentColor
        case .ready:
            return .green
        case .failed:
            return .red
        }
    }
}
