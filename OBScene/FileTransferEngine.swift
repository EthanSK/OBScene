import CryptoKit
import Foundation

/// Synchronous, filesystem-only transfer engine. The manager owns scheduling
/// and UI updates; keeping correctness here makes the destructive retention
/// behavior independently testable with temporary directories.
final class FileTransferEngine {
    static let settledFileAge: TimeInterval = 120

    struct Candidate: Equatable {
        let sourceURL: URL
        let relativePath: String
        let snapshot: FileTransferSnapshot
    }

    struct VerifiedCopy: Equatable {
        let sourceSnapshot: FileTransferSnapshot
        let sha256: String
    }

    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func candidates(in sourceFolder: URL) throws -> [Candidate] {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: sourceFolder.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            throw FileTransferError.sourceFolderMissing(sourceFolder.path)
        }

        let keys: [URLResourceKey] = [
            .isRegularFileKey,
            .fileSizeKey,
            .contentModificationDateKey,
        ]
        guard let enumerator = fileManager.enumerator(
            at: sourceFolder,
            includingPropertiesForKeys: keys,
            options: [.skipsPackageDescendants]
        ) else {
            throw FileTransferError.sourceFolderMissing(sourceFolder.path)
        }

        var result: [Candidate] = []
        for case let fileURL as URL in enumerator {
            let values = try fileURL.resourceValues(forKeys: Set(keys))
            guard values.isRegularFile == true else { continue }
            let relativePath = Self.relativePath(of: fileURL, under: sourceFolder)
            result.append(Candidate(
                sourceURL: fileURL,
                relativePath: relativePath,
                snapshot: try snapshot(of: fileURL)
            ))
        }
        return result.sorted { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
    }

    func isSettled(_ candidate: Candidate, now: Date) -> Bool {
        now.timeIntervalSince(candidate.snapshot.modificationDate) >= Self.settledFileAge
    }

    func destinationURL(for candidate: Candidate, destinationFolder: URL) -> URL {
        destinationFolder.appendingPathComponent(candidate.relativePath, isDirectory: false)
    }

    func destinationStillExists(for entry: FileTransferManifestEntry,
                                destinationURL: URL) -> Bool {
        guard let snapshot = try? snapshot(of: destinationURL) else { return false }
        return snapshot.byteCount == entry.sourceSnapshot.byteCount
    }

    /// Copy to a hidden sibling, ensure the source stayed unchanged, atomically
    /// promote the temporary file, then independently hash the final path.
    /// A failed verification never makes the source eligible for deletion.
    func copyAndVerify(candidate: Candidate,
                       destinationURL: URL,
                       ruleID: UUID) throws -> VerifiedCopy {
        try fileManager.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let temporaryName = ".\(destinationURL.lastPathComponent).obscene-partial-\(ruleID.uuidString)"
        let temporaryURL = destinationURL.deletingLastPathComponent()
            .appendingPathComponent(temporaryName, isDirectory: false)
        try? fileManager.removeItem(at: temporaryURL)
        guard fileManager.createFile(atPath: temporaryURL.path, contents: nil) else {
            throw FileTransferError.destinationFolderUnavailable(destinationURL.deletingLastPathComponent().path)
        }
        var shouldRemoveTemporaryFile = true
        defer {
            if shouldRemoveTemporaryFile {
                try? fileManager.removeItem(at: temporaryURL)
            }
        }

        let input = try FileHandle(forReadingFrom: candidate.sourceURL)
        let output = try FileHandle(forWritingTo: temporaryURL)
        var sourceHasher = SHA256()
        do {
            while let data = try input.read(upToCount: 4 * 1024 * 1024), !data.isEmpty {
                sourceHasher.update(data: data)
                try output.write(contentsOf: data)
            }
            try output.synchronize()
            try input.close()
            try output.close()
        } catch {
            try? input.close()
            try? output.close()
            throw error
        }

        let sourceAfterCopy = try snapshot(of: candidate.sourceURL)
        guard sourceAfterCopy == candidate.snapshot else { // Active recordings can grow during a copy; never promote that incomplete snapshot.
            throw FileTransferError.sourceChangedDuringCopy(candidate.sourceURL.lastPathComponent)
        }

        try fileManager.setAttributes(
            [.modificationDate: candidate.snapshot.modificationDate],
            ofItemAtPath: temporaryURL.path
        )
        if fileManager.fileExists(atPath: destinationURL.path) {
            _ = try fileManager.replaceItemAt(destinationURL, withItemAt: temporaryURL)
        } else {
            try fileManager.moveItem(at: temporaryURL, to: destinationURL)
        }
        shouldRemoveTemporaryFile = false

        let sourceHash = Self.hexDigest(sourceHasher.finalize())
        let destinationHash = try sha256(of: destinationURL)
        let destinationSnapshot = try snapshot(of: destinationURL)
        guard destinationSnapshot.byteCount == candidate.snapshot.byteCount,
              destinationHash == sourceHash
        else {
            throw FileTransferError.verificationFailed(candidate.sourceURL.lastPathComponent)
        }

        return VerifiedCopy(sourceSnapshot: candidate.snapshot, sha256: sourceHash)
    }

    /// Destructive gate: retention elapsed, both files still match the exact
    /// verified hash, and the source metadata still describes the transferred
    /// version. Callers may delete only when this returns true.
    func isSafeToDelete(candidate: Candidate,
                        destinationURL: URL,
                        manifestEntry: FileTransferManifestEntry,
                        retentionDays: Int,
                        now: Date) throws -> Bool {
        let retention = TimeInterval(retentionDays) * 24 * 60 * 60
        guard now.timeIntervalSince(manifestEntry.transferredAt) >= retention,
              candidate.snapshot == manifestEntry.sourceSnapshot,
              destinationStillExists(for: manifestEntry, destinationURL: destinationURL)
        else {
            return false
        }

        let sourceHash = try sha256(of: candidate.sourceURL)
        guard sourceHash == manifestEntry.sha256 else { return false }
        let destinationHash = try sha256(of: destinationURL)
        guard destinationHash == manifestEntry.sha256 else { return false }
        return try snapshot(of: candidate.sourceURL) == manifestEntry.sourceSnapshot
    }

    func deleteSource(_ candidate: Candidate) throws {
        try fileManager.removeItem(at: candidate.sourceURL)
    }

    func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 4 * 1024 * 1024), !data.isEmpty {
            hasher.update(data: data)
        }
        return Self.hexDigest(hasher.finalize())
    }

    func snapshot(of url: URL) throws -> FileTransferSnapshot {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        guard let fileSize = values.fileSize,
              let modificationDate = values.contentModificationDate
        else {
            throw FileTransferError.fileMetadataUnavailable(url.path)
        }
        return FileTransferSnapshot(byteCount: Int64(fileSize), modificationDate: modificationDate)
    }

    private static func relativePath(of fileURL: URL, under folderURL: URL) -> String {
        let folderComponents = folderURL.standardizedFileURL.pathComponents
        let fileComponents = fileURL.standardizedFileURL.pathComponents
        return fileComponents.dropFirst(folderComponents.count).joined(separator: "/")
    }

    private static func hexDigest<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
