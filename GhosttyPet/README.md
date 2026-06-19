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
