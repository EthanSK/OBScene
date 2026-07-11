import Foundation

private enum TestFailure: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case .failed(let message): return message
        }
    }
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw TestFailure.failed(message) }
}

@main
struct FileTransferEngineTests {
    static func main() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("obscene-file-transfer-tests-\(UUID().uuidString)", isDirectory: true)
        let source = root.appendingPathComponent("source", isDirectory: true)
        let destination = root.appendingPathComponent("destination", isDirectory: true)
        try fileManager.createDirectory(at: source, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let recording = source
            .appendingPathComponent("Session One", isDirectory: true)
            .appendingPathComponent("recording.mov", isDirectory: false)
        try fileManager.createDirectory(
            at: recording.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let originalData = Data("verified recording payload".utf8)
        try originalData.write(to: recording)
        let oldDate = Date(timeIntervalSinceNow: -600)
        try fileManager.setAttributes([.modificationDate: oldDate], ofItemAtPath: recording.path)

        let engine = FileTransferEngine(fileManager: fileManager)
        let candidates = try engine.candidates(in: source)
        try expect(candidates.count == 1, "expected one recursively discovered recording")
        let candidate = candidates[0]
        try expect(candidate.relativePath == "Session One/recording.mov", "relative path was not preserved")
        try expect(engine.isSettled(candidate, now: Date()), "old recording should be settled")

        let destinationURL = engine.destinationURL(for: candidate, destinationFolder: destination)
        let ruleID = UUID()
        let verified = try engine.copyAndVerify(
            candidate: candidate,
            destinationURL: destinationURL,
            ruleID: ruleID
        )
        let copiedData = try Data(contentsOf: destinationURL)
        let sourceHash = try engine.sha256(of: recording)
        try expect(copiedData == originalData, "destination bytes differ after verified copy")
        try expect(verified.sha256 == sourceHash, "manifest hash differs from source")

        let transferredAt = Date()
        let entry = FileTransferManifestEntry(
            ruleID: ruleID,
            relativePath: candidate.relativePath,
            sourceSnapshot: verified.sourceSnapshot,
            sha256: verified.sha256,
            transferredAt: transferredAt
        )
        let safeBeforeRetention = try engine.isSafeToDelete(
            candidate: candidate,
            destinationURL: destinationURL,
            manifestEntry: entry,
            retentionDays: 7,
            now: transferredAt.addingTimeInterval(6 * 24 * 60 * 60)
        )
        try expect(
            !safeBeforeRetention,
            "source became deletable before seven full days"
        )
        let safeAfterRetention = try engine.isSafeToDelete(
            candidate: candidate,
            destinationURL: destinationURL,
            manifestEntry: entry,
            retentionDays: 7,
            now: transferredAt.addingTimeInterval(8 * 24 * 60 * 60)
        )
        try expect(
            safeAfterRetention,
            "matching source and destination should be deletable after retention"
        )

        try Data("tampered destination payload".utf8).write(to: destinationURL)
        let safeAfterTamper = try engine.isSafeToDelete(
            candidate: candidate,
            destinationURL: destinationURL,
            manifestEntry: entry,
            retentionDays: 7,
            now: transferredAt.addingTimeInterval(8 * 24 * 60 * 60)
        )
        try expect(
            !safeAfterTamper,
            "tampered destination must block deletion"
        )
        try expect(fileManager.fileExists(atPath: recording.path), "failed verification touched the source")

        _ = try engine.copyAndVerify(
            candidate: candidate,
            destinationURL: destinationURL,
            ruleID: ruleID
        )
        try Data(repeating: 0x78, count: originalData.count).write(to: recording)
        try fileManager.setAttributes([.modificationDate: oldDate], ofItemAtPath: recording.path)
        let safeAfterUndetectableSourceEdit = try engine.isSafeToDelete(
            candidate: candidate,
            destinationURL: destinationURL,
            manifestEntry: entry,
            retentionDays: 7,
            now: transferredAt.addingTimeInterval(8 * 24 * 60 * 60)
        )
        try expect(
            !safeAfterUndetectableSourceEdit,
            "same-size source edit with restored timestamp must still block deletion"
        )

        try originalData.write(to: recording)
        try fileManager.setAttributes([.modificationDate: oldDate], ofItemAtPath: recording.path)
        let safeAfterRestore = try engine.isSafeToDelete(
            candidate: candidate,
            destinationURL: destinationURL,
            manifestEntry: entry,
            retentionDays: 7,
            now: transferredAt.addingTimeInterval(8 * 24 * 60 * 60)
        )
        try expect(
            safeAfterRestore,
            "restored verified destination should pass the destructive gate"
        )
        try engine.deleteSource(candidate)
        try expect(!fileManager.fileExists(atPath: recording.path), "safe deletion did not remove the source")

        print("FileTransferEngine tests passed")
    }
}
