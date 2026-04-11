# Releasing OBScene

OBScene ships downloadable macOS artifacts via:

- [`.github/workflows/release.yml`](../.github/workflows/release.yml)
- GitHub Releases (universal DMG + ZIP + SHA-256 checksums)
- The GitHub Pages landing page at <https://ethansk.github.io/OBScene/> (reads `site/version.json`)

The workflow mirrors the release flow used by `producer-player`, adapted for a native Swift project.

## Version source of truth

OBScene uses a **two-part display version** (mirrors producer-player):

- **Display:** `v1.0`, `v1.1`, `v2.0` — what users see on the landing page, GitHub release names, and the logo pill
- **Internal semver:** `1.0.0`, `1.1.0`, `2.0.0` — stored in `CFBundleShortVersionString` (patch is always `0`)
- **Build number:** `CFBundleVersion` = `major*10000 + minor*100` — a monotonically increasing integer

The single source of truth is `CFBundleShortVersionString` inside [`OBScene/Info.plist`](../OBScene/Info.plist). Every other label is derived from it.

### Automatic bumping on every push

The release workflow runs `./scripts/bump-version.sh minor` on every push to `main`, commits the bump back with `[skip ci]`, and then builds+signs+notarises+publishes the new `v<major>.<minor>` tag. You usually don't have to touch the version by hand.

### Manual bumping

```bash
./scripts/bump-version.sh           # minor bump: 1.0.0 -> 1.1.0 (display v1.1)
./scripts/bump-version.sh minor     # same as default
./scripts/bump-version.sh major     # major bump: 1.1.0 -> 2.0.0 (display v2.0)
./scripts/bump-version.sh set 2.5.0 # set an explicit x.y.0 version
```

`bump-version.sh` updates `CFBundleShortVersionString`, recalculates `CFBundleVersion`, and runs `sync-version.sh` automatically.

The release workflow fails fast if `site/version.json` is out of sync with `Info.plist`, so the check is enforced in CI.

## What the workflow publishes

Two universal macOS artifacts per release:

- `OBScene-<version>-mac-universal.dmg` — drag-to-Applications installer
- `OBScene-<version>-mac-universal.zip` — zipped `.app` (useful for scripted installers or auto-update)
- Matching `*.sha256` checksum files for each

The workflow also publishes stable "latest-download" aliases that always resolve to the most recent release, no matter the version:

- <https://github.com/EthanSK/OBScene/releases/latest/download/OBScene-latest-mac-universal.dmg>
- <https://github.com/EthanSK/OBScene/releases/latest/download/OBScene-latest-mac-universal.zip>

The landing page's Download button reads these from `site/version.json`.

## Release behavior by trigger

| Trigger | Result |
|---|---|
| Push to `main`/`master` | Workflow auto-bumps the minor version, commits it back with `[skip ci]`, publishes `v<major>.<minor>` tag and release |
| Push commit containing `[skip ci]` or `chore: bump version` | Workflow short-circuits (no build, no publish) — this is how the bump-back loop is prevented |
| Push tag `v*` | Builds and publishes that tag (must match `Info.plist` display version) |
| `workflow_dispatch` | Uses whatever version is already in `Info.plist`; does not bump |

## Typical release flow

Just push to main. Every push produces a new release.

```bash
git commit -am "feat: something"
git push origin main
```

The workflow will:

- Run `./scripts/bump-version.sh minor` (e.g. `1.2.0 -> 1.3.0`, display `v1.3`)
- Commit the bump to `main` with `chore: bump version to v1.3 [skip ci]`
- Build a universal `.app` with `swiftc` (arm64 + x86_64 via `lipo`)
- Sign with Developer ID (or ad-hoc fall-back)
- Notarise + staple via `notarytool` (if Apple credentials are configured)
- Create the DMG via `hdiutil`
- Publish the GitHub Release (`OBScene v1.3`) with both artifacts + SHA-256 sums
- Update the stable `OBScene-latest-mac-universal.{dmg,zip}` aliases

Confirm the download button on the landing page now shows the new version: <https://ethansk.github.io/OBScene/>. The Pages workflow re-runs automatically when `site/version.json` changes.

## GitHub Actions secrets

The workflow runs in two modes depending on which secrets are configured.

### Unsigned (ad-hoc) mode — default, no secrets required

With no secrets set, the workflow still builds, packages, and publishes the release. The `.app` inside the DMG is ad-hoc signed, so users will see a Gatekeeper warning on first launch ("Apple could not verify…"). This is fine for early testers and keeps the workflow green before Apple credentials are available.

### Signed + notarised mode — full release

Add these repository secrets under **Settings → Secrets and variables → Actions**:

| Secret | What it is | How to get it |
|---|---|---|
| `APPLE_CERTIFICATE_P12_BASE64` | Base64-encoded Developer ID Application `.p12` | Export from Keychain Access: select the "Developer ID Application" cert + its private key, File → Export → `cert.p12`, then `base64 -i cert.p12 \| pbcopy` |
| `APPLE_CERTIFICATE_PASSWORD` | Password you chose when exporting the `.p12` | — |
| `APPLE_DEVELOPER_ID` | Full signing identity string, e.g. `Developer ID Application: Ethan Sarif-Kattan (T34G959ZG8)` | `security find-identity -v -p codesigning \| grep "Developer ID Application"` |
| `APPLE_ID` | Apple ID email used for notarisation | — |
| `APPLE_TEAM_ID` | 10-character Team ID | <https://developer.apple.com/account> → Membership |
| `APPLE_APP_PASSWORD` | App-specific password for `notarytool` | <https://account.apple.com> → Sign-In and Security → App-Specific Passwords |

Once all six are set, the next release run will produce a signed + notarised + stapled DMG and ZIP with no Gatekeeper warning.

### Quick helper — export the cert locally

From a machine that already has the Developer ID cert in its login keychain:

```bash
# 1. Find the identity
security find-identity -v -p codesigning | grep "Developer ID Application"

# 2. Export the cert + key to a p12 (Keychain Access UI is easiest:
#    Keychain Access → login → Certificates → right-click the cert → Export →
#    choose .p12, set a strong password).
#
# 3. Base64 it for copy/paste into the GitHub secret:
base64 -i cert.p12 | pbcopy
```

Then paste into `APPLE_CERTIFICATE_P12_BASE64` and the password into `APPLE_CERTIFICATE_PASSWORD`.

## Local signed builds

If you already have the Developer ID cert in your login keychain you can do a full signed + notarised build locally without touching GitHub:

```bash
export APPLE_DEVELOPER_ID="Developer ID Application: Ethan Sarif-Kattan (T34G959ZG8)"
export APPLE_ID="you@example.com"
export APPLE_TEAM_ID="T34G959ZG8"
export APPLE_APP_PASSWORD="xxxx-xxxx-xxxx-xxxx"

./scripts/package-release.sh
```

Artifacts land in `build/`.

Or, if you only want to test the signing step without Apple notarisation:

```bash
SIGN_IDENTITY="Developer ID Application: Ethan Sarif-Kattan (T34G959ZG8)" \
  ./scripts/build-app.sh
```

## Workflow files

- [`.github/workflows/release.yml`](../.github/workflows/release.yml) — build, sign, notarise, publish
- [`.github/workflows/pages.yml`](../.github/workflows/pages.yml) — landing page deploy (runs `sync-version.sh`)
- [`scripts/build-app.sh`](../scripts/build-app.sh) — swiftc universal build + codesign
- [`scripts/package-release.sh`](../scripts/package-release.sh) — build + zip + DMG + notarise + staple
- [`scripts/sync-version.sh`](../scripts/sync-version.sh) — Info.plist → site/version.json
- [`scripts/bump-version.sh`](../scripts/bump-version.sh) — bump Info.plist + sync

## How this differs from producer-player

Producer Player is an Electron app using `electron-builder` for multi-OS builds. OBScene is a native Swift menu bar app, so it:

- Uses `swiftc` + `lipo` directly instead of `electron-builder`
- Builds only macOS (Linux/Windows jobs would be meaningless)
- Imports the signing cert into a fresh keychain in CI (electron-builder does this internally)
- Uses `xcrun notarytool` directly (producer-player goes through electron-builder's `notarize.js` hook)
- Reads version from `Info.plist` rather than `package.json`

Everything else — the 3-job structure (`compute-version` → `build-mac` → `publish-release`), auto-bumped build tags, changelog generation, stable latest-download aliases, version.json on the landing page — mirrors producer-player's flow.
