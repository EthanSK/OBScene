import SwiftUI
import AppKit

/// A SwiftUI facsimile of the real OBScene menu bar dropdown, used only by
/// the README + landing page screenshots. Rendered offscreen via
/// `NSHostingView` + `cacheDisplay` when the app is launched with
/// `OBSCENE_RENDER_MENU=<path>`.
///
/// Why not screenshot the real NSMenu? NSMenu isn't an NSWindow — it's a
/// system-owned overlay that `screencapture -l <windowID>` can't target, and
/// scripting its opening via AppleScript while capturing the full screen
/// leaves us at the mercy of menu timing + screen resolution. A SwiftUI
/// facsimile is pixel-perfect, reproducible in CI, and stays in sync with
/// the real menu because it literally lists the same items in the same
/// order. The only risk is that we forget to update this when we change
/// `AppDelegate.setupMenuBar()` — if you add/remove menu items there,
/// mirror the change here too.
struct MenuBarDropdownMockupView: View {
    var body: some View {
        ZStack(alignment: .top) {
            // Dark translucent background, roughly matching the real menu
            // chrome on macOS Sonoma+ in dark mode. We paint the blur tint
            // directly rather than using NSVisualEffectView because the
            // offscreen render path doesn't composite visual-effect views
            // the way a live window does.
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(red: 0.13, green: 0.13, blue: 0.14))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
                )
                .shadow(color: Color.black.opacity(0.5), radius: 20, x: 0, y: 10)

            VStack(alignment: .leading, spacing: 0) {
                menuBarChrome

                menuContent
                    .padding(.vertical, 4)
            }
        }
        .frame(width: 280)
        .padding(16)
        .background(Color.clear)
    }

    /// The menu-bar icon strip above the dropdown — mimics the row of
    /// status items on the right side of the macOS menu bar. Shows the
    /// OBScene `display.2` icon highlighted as if clicked.
    private var menuBarChrome: some View {
        HStack(spacing: 14) {
            Spacer()
            Image(systemName: "wifi")
                .foregroundColor(Color.white.opacity(0.75))
            Image(systemName: "battery.75percent")
                .foregroundColor(Color.white.opacity(0.75))
            Image(systemName: "display.2")
                .foregroundColor(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.white.opacity(0.18))
                )
            Text("9:41")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(Color.white.opacity(0.9))
        }
        .font(.system(size: 13))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(Color.black.opacity(0.25))
        .clipShape(
            UnevenRoundedRectangle(
                topLeadingRadius: 10,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: 0,
                topTrailingRadius: 10,
                style: .continuous
            )
        )
    }

    /// The list of menu items. Order and labels match
    /// `AppDelegate.setupMenuBar()` exactly.
    private var menuContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerRow(title: "OBScene", bold: true)
            statusRow(icon: "circle.fill",
                      iconColor: .green,
                      text: "OBS: Connected")
            statusRow(icon: "film",
                      iconColor: .white.opacity(0.75),
                      text: "Scene: Docked Stream")
            statusRow(icon: "display.2",
                      iconColor: .white.opacity(0.75),
                      text: "Displays: 1 / 1 external (ready)")
            statusRow(icon: "bolt.fill",
                      iconColor: .yellow,
                      text: "Trigger actions: Record + Replay Buffer")
            statusRow(icon: "clock",
                      iconColor: .white.opacity(0.75),
                      text: "Last trigger: Today, 9:39:14 AM")

            separator

            actionRow(title: "Settings…", shortcut: "⌘,", highlighted: true)
            actionRow(title: "Reconnect to OBS", shortcut: "⌘R")

            separator

            actionRow(title: "About OBScene", shortcut: nil)
            actionRow(title: "Check for Updates…", shortcut: nil)
            actionRow(title: "OBScene on GitHub", shortcut: nil)

            separator

            actionRow(title: "Quit OBScene", shortcut: "⌘Q")
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
    }

    // MARK: - Row primitives

    private func headerRow(title: String, bold: Bool) -> some View {
        Text(title)
            .font(.system(size: 12, weight: bold ? .bold : .regular))
            .foregroundColor(Color.white.opacity(0.55))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
    }

    private func statusRow(icon: String, iconColor: Color, text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .frame(width: 14, alignment: .center)
                .foregroundColor(iconColor)
            Text(text)
                .foregroundColor(Color.white.opacity(0.9))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .font(.system(size: 13))
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }

    private func actionRow(title: String, shortcut: String?, highlighted: Bool = false) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .foregroundColor(highlighted ? .white : Color.white.opacity(0.92))
            Spacer(minLength: 12)
            if let shortcut = shortcut {
                Text(shortcut)
                    .font(.system(size: 12))
                    .foregroundColor(highlighted ? Color.white.opacity(0.85) : Color.white.opacity(0.55))
            }
        }
        .font(.system(size: 13))
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(highlighted ? Color.accentColor : Color.clear)
        )
    }

    private var separator: some View {
        Rectangle()
            .fill(Color.white.opacity(0.12))
            .frame(height: 1)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
    }
}
