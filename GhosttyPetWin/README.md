# GhosttyPet (Windows)

A tiny Windows desktop pet: a pixel-art ghost, rendered natively with the Win32
API in Rust. It is the Windows counterpart to the macOS app in `../GhosttyPet`.

## Build

Requires a Rust toolchain (`rustup`, MSVC target).

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

- Drag with the left mouse button.
- Resize by scrolling over the pet, or pressing `+` / `-`.
- Quit with right-click or Escape.

## Notes

The pet is a per-pixel-alpha **layered window**: each frame the ghost is computed
into a small top-down BGRA DIB and pushed to the screen with
`UpdateLayeredWindow`. There is no Electron, WebView, image atlas, or other
heavyweight runtime — only `user32`/`gdi32` via the `windows-sys` crate.

- The ghost is a 14x14 grid of square cells. Only the eyes animate, so the body
  is stored **once** (`BODY`) and only the three face rows vary between frames
  (`FACES`) — no duplicated frame copies.
- Each cell is sized to a whole number of pixels and the hop is snapped to the
  pixel grid, so the art stays crisp and bounces in retro steps at any size.
- Transparent pixels are click-through, so you can only grab the ghost itself.
- The release profile is tuned for a small binary (`opt-level = "z"`, LTO,
  `panic = "abort"`, stripped).
