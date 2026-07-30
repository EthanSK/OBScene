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
**Date:** 2026-07-30T12:02:33Z
**Trigger:** User asked for a menu-bar command to refresh macOS capture manually while automatic capture recovery remains disabled
**Symptom:** The safe native `reactivate_capture` transaction existed only behind automatic wake, display-connect, and recording-start triggers. After those triggers were disabled, there was no user-invoked recovery path in the menu-bar dropdown.
**Root cause:** `AppDelegate.setupMenuBar()` exposed OBS reconnect and file-transfer commands but did not expose `OBSWebSocketManager.reactivateStoppedMacOSScreenCaptures(reason:)`.
**Fix:** Add **Refresh macOS Capture Source** beside the OBS commands. Enable it only while OBS WebSocket is connected and route clicks through the existing serialized native-only recovery gate with reason `manual menu bar refresh`. Manual invocation intentionally bypasses the automatic-recovery preference but never changes capture-source settings. Mirror the row in `MenuBarDropdownMockupView`. Default automatic recovery to off for missing/legacy configuration keys so fresh installs and upgrades never opt in implicitly.
**Guard:** AppConfig tests must prove missing recovery preferences default off while an explicit opt-in decodes and round-trips. The full focused test suite, Debug app build, source audit, and offscreen menu render must pass. Keep automatic recovery disabled in persisted user configuration; this command is the explicit one-shot replacement.
---

---
**Date:** 2026-07-27T12:04:00Z
**Trigger:** User opened the MacBook lid and the stopped macOS Screen Capture did not reactivate, then requested the same recovery whenever recording starts
**Symptom:** The native-only recovery installed on 2026-07-26 ran after an external display connection only. Opening the lid produced `NSWorkspace.didWakeNotification` but no capture-recovery schedule, and starting an OBS recording could not trigger recovery because OBScene subscribed to output events but ignored every obs-websocket Event message (`op` 5).
**Root cause:** The prior safety narrowing deliberately removed wake recovery while eliminating the unsafe `show_cursor` rebuild, and OBScene's WebSocket message switch had no event handler. The safe native Reactivate Capture transaction existed, but neither missing trigger fed it.
**Fix:** System wake/lid-open now schedules one native recovery after a ten-second ScreenCaptureKit settle window. An exact `RecordStateChanged` event with `outputState == OBS_WEBSOCKET_OUTPUT_STARTED` schedules one native recovery after one second. Display-connect, wake, and recording-start own independent pending work so repeated callbacks replace only the same trigger; the existing serial gate still prevents OBS operations from overlapping. Success notifications are trigger-neutral, Settings documents all three schedules, and no source setting is changed.
**Guard:** The focused test proves `[10]` display, `[10]` wake, and `[1]` recording-start schedules and rejects starting-state or non-record events. All five test binaries, an unsigned Xcode Debug build, the Developer ID-signed universal build, `git diff --check`, and the source audit pass. The signed v1.56.0 local app was installed and reconnected while OBS PID 67170 remained unchanged; the persisted recovery toggle is enabled, OBScene stayed healthy, and reconnect emitted no recovery transaction. Real lid-open and real recording-start notifications remain manual verification boundaries because sleeping the Mac or starting a recording was not performed automatically. Never simulate those events by controlling the UI, and never restore the `show_cursor`/`SetInputSettings` rebuild path.
---

---
**Date:** 2026-07-26T21:13:08Z
**Trigger:** User rejected the `show_cursor` toggle/restore fallback after OBS beachballed during automated capture recovery
**Symptom:** Capture recovery could run immediately and repeatedly on wake, display add/remove callbacks, settled scene selections, and WebSocket reconnects. When OBS returned 604 for a black source, the fallback changed `show_cursor` twice to force ScreenCaptureKit teardown/recreation, even though that setting was unrelated to the requested recovery action.
**Root cause:** OBScene treated source-setting mutation as an implicit restart API and had too many automatic trigger surfaces. Even serialized, the fallback deliberately caused two ScreenCaptureKit rebuilds and could disturb OBS while the display topology was still settling.
**Fix:** Capture recovery now runs only when the external-display count increases. Each additional display connection restarts one ten-second settle window; display removal cancels it. OBScene then presses OBS's native `reactivate_capture` property button once per macOS Screen Capture input, waits one second to verify frames after a successful press, and sends a macOS notification for success, already-active, unavailable, missing-source, connection, and request-failure outcomes. Code 604 is reported and inspected read-only; recovery never changes capture-source settings. Wake-time profile/collection/scene reconciliation remains but no longer refreshes capture, and scene-selection plus WebSocket-reconnect capture triggers were removed.
**Guard:** `scripts/test-macos-capture-recovery.swift` proves the only capture schedule is `[10]`, native outcomes remain classified, inputs and transactions stay serial, and frame/placement diagnostics remain read-only. Source audit finds no `show_cursor`, `SetInputSettings`, forced-reinitialize flag, wake trigger, scene-selection trigger, or reconnect trigger in the capture-recovery path. All five test binaries, the unsigned Debug app build, and `git diff --check` pass. A Developer ID-signed local replacement was installed over v1.56 while OBS recorded: OBScene relaunched from `/Applications`, its reconnect emitted no capture-recovery event, the OBS PID stayed unchanged, and the active recording continued growing. A physical display connection and its notification remain a manual verification boundary. Do not reintroduce a settings-based capture rebuild without explicit user approval and live OBS/ScreenCaptureKit safety evidence.
---

---
**Date:** 2026-07-26T19:24:00Z
**Trigger:** OBS beachballed during display/capture recovery and the macOS Screen Capture feed appeared black
**Symptom:** OBScene diagnostics showed display-change recovery attempts starting one second apart, overlapping for 3.3–4.3 seconds, and then reporting `capture_reinitialized` immediately after two `SetInputSettings` acknowledgements. The user saw an OBS rainbow wheel and a black capture feed.
**Root cause:** The retry schedule bounded when attempts were submitted but did not serialize the complete asynchronous recovery transactions. A second `reactivate_capture` probe could therefore run while the first probe or a settings-driven ScreenCaptureKit rebuild was still in flight. The forced fallback also restored `show_cursor` immediately after toggling it and treated WebSocket code 100 as proof of recovery even though macOS content-sharing telemetry showed no corresponding stream stop/start. This proves an unsafe recovery race and false-positive success reporting; because no recovery attempt was logged at the exact time of the later beachball, it does not prove that this path caused every OBS stall.
**Fix:** Serialize full capture-recovery transactions through a single-flight gate and coalesce trigger churn into at most one pending request. Treat 604 as ambiguous: inspect a 160-pixel source screenshot first, skip rebuilding a visibly non-black source, and only permit the final wake/display attempt to rebuild a black or unavailable frame. During a forced rebuild, leave two seconds between the `show_cursor` toggle and restore, wait one more second for the restored stream, and verify the resulting frame before logging success. Diagnostics record actual request/start/finish timing, coalescing, response codes, dimensions, brightness ratios, and SHA-256 only—never screenshot pixels or source settings.
**Guard:** Unit tests prove recovery submissions never overlap, coalesced requests preserve all reasons and the strongest final-force requirement, black/cursor-only frames are rejected, and visible frames are accepted. The full unit suite and an unsigned Xcode Debug build pass. In a live OBS 32.2.0 recording, the manual serialized sequence kept OBS responsive and preserved recording plus `show_cursor`; macOS logged a distinct stream stop/start for both settings changes, and non-black before/after source screenshots had different hashes.
---

---
**Date:** 2026-07-24T13:51:18Z
**Trigger:** Follow-up request to restore the previously disabled Custom Browser Dock behavior without hiding it in profile scripts
**Symptom:** The safe standalone `restore-obs-browser-docks` helper still existed at its reversible disabled path, but every OBScene profile command was clean and there was no visible way to opt back into dock restoration.
**Root cause:** The old integration appended `&& restore-obs-browser-docks` to profile `runScript` strings before the verified OBS selection pipeline. That made the Accessibility side effect hard to discover and could invoke it while OBS was still launching or restarting.
**Fix:** Add the persisted **Restore missing Custom Browser Docks after profile changes** setting under Wake & Display Recovery. When enabled, OBScene invokes the existing one-shot helper only after its connected profile/scene-collection/scene pipeline settles. The UI names the exact `set channels` and `chat` targets, states that the behavior restores visibility rather than page content, and opens the seven-day dock diagnostics. Keep legacy profile commands free of dock suffixes.
**Guard:** AppConfig tests prove the setting defaults off for upgrades and an explicit enabled value decodes and round-trips. The standalone helper passes Bash 3.2 syntax, embedded AppleScript compilation, fake one-shot execution, overlap-skip/lock-release, structured-log, and retention tests; the personal dock skill validates. The full OBScene unit suite, Release build, and offscreen Settings render pass.
---

---
**Date:** 2026-07-24T13:36:26Z
**Trigger:** Follow-up objection that OBScene's new wake/display capture recovery must not be hidden behavior
**Symptom:** Automatic ScreenCaptureKit repair and wake-time OBS selection reconciliation were enabled globally but had no visible control or explanation in OBScene.
**Root cause:** The recovery was implemented as internal event handling rather than as a persisted user-facing preference.
**Fix:** Add a dedicated Settings → Wake & Display Recovery group. Its enabled-by-default toggle gates display-change recovery, wake recovery, wake-time profile/scene reconciliation, and WebSocket-reconnect recovery; turning it off does not disable normal configured display profiles. The group states the bounded 0/1-second display and 0/2-second wake schedule and opens the seven-day diagnostics directory.
**Guard:** AppConfig tests prove legacy configs default to enabled and an explicit disabled value decodes and round-trips. Every delayed recovery attempt checks the current setting again, so disabling it while a retry is pending suppresses that retry. The full unit suite, Release build, and offscreen Settings render pass.
---

---
**Date:** 2026-07-24T13:13:49Z
**Trigger:** Follow-up request to re-enable the disabled OBS Lua capture restarter with self-cleaning logs for future diagnosis
**Symptom:** The old `obs-macos-capture-restarter.lua` had successfully restarted capture twice on 2026-07-22 but later threw `FILE* expected, got string`; there was no durable, focused recovery history to distinguish a missed trigger, disabled-button 604, successful reactivation, or forced rebuild.
**Root cause:** Re-enabling the Lua would duplicate OBScene's new event-driven recovery and let two independent systems race over the same ScreenCaptureKit source. The evidence does not establish that the Lua crashed OBS: the verified OBS 32.2.0 crash in this task came from the separate `GetInputPropertiesListPropertyItems` WebSocket request.
**Fix:** Keep the Lua disabled and record structured recovery events from the owning OBScene implementation. `CaptureRecoveryDiagnostics.swift` writes trigger topology, attempts, WebSocket result codes, reactivation outcomes, and forced-rebuild results to daily `~/Library/Logs/OBScene/capture-recovery/YYYY-MM-DD.ndjson` files. It never stores screenshots, source settings, or credentials and deletes only `.ndjson` files older than seven full days.
**Guard:** The capture-recovery test suite proves eight-day-old diagnostics are deleted, recent and exactly-seven-day files remain, and unrelated files are untouched. The full unit suite and Xcode Release build pass. Keep the Lua file and all registrations disabled unless OBScene recovery is deliberately removed first.
---

---
**Date:** 2026-07-24T12:40:29Z
**Trigger:** 2026-07-24 task: macOS Screen Capture froze after unplugging displays and closing/reopening the MacBook lid; OBS could also wake with its profile switched but its scene collection left behind
**Symptom:** OBS logged `Stream stopped as no capture source was not found` five seconds before Clamshell Sleep and left the `macOS Screen Capture` input stopped after wake. A prior sleep had also interrupted OBScene after the profile verified but before the scene-collection switch verified.
**Root cause:** ScreenCaptureKit stops a built-in-display stream when the lid removes that display, and OBS does not automatically reactivate it when the display returns. The disabled Lua restarter was both broken (`FILE* expected, got string`) and only reacted to an OBS properties update; OBScene had no `NSWorkspace.didWakeNotification` reconciliation, and its WebSocket can remain connected through sleep, so reconnect-only handling cannot cover this state. OBS error 604 means only that `reactivate_capture` is disabled: OBS 32.2.0 can also return 604 while a missing-display target remains black, so 604 is not proof that frames are healthy.
**Fix:** Commit `df537357ba48` adds event-driven OBScene recovery after wake, display changes, settled scene selection, and WebSocket reconnect. It lists only `screen_capture` inputs and presses OBS's `reactivate_capture` property; success 100 recovers a stopped stream. Wake also reapplies only the last automatic display profile's OBS profile/collection/scene selections, without replaying scripts or output actions. Commit `87daf3d90a89` handles the black-with-604 case on the final bounded wake/display attempt by toggling `show_cursor` and restoring its original value, forcing OBS to rebuild ScreenCaptureKit without changing the selected display or the user's saved cursor preference.
**Guard:** `scripts/test-macos-capture-recovery.swift` covers stopped success, disabled-button 604, disconnected/no-input no-ops, unexpected failure, the bounded immediate retry schedule, and which triggers may force the final rebuild. The full unit suite, universal CLI build, and Xcode Release build pass. Live OBS 32.2.0 verification first reproduced the misleading state (`reactivate_capture` returned 604 and `GetSourceScreenshot` returned 702), then manually drove the same `show_cursor` toggle/restore sequence as the automatic fallback: both settings updates returned 100, source screenshots succeeded, contained non-black pixels, and produced different hashes one second apart. A screenshot/hash check is still required before calling any 604 result healthy. Do not query `GetInputPropertiesListPropertyItems` for the macOS Screen Capture display property: OBS 32.2.0 crashed with `EXC_BAD_ACCESS` during that request on 2026-07-24. Use the verified-safe `GetInputSettings`, `SetInputSettings`, `GetSourceScreenshot`, `PressInputPropertiesButton`, and profile/scene-collection requests instead.
---

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
