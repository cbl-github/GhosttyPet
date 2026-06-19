# GhosttyPet

A tiny macOS desktop pet: **Boo**, a cute Ghostty ghost, drawn with smooth
anti-aliased vector graphics and a lively 60fps animation.

## Build

```sh
make -C GhosttyPet
```

## Run

```sh
open GhosttyPet/build/GhosttyPet.app
```

## Controls

- Drag with the left mouse button (it wobbles, then bounces when released).
- Click to poke it; press `Space` to make it spin.
- Resize by scrolling over the pet, pinching on a trackpad, or pressing `+` / `-`.
- Quit with right-click or Escape.

## Notes

Boo is drawn with a small **signed-distance-field rasterizer**: every frame the
ghost is computed from parametric shapes (rounded dome, scalloped hem, big eyes
with catchlights, blush, arms, contact shadow) with super-sampled anti-aliasing,
then blitted as a single `CGImage` in `-drawRect:`. The app is native
Objective-C / AppKit only — no Electron, WebView, AVFoundation, or bundled image
assets (the pixels are computed, not loaded). `NSImage`/`NSBitmapImageRep` are
deliberately avoided; the only thing on screen is a computed buffer.

- A 60fps animation state machine keeps it alive: it floats and breathes, blinks
  (sometimes twice), glances around, hops with squash & stretch, waves, wiggles,
  tilts its head, spins, reacts to clicks, wobbles while dragged, and dozes off
  (with little `z`'s) when left alone — then wakes on any interaction.
- Everything is sub-pixel and eased, so motion is fluid rather than steppy.
- The animation timer holds a **weak** reference to the view (no retain cycle),
  sets a tolerance so the OS can coalesce wakeups, and skips ticks entirely while
  the window is occluded — no CPU spent animating a pet nobody can see.
- The exact same design and math drive the Windows app (`../GhosttyPetWin`), so
  both pets match.
