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
import Darwin

enum ScriptRunner {

    /// Path to the per-profile script run log. Opened lazily, appended to.
    /// Lives in `~/Library/Logs/OBScene/script-runs.log` so it shows up in
    /// Console.app under "~/Library/Logs" alongside other app-specific logs.
    ///
    /// Exposed `internal` so the Settings UI ("Open Logs" button) can hand
    /// the same URL off to `NSWorkspace.open` without duplicating the path
    /// derivation. The file may not exist until the first script run; callers
    /// that surface this in the UI should ensure the directory + an empty
    /// file exist via `ensureLogFileExists()` before opening.
    static var logFileURL: URL {
        let logs = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("OBScene", isDirectory: true)
        return logs.appendingPathComponent("script-runs.log", isDirectory: false)
    }

    /// Best-effort: make sure the log directory and an empty log file both
    /// exist on disk so `NSWorkspace.open` has something to hand to the
    /// user's default `.log` editor. No-op when the file already exists.
    /// Errors are intentionally swallowed — this is a UX nicety, not a
    /// correctness path; the run-time logging codepath also creates the
    /// file lazily inside `run(...)`.
    static func ensureLogFileExists() {
        let url = logFileURL
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
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

    /// Outcome of a `runAndWait` invocation. Distinct from `Process.TerminationStatus`
    /// because we need to surface launch-failures and timeouts as first-class
    /// values: callers (specifically the run-script-before-restart path) want
    /// to log + proceed in all three cases without inspecting an `Error`.
    enum RunOutcome {
        /// Process exited normally; integer is the exit status (0 = success).
        case exited(status: Int32)
        /// Process exited from an uncaught signal; integer is the signal.
        case signalled(signal: Int32)
        /// We never managed to launch the process at all (e.g. shell binary
        /// missing). The string carries `Error.localizedDescription`.
        case failedToLaunch(reason: String)
        /// The wait exceeded the caller's timeout. The Process is left running
        /// (orphaned to launchd, same fire-and-forget model as `run`) so the
        /// user's script still finishes its work; the OBScene flow proceeds
        /// without waiting any longer.
        case timedOut
    }

    /// Launches `script` detached under a login bash. No-op if `script` is
    /// empty / whitespace. `profileName` is included in every log line so the
    /// user can tell which profile fired which script when multiple are
    /// configured. Must be called on the main thread (callers today are on
    /// the main thread from DisplayMonitor's trigger pipeline).
    static func run(script: String, profileName: String) {
        // The fire-and-forget variant is a thin wrapper over `runAndWait` —
        // we just don't observe the completion. Keeping the wrapper preserves
        // every existing call-site (the after-restart path, the no-restart
        // path, and the legacy "script only" path) without forcing them to
        // care about the new completion handler.
        _ = runAndWait(
            script: script,
            profileName: profileName,
            timeout: nil,
            completion: nil
        )
    }

    /// Variant that observes the underlying Process to completion. Returns the
    /// launched `Process` (or `nil` for empty script / launch failure) so the
    /// caller can keep a reference if it wants to poll/cancel; the primary
    /// completion signal is the `completion` closure.
    ///
    /// Timing semantics:
    ///   - `completion` fires exactly once on the main queue, with one of the
    ///     `RunOutcome` cases.
    ///   - If `timeout` is non-nil and elapses before the process exits, we
    ///     fire `completion(.timedOut)` and STOP observing the process — the
    ///     child keeps running in the background (re-parented to launchd if
    ///     OBScene quits later) so the user's script side effects still land.
    ///     We do NOT SIGTERM/SIGKILL the child: the run-script-before-restart
    ///     caller wants the script's work to finish even if OBScene moves on.
    ///   - If `timeout` is nil, we wait forever for the process to exit. This
    ///     is what the legacy `run(script:profileName:)` path effectively does
    ///     (it just doesn't observe the completion).
    ///
    /// `completion: nil` matches the legacy fire-and-forget behaviour — the
    /// process runs detached and nobody waits for it.
    @discardableResult
    static func runAndWait(script: String,
                           profileName: String,
                           timeout: TimeInterval?,
                           completion: ((RunOutcome) -> Void)?) -> Process? {
        let trimmed = script.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            // Honour the contract: completion fires exactly once. An empty
            // script is "trivially exited 0" from the caller's perspective.
            if let completion = completion {
                DispatchQueue.main.async { completion(.exited(status: 0)) }
            }
            return nil
        }

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

        // Latch for the completion handler. `terminationHandler` and the
        // timeout closure (if a timeout was set) both race to fire it; we
        // ensure exactly one wins. Captured by reference (NSObject lock) so
        // both closures see the same state.
        let completionLatch = CompletionLatch(completion: completion)

        // When the process ends, tear down the readability handlers and
        // close the pipe FDs so the termination thread can exit cleanly.
        //
        // Fix #5 — handler ordering / FD-leak prevention:
        // Previously, `terminationHandler` fired the completion latch and
        // then called `readDataToEndOfFile()` on each pipe. When the
        // user's script spawned a background grandchild that inherited
        // stdout/stderr (e.g. `daemon-thing &`), the pipe write-ends
        // stayed open for the lifetime of that grandchild, so EOF never
        // arrived and `readDataToEndOfFile()` blocked forever on
        // Foundation's termination thread. The readability handlers were
        // only cleared AFTER those blocking reads, so each daemonising
        // script leaked one termination thread, two FileHandles, and two
        // readability handlers.
        //
        // New order:
        //   1. Fire completion latch so the caller proceeds.
        //   2. Clear readability handlers FIRST so Foundation stops
        //      delivering more chunks via the dispatch source.
        //   3. Best-effort nonblocking drain of anything that's already
        //      buffered. We never call `readDataToEndOfFile()` or
        //      `availableData` here; both can block on the grandchild's
        //      lingering write-end.
        //   4. Close the FileHandles. This drops our read-end; the
        //      grandchild keeps the write-end; any later write sees
        //      SIGPIPE / EPIPE. Tail output beyond what's buffered is
        //      intentionally truncated; the alternative (block forever)
        //      was strictly worse.
        process.terminationHandler = { proc in
            // (1) Surface the exit to the caller before we touch any
            // pipe state — the latch is the user-visible contract.
            let status = proc.terminationStatus
            let outcome: RunOutcome = (proc.terminationReason == .uncaughtSignal)
                ? .signalled(signal: status)
                : .exited(status: status)
            completionLatch.fire(outcome)

            let reason: String
            switch proc.terminationReason {
            case .exit: reason = "exit"
            case .uncaughtSignal: reason = "signal"
            @unknown default: reason = "unknown"
            }
            let footer = "[\(Self.isoFormatter.string(from: Date()))] profile=\"\(tag)\" finished: status=\(status) reason=\(reason)\n"
            Self.appendToLog(footer)

            // (2) Clear handlers BEFORE any read so Foundation stops
            // pushing more data and the dispatch sources backing the
            // handlers can be torn down.
            let outHandle = outPipe.fileHandleForReading
            let errHandle = errPipe.fileHandleForReading
            outHandle.readabilityHandler = nil
            errHandle.readabilityHandler = nil

            // (3) Nonblocking drain — pull whatever's already in the
            // kernel buffer, but never wait for EOF. `FileHandle`'s
            // `availableData` is not safe here: outside a readability
            // callback it may block until data or EOF, which is exactly
            // the hang this cleanup path is avoiding.
            //
            // We tolerate truncation once the pipe is empty at this
            // instant. If a grandchild writes after we close below, it
            // will see SIGPIPE / EPIPE.
            func drain(_ handle: FileHandle, stream: String) {
                let fd = handle.fileDescriptor
                let originalFlags = fcntl(fd, F_GETFL)
                guard originalFlags >= 0 else { return }
                guard fcntl(fd, F_SETFL, originalFlags | O_NONBLOCK) >= 0 else { return }
                defer {
                    _ = fcntl(fd, F_SETFL, originalFlags)
                }

                var buffer = [UInt8](repeating: 0, count: 16 * 1024)
                while true {
                    let bytesRead = buffer.withUnsafeMutableBytes { rawBuffer -> Int in
                        guard let baseAddress = rawBuffer.baseAddress else { return 0 }
                        return Darwin.read(fd, baseAddress, rawBuffer.count)
                    }

                    if bytesRead > 0 {
                        let chunk = Data(buffer[0..<bytesRead])
                        Self.appendToLog(Self.format(tag: tag, stream: stream, data: chunk))
                        continue
                    }
                    if bytesRead == 0 { break }
                    if errno == EINTR { continue }
                    if errno == EAGAIN || errno == EWOULDBLOCK { break }
                    break
                }
            }
            drain(outHandle, stream: "stdout")
            drain(errHandle, stream: "stderr")

            // (4) Drop our read-end. If a grandchild still holds the
            // write-end, kernel will SIGPIPE its next write; that's the
            // documented detached-grandchild contract — nothing for us
            // to clean up further.
            try? outHandle.close()
            try? errHandle.close()
        }

        do {
            try process.run()
        } catch {
            let msg = "[\(Self.isoFormatter.string(from: Date()))] profile=\"\(tag)\" failed to launch: \(error.localizedDescription)\n"
            Self.appendToLog(msg)
            // Mirror Fix #5 cleanup order: clear handlers first, then
            // close the FDs so we never leak file descriptors when the
            // shell binary is missing or exec fails. terminationHandler
            // never fires in this path, so we own the cleanup.
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            try? outPipe.fileHandleForReading.close()
            try? errPipe.fileHandleForReading.close()
            // The process never started; notify the caller directly.
            completionLatch.fire(.failedToLaunch(reason: error.localizedDescription))
            return nil
        }

        // If the caller asked for a timeout, schedule a side-channel that
        // fires `.timedOut` after the deadline. The completion latch is
        // one-shot, so this is a no-op if the process already exited
        // cleanly (terminationHandler will have already fired). We
        // deliberately do NOT terminate the child — the user wants the
        // script to keep working in the background even if OBScene moves
        // on to the next pipeline step (mirrors the long-standing
        // fire-and-forget contract for grandchildren).
        //
        // Note: do NOT gate this on `process.isRunning`. If the script's
        // shell exited but a background grandchild keeps the stdout pipe
        // open, `terminationHandler` blocks in `readDataToEndOfFile()`
        // and `isRunning` returns false — gating would skip the timeout,
        // leaving the caller waiting forever. The latch's one-shot
        // semantics make the unconditional fire safe.
        if let timeout = timeout {
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
                completionLatch.fire(.timedOut)
            }
        }

        // Deliberately do NOT `waitUntilExit()` — the process runs detached
        // from the main app's lifecycle. If OBScene quits while a script is
        // still running, the child will be orphaned (re-parented to launchd)
        // and will continue until it exits naturally, which is the desired
        // behaviour for long-lived post-trigger tasks.
        return process
    }

    /// One-shot latch around the optional `RunOutcome` completion handler.
    /// `terminationHandler` and the timeout side-channel both race to call
    /// `fire(_:)`; only the first call propagates. Subsequent calls are
    /// no-ops so a delayed exit after a timeout never double-fires the
    /// caller. Wraps the closure in an NSObject lock because the two
    /// closures may run on arbitrary background queues (Foundation's
    /// `terminationHandler` is documented as such).
    private final class CompletionLatch {
        private var completion: ((RunOutcome) -> Void)?
        private let lock = NSLock()

        init(completion: ((RunOutcome) -> Void)?) {
            self.completion = completion
        }

        func fire(_ outcome: RunOutcome) {
            lock.lock()
            let observer = completion
            completion = nil
            lock.unlock()
            guard let observer = observer else { return }
            // Always hop to main so callers can update UI / mutate non-thread-
            // safe state without an extra dispatch.
            DispatchQueue.main.async { observer(outcome) }
        }
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
