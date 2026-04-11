# Releasing OBScene

OBScene ships downloadable macOS artifacts via:

- [`.github/workflows/release.yml`](../.github/workflows/release.yml)
- GitHub Releases (universal DMG + ZIP + SHA-256 checksums)
- The GitHub Pages landing page at <https://ethansk.github.io/OBScene/> (reads `site/version.json`)

The workflow mirrors the release flow used by `producer-player`, adapted for a native Swift project.

## Version source of truth

The single source of truth for the semantic version is `CFBundleShortVersionString` inside [`OBScene/Info.plist`](../OBScene/Info.plist). Every other version label (landing page, GitHub release name, artifact filenames) is derived from this value.

After changing the version, regenerate `site/version.json`:

```bash
./scripts/sync-version.sh
```

Or do both in one step:

```bash
./scripts/bump-version.sh patch   # 1.0.0 -> 1.0.1
./scripts/bump-version.sh minor   # 1.0.1 -> 1.1.0
./scripts/bump-version.sh major   # 1.1.0 -> 2.0.0
./scripts/bump-version.sh set 1.2.3
```

`bump-version.sh` updates `CFBundleShortVersionString`, recalculates `CFBundleVersion` (the integer build number), and runs `sync-version.sh` automatically.

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
| Push to `main`/`master` with a new `CFBundleShortVersionString` | Publishes canonical `v<version>` tag and release |
| Push to `main`/`master` with the same version already released | Publishes `v<version>-build.<run_number>` |
| Push tag `v*` | Builds and publishes that tag (must match `Info.plist` version) |
| `workflow_dispatch` | Builds artifacts; publish step only runs on `main`/`master` |

## Typical release flow

1. Bump the version:

   ```bash
   ./scripts/bump-version.sh patch
   ```

2. Commit and push:

   ```bash
   git add OBScene/Info.plist site/version.json
   git commit -m "chore: bump version to $(./scripts/sync-version.sh >/dev/null && plutil -extract CFBundleShortVersionString raw OBScene/Info.plist)"
   git push origin main
   ```

3. Watch the **Release** workflow at <https://github.com/EthanSK/OBScene/actions/workflows/release.yml>. It will:
   - Build a universal `.app` with `swiftc` (arm64 + x86_64 via `lipo`)
   - Sign with Developer ID (or ad-hoc fall-back)
   - Notarise + staple via `notarytool` (if Apple credentials are configured)
   - Create the DMG via `hdiutil`
   - Publish the GitHub Release with both artifacts + SHA-256 sums
   - Update the stable `OBScene-latest-mac-universal.{dmg,zip}` aliases

4. Confirm the download button on the landing page now shows the new version: <https://ethansk.github.io/OBScene/>. The Pages workflow re-runs automatically when `site/version.json` changes.

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
