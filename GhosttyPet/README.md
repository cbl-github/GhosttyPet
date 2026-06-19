# GhosttyPet

A tiny macOS desktop pet inspired by the clean Ghostty source animation.

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

The app uses native Objective-C/AppKit and CoreGraphics-style vector drawing. It does not use Electron, WebView, AVFoundation playback, or image frame atlases.
