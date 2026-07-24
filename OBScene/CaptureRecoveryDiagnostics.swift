import Foundation

/// Seven-day, local-only diagnostics for macOS Screen Capture recovery.
///
/// Each recovery event is appended as one JSON object under
/// `~/Library/Logs/OBScene/capture-recovery/YYYY-MM-DD.ndjson`. The log stores
/// trigger/result metadata only—never screenshots, OBS credentials, or source
/// settings—and removes diagnostic files older than seven full days.
final class CaptureRecoveryDiagnostics {
    static let shared = CaptureRecoveryDiagnostics()
    static let retentionInterval: TimeInterval = 7 * 24 * 60 * 60
    static var logDirectoryURL: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("OBScene", isDirectory: true)
            .appendingPathComponent("capture-recovery", isDirectory: true)
    }

    struct Event: Encodable {
        let timestamp: String
        let event: String
        let reason: String?
        let inputName: String?
        let responseCode: Int?
        let success: Bool?
        let details: [String: String]?
    }

    private let fileManager: FileManager
    private let directoryURL: URL
    private let queue = DispatchQueue(
        label: "com.ethansk.OBScene.CaptureRecoveryDiagnostics.file"
    )

    private static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let filenameFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private init(
        fileManager: FileManager = .default,
        directoryURL: URL? = nil
    ) {
        self.fileManager = fileManager
        self.directoryURL = directoryURL ?? Self.logDirectoryURL
    }

    func record(
        _ event: String,
        reason: String? = nil,
        inputName: String? = nil,
        responseCode: Int? = nil,
        success: Bool? = nil,
        details: [String: String] = [:]
    ) {
        let now = Date()
        let entry = Event(
            timestamp: Self.timestampFormatter.string(from: now),
            event: event,
            reason: reason,
            inputName: inputName,
            responseCode: responseCode,
            success: success,
            details: details.isEmpty ? nil : details
        )

        queue.async { [fileManager, directoryURL] in
            do {
                try fileManager.createDirectory(
                    at: directoryURL,
                    withIntermediateDirectories: true
                )
                try Self.removeExpiredLogs(
                    in: directoryURL,
                    now: now,
                    fileManager: fileManager
                )

                let filename = "\(Self.filenameFormatter.string(from: now)).ndjson"
                let logURL = directoryURL.appendingPathComponent(filename)
                var data = try Self.encoder.encode(entry)
                data.append(0x0A)

                if !fileManager.fileExists(atPath: logURL.path) {
                    fileManager.createFile(atPath: logURL.path, contents: nil)
                }
                let handle = try FileHandle(forWritingTo: logURL)
                defer { try? handle.close() }
                _ = try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } catch {
                // Diagnostics must never block or fail the capture-recovery path.
            }
        }
    }

    static func removeExpiredLogs(
        in directoryURL: URL,
        now: Date,
        fileManager: FileManager = .default
    ) throws {
        let cutoff = now.addingTimeInterval(-retentionInterval)
        let files = try fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )

        for fileURL in files where fileURL.pathExtension == "ndjson" {
            let values = try fileURL.resourceValues(
                forKeys: [.contentModificationDateKey]
            )
            guard let modifiedAt = values.contentModificationDate,
                  modifiedAt < cutoff else {
                continue
            }
            try fileManager.removeItem(at: fileURL)
        }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()
}
