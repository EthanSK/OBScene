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
**Date:** 2026-07-11T14:48:08Z
**Trigger:** 2026-07-11 task: 'plug-in didn't switch to right scene' (later retracted by Ethan as expected behavior)
**Symptom:** OBScene 'plugged in and it didn't change to the right scene' — dock connect appeared to switch OBS to the wrong scene (coffee shop coding instead of 3000AD)
**Root cause:** NOT A BUG. Dock plug-in correctly fired the display-plug-in profile and switched to 3000AD (14:27 log verified). The later 'coffee shop coding' switch was Ethan manually plugging in his public USB flash drive, which correctly fired the USB-plug-in profile. Two separate, correct trigger firings — expected behavior.
**Fix:** No code change. Do NOT add trigger-conflict / display-vs-USB precedence / debounce / suppression logic. Dock auto-switch works; a USB-drive plug firing the USB profile is intended.
**Commit:** none
**Guard:** This LEARNINGS entry — stops future agents chasing a phantom scene-switch bug in DisplayMonitor/USBMonitor/VerifiedSetEngine.
---

