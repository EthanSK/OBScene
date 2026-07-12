import AppKit
import Combine
import Foundation

extension Notification.Name {
    static let fileTransferStateChanged = Notification.Name("fileTransferStateChanged")
}

/// Watches volume mounts and periodically revisits configured rules. A timer
/// matters because a dock may stay attached while OBS finishes another
/// recording, and because retained laptop copies become eligible for cleanup
/// without another physical unplug/replug edge.
final class FileTransferManager: ObservableObject {
    static let shared = FileTransferManager()

    enum ScanReason: Equatable {
        case launch
        case driveMounted
        case periodic
        case manual
    }

    @Published private(set) var states: [UUID: FileTransferRuleState] = [:]

    private let engine = FileTransferEngine()
    private let workQueue = DispatchQueue(label: "com.ethansk.OBScene.FileTransfer", qos: .utility)
    private let runLock = NSLock()
    private var scanIsQueuedOrRunning = false
    private var pendingScan = false
    private var workspaceObservers: [NSObjectProtocol] = []
    private var timer: Timer?
    private var isMonitoring = false
    private var manifest: FileTransferManifest

    // MARK: - Plug-in EDGE detection state
    //
    // The transfer must fire exactly ONCE when a rule's destination (backup) drive
    // goes from NOT-connected -> connected. macOS posts didMount/didUnmount for
    // EVERY volume, and a single dock connect emits a BURST of them; unrelated USB
    // drives, disk images and network shares fire them too. So we cannot treat each
    // mount event as a trigger. Instead we remember which volume UUIDs were mounted
    // last time (`lastKnownMountedUUIDs`) and only act on a genuine rising edge for
    // a watched rule's destination drive. See handleMountChange().

    /// The set of volume UUIDs that were mounted at the previous mount-change tick.
    /// Diffed against the current set to detect rising edges. Seeded in
    /// startMonitoring() so a drive already plugged in at launch counts as
    /// "already connected" (the launch scan handles it), NOT as a fresh edge.
    private var lastKnownMountedUUIDs: Set<String> = []

    /// Per-destination-UUID timestamp of the last connect that actually triggered a
    /// scan. Guards against rapid unplug->replug churn (and duplicate mount signals)
    /// re-firing the transfer: a new rising edge within `reTriggerGuardInterval` of
    /// the previous triggered run for the same drive is swallowed.
    private var lastConnectTriggerAt: [String: Date] = [:]

    /// Wait this long after a connect edge before scanning, so the dock's mount
    /// burst settles and the volume is fully ready. Also coalesces multiple mounts
    /// of the same physical connection into one run.
    private let connectSettleDelay: TimeInterval = 3

    /// Ignore a fresh connect edge for the same drive within this window of its last
    /// triggered run — an unplug->replug bounce is one physical connection = one run.
    private let reTriggerGuardInterval: TimeInterval = 30

    static var manifestFileURL: URL {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        return applicationSupport
            .appendingPathComponent("OBScene", isDirectory: true)
            .appendingPathComponent("file-transfer-manifest.json", isDirectory: false)
    }

    private init() {
        manifest = Self.loadManifest()
    }

    deinit {
        stopMonitoring()
    }

    func startMonitoring() {
        guard !isMonitoring else { return }
        isMonitoring = true
        // Seed the edge-detector with whatever is already mounted, so a backup drive
        // that is ALREADY plugged in when OBScene launches is treated as "already
        // connected" (the launch scan below handles it once) rather than as a fresh
        // connect edge that would double-run.
        lastKnownMountedUUIDs = Set(Self.mountedVolumes().map { $0.uuid })
        let center = NSWorkspace.shared.notificationCenter
        // Both mount AND unmount funnel through handleMountChange, which diffs the
        // mounted-volume set and fires a transfer ONLY on a NOT-connected ->
        // connected transition of a watched rule's destination drive. This replaces
        // the old "scan on every didMount" behavior that spammed no-op notifications.
        workspaceObservers.append(
            center.addObserver(forName: NSWorkspace.didMountNotification, object: nil, queue: .main) { [weak self] _ in
                self?.handleMountChange()
            }
        )
        workspaceObservers.append(
            center.addObserver(forName: NSWorkspace.didUnmountNotification, object: nil, queue: .main) { [weak self] _ in
                self?.handleMountChange()
            }
        )
        // The periodic timer is NOT a transfer trigger for the plug-in case — it only
        // exists so retained laptop copies become eligible for cleanup while a drive
        // stays attached (see class doc). It never posts a no-op notification.
        timer = Timer.scheduledTimer(withTimeInterval: 15 * 60, repeats: true) { [weak self] _ in
            self?.requestScan(reason: .periodic)
        }
        refreshWaitingStates()
        requestScan(reason: .launch)
    }

    func stopMonitoring() {
        guard isMonitoring else { return }
        isMonitoring = false
        timer?.invalidate()
        timer = nil
        let center = NSWorkspace.shared.notificationCenter
        for observer in workspaceObservers {
            center.removeObserver(observer)
        }
        workspaceObservers.removeAll()
    }

    /// Central plug-in EDGE handler. Called on EVERY volume mount AND unmount.
    ///
    /// The trigger is the RISING EDGE of a watched rule's destination drive:
    /// not-connected -> connected. We compare the current mounted-UUID set against
    /// the last-known set and only run a rule when ITS backup drive just appeared.
    ///
    /// Debounce / de-dupe against USB churn:
    ///  - `connectSettleDelay` waits a few seconds after the edge before scanning so
    ///    the dock's mount burst finishes and the volume is fully ready (also
    ///    coalesces the burst into a single run).
    ///  - `reTriggerGuardInterval` swallows a rapid unplug->replug (or a duplicate
    ///    mount signal): one physical connection = at most one transfer run.
    ///
    /// This is what fixed the notification spam: the old code ran a full scan on
    /// EVERY didMount (any volume), so with the backup drive already connected it
    /// repeatedly found nothing and posted "Everything is already transferred and
    /// verified". Now an unrelated volume mounting is NOT a rising edge for the
    /// backup drive (it was already connected), so nothing re-fires.
    private func handleMountChange() {
        let currentUUIDs = Set(Self.mountedVolumes().map { $0.uuid })
        let previousUUIDs = lastKnownMountedUUIDs
        lastKnownMountedUUIDs = currentUUIDs

        for rule in ConfigStore.shared.config.fileTransferRules where rule.isEnabled {
            let destUUID = rule.destinationVolumeUUID
            let wasConnected = previousUUIDs.contains(destUUID)
            let isConnected = currentUUIDs.contains(destUUID)

            if isConnected && !wasConnected {
                // Rising edge for this rule's backup drive — the ONE moment we run.
                let now = Date()
                if let last = lastConnectTriggerAt[destUUID],
                   now.timeIntervalSince(last) < reTriggerGuardInterval {
                    // Unplug->replug bounce (or a duplicate mount signal) within the
                    // guard window: same physical connection, so do NOT re-run.
                    ActivityLog.shared.log(
                        .info,
                        "\(rule.name): backup drive reconnected within \(Int(reTriggerGuardInterval))s of the last run — skipping duplicate transfer.",
                        userVisible: false
                    )
                    continue
                }
                lastConnectTriggerAt[destUUID] = now
                // Settle delay: let the mount burst finish + the volume become fully
                // ready, then scan this rule exactly once for the fresh connection.
                DispatchQueue.main.asyncAfter(deadline: .now() + connectSettleDelay) { [weak self] in
                    self?.requestScan(reason: .driveMounted, onlyRuleID: rule.id)
                }
            } else if !isConnected {
                // Drive absent (including right after its own unmount) — reflect it.
                updateState(ruleID: rule.id, phase: .waitingForDrive)
            }
            // isConnected && wasConnected: drive stayed put — deliberately do nothing
            // so it never re-fires while it remains connected.
        }
    }

    func runNow() {
        requestScan(reason: .manual)
    }

    func runNow(ruleID: UUID) {
        requestScan(reason: .manual, onlyRuleID: ruleID)
    }

    var menuSummary: String {
        let enabledRules = ConfigStore.shared.config.fileTransferRules.filter { $0.isEnabled }
        guard !enabledRules.isEmpty else { return "Transfers: Not configured" }
        let enabledStates = enabledRules.compactMap { states[$0.id] }
        if let working = enabledStates.first(where: { $0.phase.isWorking }) {
            return "Transfers: " + working.phase.label
        }
        if let failed = enabledStates.first(where: {
            if case .failed = $0.phase { return true }
            return false
        }) {
            return "Transfers: " + failed.phase.label
        }
        let waitingCount = enabledStates.filter { $0.phase == .waitingForDrive }.count
        if waitingCount == enabledRules.count {
            return "Transfers: Waiting for drive"
        }
        return "Transfers: Ready"
    }

    /// Convert a folder selected while an external drive is mounted into the
    /// stable UUID + relative-path identity persisted by a rule.
    static func destinationIdentity(for selectedFolder: URL) throws -> (
        volumeUUID: String,
        volumeName: String,
        relativePath: String
    ) {
        let selected = selectedFolder.standardizedFileURL
        guard let volume = mountedVolumes().first(where: {
            selected.path == $0.rootURL.path || selected.path.hasPrefix($0.rootURL.path + "/")
        }) else {
            throw FileTransferError.invalidFolderSelection("Choose a folder on a mounted external drive.")
        }
        guard !volume.isInternal else { // The destination must be a second physical copy, not another folder on the recording Mac.
            throw FileTransferError.invalidFolderSelection("Choose a folder on an external drive, not the Mac's internal disk.")
        }
        let relativePath = selected.pathComponents
            .dropFirst(volume.rootURL.pathComponents.count)
            .joined(separator: "/")
        return (volume.uuid, volume.name, relativePath)
    }

    static func mountedVolumes() -> [MountedTransferVolume] {
        let keys: [URLResourceKey] = [
            .volumeNameKey,
            .volumeUUIDStringKey,
            .volumeIsInternalKey,
        ]
        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys,
            options: [.skipHiddenVolumes]
        ) ?? []
        return urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  let uuid = values.volumeUUIDString,
                  let name = values.volumeName,
                  let isInternal = values.volumeIsInternal
            else {
                return nil
            }
            return MountedTransferVolume(
                rootURL: url.standardizedFileURL,
                uuid: uuid,
                name: name,
                isInternal: isInternal
            )
        }
    }

    private func requestScan(reason: ScanReason, onlyRuleID: UUID? = nil) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.requestScan(reason: reason, onlyRuleID: onlyRuleID)
            }
            return
        }

        runLock.lock()
        if scanIsQueuedOrRunning {
            pendingScan = true
            runLock.unlock()
            return
        }
        scanIsQueuedOrRunning = true
        runLock.unlock()

        let configuredRules = ConfigStore.shared.config.fileTransferRules
        let rules = configuredRules.filter { onlyRuleID == nil || $0.id == onlyRuleID }
        workQueue.async { [weak self] in
            self?.run(rules: rules, reason: reason)
            DispatchQueue.main.async { [weak self] in
                self?.finishScan()
            }
        }
    }

    private func finishScan() {
        runLock.lock()
        let shouldRunAgain = pendingScan
        pendingScan = false
        scanIsQueuedOrRunning = false
        runLock.unlock()
        if shouldRunAgain {
            requestScan(reason: .periodic)
        }
    }

    private func run(rules: [FileTransferRule], reason: ScanReason) {
        let volumesByUUID = Dictionary(
            uniqueKeysWithValues: Self.mountedVolumes().map { ($0.uuid, $0) }
        )
        for rule in rules {
            guard rule.isEnabled else {
                updateState(ruleID: rule.id, phase: .disabled)
                continue
            }
            guard let volume = volumesByUUID[rule.destinationVolumeUUID] else {
                updateState(ruleID: rule.id, phase: .waitingForDrive)
                continue
            }
            run(rule: rule, volume: volume, reason: reason)
        }
    }

    private func run(rule: FileTransferRule,
                     volume: MountedTransferVolume,
                     reason: ScanReason) {
        updateState(ruleID: rule.id, phase: .scanning)
        let destinationFolder = rule.destinationRelativePath.isEmpty
            ? volume.rootURL
            : volume.rootURL.appendingPathComponent(rule.destinationRelativePath, isDirectory: true)

        do {
            let sourcePath = rule.sourceFolderURL.standardizedFileURL.path
            let destinationPath = destinationFolder.standardizedFileURL.path
            guard sourcePath != destinationPath,
                  !destinationPath.hasPrefix(sourcePath + "/"),
                  !sourcePath.hasPrefix(destinationPath + "/")
            else { // A later folder edit must never turn the backup into a recursive self-copy.
                throw FileTransferError.invalidFolderSelection(
                    "The recordings folder and backup folder cannot contain each other."
                )
            }
            try FileManager.default.createDirectory(
                at: destinationFolder,
                withIntermediateDirectories: true
            )
            let candidates = try engine.candidates(in: rule.sourceFolderURL)
            let settledCandidates = candidates.filter { engine.isSettled($0, now: Date()) }
            var copiedFiles = 0
            var deletedFiles = 0
            var didPostStartNotification = false

            for (index, candidate) in settledCandidates.enumerated() {
                let destinationURL = engine.destinationURL(
                    for: candidate,
                    destinationFolder: destinationFolder
                )
                let existingEntry = manifest.entry(
                    ruleID: rule.id,
                    relativePath: candidate.relativePath
                )
                let entryDescribesSource = existingEntry?.sourceSnapshot == candidate.snapshot
                let verifiedDestinationExists = existingEntry.map {
                    engine.destinationStillExists(for: $0, destinationURL: destinationURL)
                } ?? false

                if let existingEntry,
                   entryDescribesSource,
                   verifiedDestinationExists {
                    let retentionElapsed = Date().timeIntervalSince(existingEntry.transferredAt)
                        >= TimeInterval(rule.retentionDays) * 24 * 60 * 60
                    if !retentionElapsed {
                        continue
                    }

                    updateState(
                        ruleID: rule.id,
                        phase: .verifying(
                            fileName: candidate.sourceURL.lastPathComponent,
                            completed: index,
                            total: settledCandidates.count
                        )
                    )
                    if try engine.isSafeToDelete(
                        candidate: candidate,
                        destinationURL: destinationURL,
                        manifestEntry: existingEntry,
                        retentionDays: rule.retentionDays,
                        now: Date()
                    ) {
                        try engine.deleteSource(candidate)
                        deletedFiles += 1
                        ActivityLog.shared.log(
                            .fileDeleted,
                            "Deleted retained laptop copy after re-verifying both files: \(candidate.relativePath)",
                            userVisible: true
                        )
                        continue
                    }
                    // The destination or source no longer matches the proof.
                    // Re-copying creates a fresh verified proof and resets the
                    // retention clock; deletion is deliberately skipped.
                }

                if !didPostStartNotification {
                    didPostStartNotification = true
                    UserNotifier.post(
                        title: "OBScene transfer started",
                        body: "Copying recordings to \(volume.name). Originals will remain on this Mac for at least \(rule.retentionDays) days."
                    )
                    ActivityLog.shared.log(
                        .fileTransferStarted,
                        "Transfer started: \(rule.name) → \(volume.name)",
                        userVisible: true
                    )
                }
                updateState(
                    ruleID: rule.id,
                    phase: .copying(
                        fileName: candidate.sourceURL.lastPathComponent,
                        completed: index,
                        total: settledCandidates.count
                    )
                )
                let verifiedCopy = try engine.copyAndVerify(
                    candidate: candidate,
                    destinationURL: destinationURL,
                    ruleID: rule.id
                )
                updateState(
                    ruleID: rule.id,
                    phase: .verifying(
                        fileName: candidate.sourceURL.lastPathComponent,
                        completed: index,
                        total: settledCandidates.count
                    )
                )
                manifest.set(FileTransferManifestEntry(
                    ruleID: rule.id,
                    relativePath: candidate.relativePath,
                    sourceSnapshot: verifiedCopy.sourceSnapshot,
                    sha256: verifiedCopy.sha256,
                    transferredAt: Date()
                ))
                try saveManifest()
                copiedFiles += 1
            }

            let unsettledFiles = candidates.count - settledCandidates.count
            let message = Self.resultMessage(
                copiedFiles: copiedFiles,
                deletedFiles: deletedFiles,
                unsettledFiles: unsettledFiles
            )
            updateState(
                ruleID: rule.id,
                phase: .ready(message: message),
                copiedFiles: copiedFiles,
                deletedFiles: deletedFiles,
                lastRunAt: Date()
            )
            if copiedFiles > 0 || deletedFiles > 0 {
                UserNotifier.post(
                    title: "OBScene transfer complete",
                    body: Self.notificationResultMessage(
                        driveName: volume.name,
                        copiedFiles: copiedFiles,
                        deletedFiles: deletedFiles
                    )
                )
                ActivityLog.shared.log(
                    .fileTransferCompleted,
                    "\(rule.name): \(message)",
                    userVisible: true
                )
            } else {
                // NO-OP run: the destination already holds every settled recording
                // (or files are still being written). This is the COMMON case on a
                // plug-in edge and must stay SILENT — a user notification here was the
                // "Everything is already transferred and verified" spam Ethan hit on
                // every USB mount event. We log it (NOT user-visible) so the activity
                // feed still records the check, but never post a notification for a
                // no-op. Only an ACTUAL transfer (copied/deleted, above) or a real
                // error (catch block) notifies the user.
                let noopDetail = unsettledFiles > 0
                    ? "no finished recordings to copy yet (\(unsettledFiles) still being written)"
                    : "everything already transferred and verified"
                ActivityLog.shared.log(
                    .fileTransferCompleted,
                    "\(rule.name): \(noopDetail) — no changes, notification suppressed.",
                    userVisible: false
                )
            }
        } catch {
            let message = error.localizedDescription
            updateState(
                ruleID: rule.id,
                phase: .failed(message: message),
                lastRunAt: Date()
            )
            ActivityLog.shared.log(
                .fileTransferFailed,
                "\(rule.name): \(message)",
                userVisible: true
            )
            UserNotifier.post(
                title: "OBScene transfer needs attention",
                body: message
            )
        }
    }

    private func refreshWaitingStates() {
        let mountedUUIDs = Set(Self.mountedVolumes().map { $0.uuid })
        for rule in ConfigStore.shared.config.fileTransferRules {
            if !rule.isEnabled {
                updateState(ruleID: rule.id, phase: .disabled)
            } else if !mountedUUIDs.contains(rule.destinationVolumeUUID) {
                updateState(ruleID: rule.id, phase: .waitingForDrive)
            }
        }
    }

    private func updateState(ruleID: UUID,
                             phase: FileTransferPhase,
                             copiedFiles: Int = 0,
                             deletedFiles: Int = 0,
                             lastRunAt: Date? = nil) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let previous = self.states[ruleID]
            self.states[ruleID] = FileTransferRuleState(
                phase: phase,
                lastRunAt: lastRunAt ?? previous?.lastRunAt,
                copiedFiles: copiedFiles,
                deletedFiles: deletedFiles
            )
            NotificationCenter.default.post(name: .fileTransferStateChanged, object: self)
        }
    }

    private static func resultMessage(copiedFiles: Int,
                                      deletedFiles: Int,
                                      unsettledFiles: Int) -> String {
        var parts: [String] = []
        if copiedFiles > 0 { parts.append("\(copiedFiles) copied and verified") }
        if deletedFiles > 0 { parts.append("\(deletedFiles) laptop copies safely removed") }
        if unsettledFiles > 0 { parts.append("\(unsettledFiles) still being written") }
        return parts.isEmpty ? "Everything is safely backed up" : parts.joined(separator: ", ")
    }

    private static func notificationResultMessage(driveName: String,
                                                  copiedFiles: Int,
                                                  deletedFiles: Int) -> String {
        var parts: [String] = []
        if copiedFiles > 0 {
            parts.append("\(copiedFiles) file(s) copied and SHA-256 verified on \(driveName).")
        }
        if deletedFiles > 0 {
            parts.append("\(deletedFiles) retained laptop copy/copies were re-verified and removed.")
        }
        return parts.joined(separator: " ")
    }

    private static func loadManifest() -> FileTransferManifest {
        guard let data = try? Data(contentsOf: manifestFileURL),
              let decoded = try? JSONDecoder().decode(FileTransferManifest.self, from: data)
        else {
            return FileTransferManifest()
        }
        return decoded
    }

    private func saveManifest() throws {
        let url = Self.manifestFileURL
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: url, options: .atomic)
    }
}
