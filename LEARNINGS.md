# Learnings

Per-repo institutional memory for fixes. Every entry below is a real bug we hit + how we solved it. Check this file BEFORE attempting a same-looking fix.

Maintained by the `learnings` skill — see `~/.claude/skills/learnings/skill.md`.

## Format

Each entry looks like:

```
---
**Date:** YYYY-MM-DDTHH:MM:SSZ
**Trigger:** <voice N / message snippet / null>
**Symptom:** <what was visible>
**Root cause:** <what we actually found>
**Fix:** <file:line + short prose + commit SHA>
**Guard:** <test / lint / watchdog / comment that prevents regression — or 'none'>
---
```

## Entries

(newest first)

---
**Date:** 2026-07-21T14:21:04Z
**Trigger:** 2026-07-21 task: investigate why the Mac commonly runs out of memory and fix OBScene without changing file-transfer behavior
**Symptom:** macOS Jetsam snapshots caught installed OBScene 1.54.0 at about 26 GiB resident with a 31 GiB lifetime peak during automatic recording retention verification; the same process returned to 36 MiB after the pass, but system compression and swap pressure restarted other development apps.
**Root cause:** `FileTransferEngine` read every 4 MiB `FileHandle` chunk in one long-lived autorelease scope. Large copy and SHA-256 passes therefore retained temporary Foundation `Data` backing storage until the whole pass ended. The seven-day cleanup path hashes both the laptop and backup copy, so roughly 13.8 GiB of newly eligible recordings could create about 27.6 GiB of temporary allocation, matching the captured peak.
**Fix:** Added one shared `forEachChunk` helper in `FileTransferEngine.swift`. It keeps the existing 4 MiB streaming, hashing, atomic copy, verification, retention, and deletion behavior, but wraps each read plus its consumer in an `autoreleasepool` so temporary chunk storage is released before the next read. Both copy and standalone hash paths now use the same helper.
**Commit:** none
**Guard:** The normal file-transfer test now crosses the 4 MiB chunk boundary. Set `OBSCENE_RUN_MEMORY_REGRESSION=1` when running `obscene-file-transfer-tests` to hash a 2 GiB sparse recording; the release worktree passed with 36,159,488 bytes maximum RSS and 25,068,096 bytes peak footprint instead of memory growing with file size.
---

---
**Date:** 2026-07-12T00:05:00Z
**Trigger:** 2026-07-12 task: file-transfer keeps firing "everything is already transferred and verified" decently often
**Symptom:** OBScene file-transfer over-triggered — repeated "Everything is already transferred and verified" notifications, without plugging in anything new.
**Root cause:** `FileTransferManager.startMonitoring()` registered `NSWorkspace.didMountNotification` → `requestScan(reason: .driveMounted)` with NO check that the mounted volume was the rule's destination drive and NO edge detection. A dock connect emits a BURST of mount events; unrelated USB drives / disk images / network shares also fire `didMount`. With the backup drive already connected, every one of these re-ran the scan, found nothing new, and hit the no-op notification branch (`else if reason == .driveMounted || .manual`) → spam.
**Fix:** Edge-only + debounced trigger in `FileTransferManager.swift`. Added `lastKnownMountedUUIDs` (seeded at launch); mount AND unmount now funnel through `handleMountChange()`, which fires a rule ONLY on a NOT-connected → connected rising edge of its `destinationVolumeUUID`. `connectSettleDelay` (3s) coalesces the dock burst; `reTriggerGuardInterval` (30s) swallows unplug→replug bounce so one physical connection = one run. The no-op branch is now log-only (`ActivityLog … userVisible:false`) instead of `UserNotifier.post` — only an actual transfer or a real error notifies. UI wording in `FileTransferSettingsView.swift` now states "Runs once when <drive> is plugged in (on connect)".
**Commit:** (branch fix/file-transfer-edge-trigger — see PR)
**Guard:** Thorough inline comments at the trigger site (edge + debounce rationale) + this entry. The no-op path can never notify again (log-only). Do NOT revert to scanning on every `didMount` — that is the spam.
---

---
**Date:** 2026-07-11T14:48:08Z
**Trigger:** 2026-07-11 task: 'plug-in didn't switch to right scene' (later retracted by Ethan as expected behavior)
**Symptom:** OBScene 'plugged in and it didn't change to the right scene' — dock connect appeared to switch OBS to the wrong scene (coffee shop coding instead of 3000AD)
**Root cause:** NOT A BUG. Dock plug-in correctly fired the display-plug-in profile and switched to 3000AD (14:27 log verified). The later 'coffee shop coding' switch was Ethan manually plugging in his public USB flash drive, which correctly fired the USB-plug-in profile. Two separate, correct trigger firings — expected behavior.
**Fix:** No code change. Do NOT add trigger-conflict / display-vs-USB precedence / debounce / suppression logic. Dock auto-switch works; a USB-drive plug firing the USB profile is intended.
**Commit:** none
**Guard:** This LEARNINGS entry — stops future agents chasing a phantom scene-switch bug in DisplayMonitor/USBMonitor/VerifiedSetEngine.
---
