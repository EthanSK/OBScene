# Releasing OBScene

OBScene ships downloadable macOS artifacts via:

- [`.github/workflows/release.yml`](../.github/workflows/release.yml)
- GitHub Releases (universal DMG + ZIP + SHA-256 checksums + Sparkle-signed ZIP)
- The GitHub Pages landing page at <https://ethansk.github.io/OBScene/> (reads `site/version.json`)
- The Sparkle appcast feed at <https://ethansk.github.io/OBScene/appcast.xml> (reads `site/appcast.xml`)

The workflow mirrors the release flow used by `producer-player`, adapted for a native Swift project. Producer Player uses `electron-updater`; OBScene uses [Sparkle 2.x](https://sparkle-project.org/) because the app is a native Swift menu bar app rather than Electron. The conceptual flow (check feed URL, verify signature, replace, relaunch) is identical.

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
| Push to `main`/`master` | Workflow auto-bumps the minor version, commits it back with `[skip release]`, publishes `v<major>.<minor>` tag and release |
| Push commit containing `[skip release]` | Release workflow short-circuits (no build, no publish) — this is how the bump-back loop is prevented. The Pages workflow still runs, so the landing page updates to the new version. |
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
- Commit the bump to `main` with `chore: bump version to v1.3 [skip release]`
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
| `SPARKLE_ED_PRIVATE_KEY` | Base64 EdDSA private seed for signing Sparkle updates | `./Frameworks/bin/generate_keys --account obscene-sparkle -x /tmp/key`, then `cat /tmp/key`. Matching public key goes into `OBScene/Info.plist` as `SUPublicEDKey`. |

Once all seven are set, the next release run will produce a signed + notarised + stapled DMG and ZIP with no Gatekeeper warning, and a valid Sparkle appcast entry that existing installs can auto-update against.

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

- [`.github/workflows/release.yml`](../.github/workflows/release.yml) — build, sign, notarise, publish, sign update, update appcast
- [`.github/workflows/pages.yml`](../.github/workflows/pages.yml) — landing page deploy (runs `sync-version.sh`)
- [`scripts/build-app.sh`](../scripts/build-app.sh) — swiftc universal build + Sparkle embed + codesign
- [`scripts/package-release.sh`](../scripts/package-release.sh) — build + zip + DMG + notarise + staple
- [`scripts/sync-version.sh`](../scripts/sync-version.sh) — Info.plist → site/version.json
- [`scripts/bump-version.sh`](../scripts/bump-version.sh) — bump Info.plist + sync
- [`scripts/update-appcast.py`](../scripts/update-appcast.py) — maintain `site/appcast.xml` on each release

## Trigger sequencing

The "Simulate Display Connection" button and real display-trigger events both run through `DisplayMonitor.runTriggerActions()`. That function fires up to four OBS WebSocket requests in order — `SetCurrentSceneCollection`, `SetCurrentProfile`, `SetCurrentProgramScene`, then whichever of `StartRecord` / `StartStream` / `StartVirtualCam` / `StartReplayBuffer` the user enabled.

These are **not** independent. OBS applies scene collection and profile switches asynchronously on its side — `SetCurrentSceneCollection` reloads the entire scene list in the background, and setting a scene from the new collection immediately afterwards can silently fail because the new scene names haven't been indexed yet. Likewise, `StartRecord` issued before the profile switch has applied will use the old output path / encoder settings.

To avoid these races we sequence the steps with small fixed delays, defined as private constants near the top of `DisplayMonitor.swift`:

| Gap | Default | Purpose |
|---|---|---|
| `collectionToProfileDelay` | 500 ms | Let OBS finish reloading the scene list after switching scene collection before we switch profile. |
| `profileToSceneDelay` | 500 ms | Let the new profile's encoder/output settings apply before switching the active scene. |
| `sceneToActionsDelay` | 250 ms | Let the program scene settle before firing Start actions. |

The four start actions are fired in parallel — they don't interfere with each other.

If users report `SetCurrentProgramScene` silently failing or `StartRecord` using the wrong output settings, bump `collectionToProfileDelay` first (it guards the slowest OBS reload). There is no UI for these — they're intentionally hard-coded so that reliability doesn't depend on user configuration.

## How this differs from producer-player

Producer Player is an Electron app using `electron-builder` for multi-OS builds. OBScene is a native Swift menu bar app, so it:

- Uses `swiftc` + `lipo` directly instead of `electron-builder`
- Builds only macOS (Linux/Windows jobs would be meaningless)
- Imports the signing cert into a fresh keychain in CI (electron-builder does this internally)
- Uses `xcrun notarytool` directly (producer-player goes through electron-builder's `notarize.js` hook)
- Reads version from `Info.plist` rather than `package.json`
- Uses **Sparkle 2.x** for auto-updates instead of **electron-updater**

Everything else — the 3-job structure (`compute-version` → `build-mac` → `publish-release`), auto-bumped build tags, changelog generation, stable latest-download aliases, version.json on the landing page — mirrors producer-player's flow.

## Auto-updates (Sparkle)

OBScene ships with Sparkle 2.x vendored under [`Frameworks/Sparkle.framework`](../Frameworks/Sparkle.framework). The build script embeds the framework into `OBScene.app/Contents/Frameworks/`, the app links against it with an `@executable_path/../Frameworks` rpath, and `UpdaterManager` wires up `SPUStandardUpdaterController` on launch.

### Feed URL + schedule

Configured in [`OBScene/Info.plist`](../OBScene/Info.plist):

| Key | Value |
|---|---|
| `SUFeedURL` | `https://ethansk.github.io/OBScene/appcast.xml` |
| `SUPublicEDKey` | the public half of the EdDSA keypair (see below) |
| `SUEnableAutomaticChecks` | `YES` |
| `SUScheduledCheckInterval` | `86400` (24 hours) |
| `SUAutomaticallyUpdate` | `YES` (download in background, prompt to install) |

The app also fires an explicit background check ~9 seconds after launch (mirrors producer-player's `AUTO_UPDATE_CHECK_DELAY_MS`) so users see update prompts quickly on cold start.

### EdDSA signing keypair

Sparkle uses an EdDSA (ed25519) keypair to verify downloads. This is **separate** from the Apple Developer ID cert used for codesigning.

- **Public key** → hard-coded in `Info.plist` under `SUPublicEDKey`.
- **Private key** → stored as the `SPARKLE_ED_PRIVATE_KEY` GitHub secret.

To rotate the key:

```bash
# Generate a new keypair in your login keychain.
./Frameworks/bin/generate_keys --account obscene-sparkle

# Export the private key to a file (base64-encoded ed25519 seed).
./Frameworks/bin/generate_keys --account obscene-sparkle -x /tmp/obscene-sparkle-private.key
cat /tmp/obscene-sparkle-private.key
# → 22ZgWm4...=  (example)

# Paste into GitHub: Settings → Secrets → SPARKLE_ED_PRIVATE_KEY
gh secret set SPARKLE_ED_PRIVATE_KEY --body "$(cat /tmp/obscene-sparkle-private.key)"

# Update SUPublicEDKey in OBScene/Info.plist with the new public key
# (generate_keys prints it as a plist snippet when the key is first created).
```

Don't forget to wipe the old key file (`rm /tmp/obscene-sparkle-private.key`) after pasting.

### Release-side flow

On every push to `main`, the release workflow:

1. Builds `OBScene.app` with `Sparkle.framework` embedded + signed (inside-out, nested XPC services + Updater.app + framework + outer app).
2. Notarises the app + DMG + ZIP via `xcrun notarytool`.
3. Runs [`Frameworks/bin/sign_update`](../Frameworks/bin/sign_update) to compute the EdDSA signature of the stapled ZIP, using the private key piped in via stdin from `SPARKLE_ED_PRIVATE_KEY`.
4. Calls [`scripts/update-appcast.py`](../scripts/update-appcast.py) which prepends a new `<item>` to `site/appcast.xml` with the version, build number, signature, download URL, and release notes link.
5. Commits the updated `site/appcast.xml` back to `main` with a `[skip release]` subject so the release workflow doesn't re-trigger.
6. Publishes the GitHub Release with DMG + ZIP + checksums.
7. Dispatches the Pages workflow so `appcast.xml` + `version.json` are live within a minute or two.

### Vendored Sparkle

The Sparkle framework and its bin tools live under [`Frameworks/`](../Frameworks/) at the repo root:

```
Frameworks/
├── Sparkle.framework/         # embedded into OBScene.app/Contents/Frameworks
└── bin/
    ├── sign_update            # compute EdDSA signature for a ZIP
    └── generate_appcast       # not currently used; left for convenience
```

To upgrade Sparkle, download the latest tarball from <https://github.com/sparkle-project/Sparkle/releases>, extract, and replace `Frameworks/Sparkle.framework` + the `bin/` tools. Then rebuild and verify:

```bash
./scripts/build-app.sh
otool -L build/OBScene.app/Contents/MacOS/OBScene | grep Sparkle
# should print: @rpath/Sparkle.framework/Versions/B/Sparkle ...
```

### Appcast layout

`site/appcast.xml` is a standard [Sparkle 2 appcast](https://sparkle-project.org/documentation/publishing/). Example item:

```xml
<item>
  <title>OBScene v1.6</title>
  <pubDate>Sat, 11 Apr 2026 20:15:06 +0000</pubDate>
  <sparkle:version>10600</sparkle:version>
  <sparkle:shortVersionString>1.6.0</sparkle:shortVersionString>
  <sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>
  <sparkle:releaseNotesLink>https://github.com/EthanSK/OBScene/releases/tag/v1.6</sparkle:releaseNotesLink>
  <enclosure
    url="https://github.com/EthanSK/OBScene/releases/download/v1.6/OBScene-1.6.0-mac-universal.zip"
    length="2908871"
    type="application/octet-stream"
    sparkle:version="10600"
    sparkle:shortVersionString="1.6.0"
    sparkle:edSignature="EItZSJoFaYNMQizj…" />
</item>
```

`update-appcast.py` regenerates the file in place on each release and upserts by `sparkle:shortVersionString`, so re-runs of the same release don't duplicate entries.
