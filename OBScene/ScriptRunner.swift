//
// ScriptRunner.swift — per-profile "Run on activate" shell hook.
//
// When a TriggerProfile with a non-empty `runScript` fires, we launch the
// script detached via `/bin/bash -l -c <script>` so the main app never blocks
// on it. Stdout and stderr are tee'd (via a Pipe + timestamped write) to
// `~/Library/Logs/OBScene/script-runs.log` so the user can audit what ran
// without needing to attach a debugger.
//
// Security note: this executes arbitrary shell supplied by the user via the
// Settings UI. It is an intentional power-user escape hatch (e.g. invoking
// `restream-channel-switch` or similar external CLI tools on profile change)
// rather than a sandboxed API. The login shell (`-l`) is used so the command
// sees the user's usual PATH / aliases from ~/.zprofile, ~/.bash_profile etc.
//

import Foundation

enum ScriptRunner {

    /// Path to the per-profile script run log. Opened lazily, appended to.
    /// Lives in `~/Library/Logs/OBScene/script-runs.log` so it shows up in
    /// Console.app under "~/Library/Logs" alongside other app-specific logs.
    private static var logFileURL: URL {
        let logs = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("OBScene", isDirectory: true)
        return logs.appendingPathComponent("script-runs.log", isDirectory: false)
    }

    /// Serial queue for log-file appends. `Pipe` callbacks may arrive on
    /// multiple background threads for the same Process, and different
    /// profiles' scripts may fire concurrently — funnelling every write
    /// through a single queue keeps the log file legible.
    private static let logQueue = DispatchQueue(label: "com.ethansk.OBScene.ScriptRunner.log")

    /// ISO8601 formatter used to timestamp each log line. Initialised once
    /// because `ISO8601DateFormatter` setup is non-trivial.
    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Launches `script` detached under a login bash. No-op if `script` is
    /// empty / whitespace. `profileName` is included in every log line so the
    /// user can tell which profile fired which script when multiple are
    /// configured. Must be called on the main thread (callers today are on
    /// the main thread from DisplayMonitor's trigger pipeline).
    static func run(script: String, profileName: String) {
        let trimmed = script.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Make sure the log directory exists before we try to open the log
        // stream. Harmless if the directory is already there.
        let logURL = logFileURL
        try? FileManager.default.createDirectory(
            at: logURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }

        let header = "[\(Self.isoFormatter.string(from: Date()))] profile=\"\(profileName)\" starting: \(trimmed)\n"
        Self.appendToLog(header)

        // Use the user's login shell so PATH/aliases from ~/.zprofile,
        // ~/.bash_profile, etc. are loaded the same way an interactive
        // terminal would see them. macOS sets `SHELL` to the login shell
        // from /etc/passwd (commonly /bin/zsh on modern macOS); only fall
        // back to /bin/bash if SHELL is unset or points at a missing binary.
        let loginShell: String = {
            let candidate = ProcessInfo.processInfo.environment["SHELL"] ?? ""
            if !candidate.isEmpty, FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
            return "/bin/bash"
        }()

        let process = Process()
        process.launchPath = loginShell
        // `-l` = login shell (so PATH / ~/.zprofile-style setup is loaded),
        // `-c` = run the string and exit. Both zsh and bash accept these
        // flags with the same semantics, which is why SHELL-vs-bash is a
        // drop-in swap here.
        process.arguments = ["-l", "-c", trimmed]

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        // No stdin — scripts run non-interactively.
        process.standardInput = FileHandle.nullDevice

        // Stream stdout and stderr to the log file as chunks arrive. We do
        // NOT buffer the entire script output in memory; long-running scripts
        // (e.g. a `tail -f`) would blow up otherwise. Each chunk is prefixed
        // with the profile name so interleaved output from concurrent scripts
        // remains attributable.
        let tag = profileName
        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { return }
            Self.appendToLog(Self.format(tag: tag, stream: "stdout", data: data))
        }
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { return }
            Self.appendToLog(Self.format(tag: tag, stream: "stderr", data: data))
        }

        // When the process ends, tear down the readability handlers so the
        // Pipe file descriptors can be closed and a completion line is logged.
        process.terminationHandler = { proc in
            // Drain any remaining buffered output.
            let remainingOut = outPipe.fileHandleForReading.readDataToEndOfFile()
            if !remainingOut.isEmpty {
                Self.appendToLog(Self.format(tag: tag, stream: "stdout", data: remainingOut))
            }
            let remainingErr = errPipe.fileHandleForReading.readDataToEndOfFile()
            if !remainingErr.isEmpty {
                Self.appendToLog(Self.format(tag: tag, stream: "stderr", data: remainingErr))
            }
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil

            let status = proc.terminationStatus
            let reason: String
            switch proc.terminationReason {
            case .exit: reason = "exit"
            case .uncaughtSignal: reason = "signal"
            @unknown default: reason = "unknown"
            }
            let footer = "[\(Self.isoFormatter.string(from: Date()))] profile=\"\(tag)\" finished: status=\(status) reason=\(reason)\n"
            Self.appendToLog(footer)
        }

        do {
            try process.run()
        } catch {
            let msg = "[\(Self.isoFormatter.string(from: Date()))] profile=\"\(tag)\" failed to launch: \(error.localizedDescription)\n"
            Self.appendToLog(msg)
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
        }
        // Deliberately do NOT `waitUntilExit()` — the process runs detached
        // from the main app's lifecycle. If OBScene quits while a script is
        // still running, the child will be orphaned (re-parented to launchd)
        // and will continue until it exits naturally, which is the desired
        // behaviour for long-lived post-trigger tasks.
    }

    /// Format a chunk of output for the log file. Strips trailing newlines so
    /// each logical output line gets its own prefixed log line instead of a
    /// dangling empty one.
    private static func format(tag: String, stream: String, data: Data) -> String {
        let text = String(data: data, encoding: .utf8) ?? "<non-utf8 \(data.count) bytes>"
        let ts = Self.isoFormatter.string(from: Date())
        // Attach the prefix to every line so we don't get ambiguous output
        // when two scripts run concurrently.
        return text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.isEmpty ? "" : "[\(ts)] profile=\"\(tag)\" \(stream): \($0)" }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
            .appending("\n")
    }

    /// Append a string to the script-runs log. Always runs on `logQueue` so
    /// multiple scripts interleave safely. Opens + closes the file handle
    /// per-append so we never hold a dangling FD across app lifetime.
    private static func appendToLog(_ line: String) {
        let url = Self.logFileURL
        Self.logQueue.async {
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                // Fall back to a plain append if FileHandle can't be opened
                // (e.g. directory was deleted mid-session).
                _ = try? data.write(to: url, options: .atomic)
            }
        }
    }
}
