# OBScene Project Instructions

## UI visual QA

- Any change to SwiftUI layout, text, control sizing or placement, profile tabs, menus, or Settings presentation must be built and screenshot-tested before commit and release.
- Use OBScene's isolated offscreen renderer for Settings QA so tests never rewrite the user's persisted profiles.
- Render and inspect Settings at 640, 760, and 980 points wide. The 640-point render covers the minimum window, 760 covers the two-column boundary, and 980 covers the default window.
- When practical, reproduce a reported window width before the fix and capture the same width afterward.
- Explicitly inspect every screenshot for character-by-character wrapping, truncation, overlap, clipped controls, inaccessible actions, and horizontal or vertical overflow. A successful build or unit test is not visual proof.
- Interactive UI changes such as drag and drop require focused state/ordering tests in addition to screenshots. Use manual interaction testing when it can be done without disturbing the user's live Mac; screenshots alone do not prove interaction behavior.

The Settings renderer accepts these environment variables:

```sh
OBSCENE_RENDER_SETTINGS=/tmp/obscene-settings.png \
OBSCENE_RENDER_SETTINGS_WIDTH=640 \
OBSCENE_RENDER_SETTINGS_HEIGHT=1200 \
build/OBScene.app/Contents/MacOS/OBScene
```
