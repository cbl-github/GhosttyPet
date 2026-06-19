# GhosttyPet (Windows)

A tiny Windows desktop pet: **Boo**, a cute Ghostty ghost, rendered natively with
the Win32 API in Rust. It is the Windows counterpart to the macOS app in
`../GhosttyPet`.

## Build

Requires a Rust toolchain (`rustup`). Builds with either the MSVC or the
self-contained GNU target (`x86_64-pc-windows-gnu`).

```sh
cargo build --release
```

The binary is `target/release/GhosttyPet.exe`.

## Run

```sh
cargo run --release
```

or just launch `target/release/GhosttyPet.exe`.

## Controls

- Drag with the left mouse button (it wobbles, then bounces when released).
- Click to poke it; press `Space` to make it spin.
- Resize by scrolling over the pet, or pressing `+` / `-`.
- Quit with right-click or Escape.

## Notes

Boo is drawn with a small **signed-distance-field rasterizer**: every frame the
ghost is computed from parametric shapes (dome, scalloped hem, big eyes with
catchlights, blush, arms, contact shadow) with super-sampled anti-aliasing, so it
stays smooth and cute at any size. The result is pushed to a per-pixel-alpha
**layered window** via `UpdateLayeredWindow`. There is no Electron, WebView, image
atlas, or other heavyweight runtime — only `user32`/`gdi32` via `windows-sys`, and
no image assets (the pixels are computed, not loaded).

- A 60fps animation state machine keeps it alive: it floats and breathes, blinks
  (sometimes twice), glances around, hops with squash & stretch, waves, wiggles,
  tilts its head, spins, reacts to clicks, wobbles while dragged, and dozes off
  (with little `z`'s) when left alone — then wakes on any interaction.
- Everything is sub-pixel and eased, so motion is fluid rather than steppy.
- Transparent pixels are click-through, so you can only grab the ghost itself.
- Still tiny: ~1.6 MB private working set; the release profile is tuned for a
  small binary (`opt-level = "z"`, LTO, `panic = "abort"`, stripped).
- The same design/animation math drives the macOS app, so both pets match.
