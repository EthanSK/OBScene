import SwiftUI

/// Compact status pill rendering the current `OBSConnectionState` from
/// `OBSWebSocketManager`. Three states:
///
///   - `.connected`     → green dot + "Connected"
///   - `.retrying`      → yellow dot + "Retrying in Ns…" countdown +
///                        "Reconnect now" button
///   - `.disconnected`  → red dot + "Disconnected" (optionally with error) +
///                        "Reconnect now" button
///   - `.idle`          → gray dot + "Not configured"
///
/// Clicking the pill itself also triggers an immediate reconnect — matches
/// the "small Reconnect now button (or make the pill clickable)" requirement.
struct OBSConnectionStatusPill: View {
    @ObservedObject var obsManager: OBSWebSocketManager

    /// Drives the live countdown in the `.retrying` state. We tick once per
    /// second — the retry window is at most 60s so the 1Hz refresh rate is
    /// both enough to feel live and cheap. Using TimelineView here keeps the
    /// tick local to the pill and doesn't force the whole settings view to
    /// redraw every second.
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0)) { context in
            pill(at: context.date)
        }
    }

    @ViewBuilder
    private func pill(at now: Date) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(dotColor)
                .frame(width: 8, height: 8)

            Text(label(at: now))
                .font(.caption)
                .foregroundColor(textColor)
                .lineLimit(1)
                .truncationMode(.tail)

            if showReconnectButton {
                Button {
                    obsManager.reconnectNow()
                } label: {
                    Text("Reconnect now")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .help("Reconnect to OBS immediately and reset the backoff timer.")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            Capsule(style: .continuous)
                .fill(backgroundColor)
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(borderColor, lineWidth: 0.5)
        )
        .contentShape(Capsule(style: .continuous))
        .onTapGesture {
            // Whole-pill tap also triggers an immediate reconnect (except
            // in idle — nothing to reconnect to yet).
            if case .idle = obsManager.connectionState { return }
            obsManager.reconnectNow()
        }
        .help(helpText(at: now))
    }

    // MARK: - State-derived rendering

    private var dotColor: Color {
        switch obsManager.connectionState {
        case .connected:      return .green
        case .retrying:       return .yellow
        case .disconnected:   return .red
        case .idle:           return .gray
        }
    }

    private var textColor: Color {
        switch obsManager.connectionState {
        case .connected, .idle: return .secondary
        case .retrying:         return Color.orange
        case .disconnected:     return .red
        }
    }

    private var backgroundColor: Color {
        switch obsManager.connectionState {
        case .connected:    return Color.green.opacity(0.12)
        case .retrying:     return Color.yellow.opacity(0.15)
        case .disconnected: return Color.red.opacity(0.12)
        case .idle:         return Color.gray.opacity(0.10)
        }
    }

    private var borderColor: Color {
        switch obsManager.connectionState {
        case .connected:    return Color.green.opacity(0.35)
        case .retrying:     return Color.yellow.opacity(0.45)
        case .disconnected: return Color.red.opacity(0.35)
        case .idle:         return Color.gray.opacity(0.25)
        }
    }

    private var showReconnectButton: Bool {
        switch obsManager.connectionState {
        case .connected, .idle: return false
        case .retrying, .disconnected: return true
        }
    }

    private func label(at now: Date) -> String {
        switch obsManager.connectionState {
        case .connected:
            return "Connected"
        case .idle:
            return "Not configured"
        case .retrying(let nextAttemptAt, _):
            let remaining = max(0, Int(ceil(nextAttemptAt.timeIntervalSince(now))))
            if remaining <= 0 {
                return "Reconnecting…"
            }
            return "Retrying in \(remaining)s…"
        case .disconnected(let message):
            if let message = message, !message.isEmpty {
                return "Disconnected: \(truncated(message, limit: 60))"
            }
            return "Disconnected"
        }
    }

    private func helpText(at now: Date) -> String {
        switch obsManager.connectionState {
        case .connected:
            return "Connected to OBS. Click to reconnect."
        case .idle:
            return "Enter host/port/password below and click Connect."
        case .retrying(let nextAttemptAt, let delay):
            let remaining = max(0, Int(ceil(nextAttemptAt.timeIntervalSince(now))))
            return "Next reconnect attempt in \(remaining)s (backoff \(Int(delay))s). Click to retry now."
        case .disconnected(let message):
            if let message = message, !message.isEmpty {
                return "Not connected — \(message). Click to retry now."
            }
            return "Not connected. Click to retry now."
        }
    }

    private func truncated(_ s: String, limit: Int) -> String {
        if s.count <= limit { return s }
        return String(s.prefix(limit - 1)) + "…"
    }
}
