import Foundation

/// One automatic, drive-triggered file-transfer setup. The destination is
/// identified by filesystem UUID rather than `/Volumes/<name>` so renaming a
/// drive (or macOS mounting it with a numeric suffix) cannot send recordings
/// to the wrong disk.
struct FileTransferRule: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    var name: String = "Recordings Backup"
    var isEnabled: Bool = true
    var sourceFolderPath: String = ""
    var destinationVolumeUUID: String = ""
    var destinationVolumeName: String = ""
    var destinationRelativePath: String = ""
    var retentionDays: Int = 7

    var sourceFolderURL: URL {
        URL(fileURLWithPath: sourceFolderPath, isDirectory: true)
    }

    var destinationDisplayPath: String {
        guard !destinationRelativePath.isEmpty else { return destinationVolumeName }
        return destinationVolumeName + "/" + destinationRelativePath
    }
}

struct FileTransferSnapshot: Codable, Equatable {
    let byteCount: Int64
    let modificationDate: Date
}

/// Durable proof of a completed copy. A source edit produces a different
/// snapshot and therefore forces a new verified transfer with a fresh
/// `transferredAt`, restarting the retention window.
struct FileTransferManifestEntry: Codable, Equatable, Identifiable {
    var id: String { ruleID.uuidString + ":" + relativePath }

    let ruleID: UUID
    let relativePath: String
    let sourceSnapshot: FileTransferSnapshot
    let sha256: String
    let transferredAt: Date
}

struct FileTransferManifest: Codable, Equatable {
    var entries: [FileTransferManifestEntry] = []

    func entry(ruleID: UUID, relativePath: String) -> FileTransferManifestEntry? {
        entries.first { $0.ruleID == ruleID && $0.relativePath == relativePath }
    }

    mutating func set(_ entry: FileTransferManifestEntry) {
        entries.removeAll { $0.ruleID == entry.ruleID && $0.relativePath == entry.relativePath }
        entries.append(entry)
    }
}

struct MountedTransferVolume: Equatable {
    let rootURL: URL
    let uuid: String
    let name: String
    let isInternal: Bool
}

enum FileTransferPhase: Equatable {
    case disabled
    case waitingForDrive
    case scanning
    case copying(fileName: String, completed: Int, total: Int)
    case verifying(fileName: String, completed: Int, total: Int)
    case ready(message: String)
    case failed(message: String)

    var label: String {
        switch self {
        case .disabled:
            return "Disabled"
        case .waitingForDrive:
            return "Waiting for drive"
        case .scanning:
            return "Checking for recordings…"
        case .copying(let fileName, let completed, let total):
            return "Copying \(fileName) (\(completed + 1) of \(total))"
        case .verifying(let fileName, let completed, let total):
            return "Verifying \(fileName) (\(completed + 1) of \(total))"
        case .ready(let message), .failed(let message):
            return message
        }
    }

    var isWorking: Bool {
        switch self {
        case .scanning, .copying, .verifying:
            return true
        case .disabled, .waitingForDrive, .ready, .failed:
            return false
        }
    }
}

struct FileTransferRuleState: Equatable {
    var phase: FileTransferPhase
    var lastRunAt: Date?
    var copiedFiles: Int
    var deletedFiles: Int

    static let waiting = FileTransferRuleState(
        phase: .waitingForDrive,
        lastRunAt: nil,
        copiedFiles: 0,
        deletedFiles: 0
    )
}

struct FileTransferRunResult: Equatable {
    let copiedFiles: Int
    let deletedFiles: Int
    let skippedUnsettledFiles: Int
}

enum FileTransferError: LocalizedError, Equatable {
    case sourceFolderMissing(String)
    case destinationFolderUnavailable(String)
    case invalidFolderSelection(String)
    case fileMetadataUnavailable(String)
    case sourceChangedDuringCopy(String)
    case verificationFailed(String)

    var errorDescription: String? {
        switch self {
        case .sourceFolderMissing(let path):
            return "Source folder is missing: \(path)"
        case .destinationFolderUnavailable(let path):
            return "Destination folder is unavailable: \(path)"
        case .invalidFolderSelection(let reason):
            return reason
        case .fileMetadataUnavailable(let path):
            return "Could not read file metadata: \(path)"
        case .sourceChangedDuringCopy(let name):
            return "\(name) changed while it was being copied. It was left on the laptop and will retry later."
        case .verificationFailed(let name):
            return "\(name) did not match after copying. The laptop copy was kept."
        }
    }
}
