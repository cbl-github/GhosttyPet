# Ghostty-Style macOS Desktop Pet Design

## Goal

Build a tiny macOS-only desktop pet inspired by the clean Ghostty source animation. The app should feel like the clean video source, not the website's ASCII conversion artifacts.

## Constraints

- macOS only.
- Memory target: stay as low as practical, with 20 MB as the user-facing ceiling.
- No Electron, WebView, browser runtime, AVFoundation video playback, or bundled frame atlas.
- The pet should be frameless, transparent, always on top, and draggable.
- Use native Objective-C/AppKit and CoreGraphics drawing available on this Mac.

## Visual Design

The pet is a clean vector ghost:

- white body fill,
- black inner outline,
- bright blue outer outline,
- rounded dome top,
- three rounded scallops at the bottom,
- terminal-like face variants such as `>-`, `>>`, and `@@`.

The app should use smooth vector drawing rather than the website's `terminals/home/animation_frames/*.txt` ASCII frames. Those frames are intentionally low-resolution terminal art and create jagged, broken outlines when displayed as a standalone pet.

## Behavior

- Create one transparent borderless floating window.
- Draw the ghost centered in the window.
- Animate with a small bounce, subtle scale pulse, and occasional face changes.
- Allow dragging the pet by clicking and moving the window.
- Provide a quit path with right-click or Escape.

## Architecture

- `main.m` owns app startup, app delegate, window creation, and menu.
- `PetView.m` owns CoreGraphics drawing, animation timing, mouse interactions, and quit handling.
- Shell tests verify build outputs and dependency boundaries.

## Testing

- Build with `clang` against AppKit.
- Verify the generated `.app` bundle has a valid Info.plist.
- Verify the binary links AppKit/CoreGraphics but not WebKit or AVFoundation.
- Launch smoke-test manually or with `open` where possible.

## Known Tradeoff

Activity Monitor may count shared AppKit framework pages against the process, so exact displayed memory can vary. The implementation minimizes private allocations and avoids heavyweight runtimes.
