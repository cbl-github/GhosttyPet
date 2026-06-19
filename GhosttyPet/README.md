# GhosttyPet

A tiny macOS desktop pet: a pixel-art ghost inspired by Ghostty, rendered as crisp blocky cells.

## Build

```sh
make -C GhosttyPet
```

## Run

```sh
open GhosttyPet/build/GhosttyPet.app
```

## Controls

- Drag with the left mouse button.
- Quit with right-click.
- Quit with Escape when the pet has focus.

## Notes

The ghost is drawn as a 14x14 pixel grid of square cells (`NSRectFill`, antialiasing off for crisp edges), with four animated faces — `>-`, `>>`, `@@`, `--` — plus a gentle bounce and scale pulse. The app uses native Objective-C/AppKit only. It does not use Electron, WebView, AVFoundation playback, or image frame atlases — the pixels are computed, not loaded from a bitmap.

Performance notes:

- Only the eyes animate, so the body is stored **once** (`kGhostBody`) and only the three face rows vary between frames (`kGhostFaces`) — no duplicated frame copies.
- Each repaint groups cells by color and emits just three `NSRectFillList` calls (instead of ~200 per-cell fills) from stack buffers, so drawing allocates nothing on the heap.
- The animation timer holds a **weak** reference to the view, so there is no retain cycle.
- The timer sets a tolerance so the OS can coalesce its wakeups, and ticks are skipped entirely while the window is occluded — no CPU spent animating a pet nobody can see.
