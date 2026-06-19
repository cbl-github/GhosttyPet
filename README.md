# GhosttyPet

Tiny desktop pet: a pixel-art ghost inspired by Ghostty. It bounces with a
pixel-style hop, can be dragged around, and is resizable.

## macOS (`GhosttyPet/`)

Native Objective-C / AppKit.

```sh
make -C GhosttyPet
open GhosttyPet/build/GhosttyPet.app
```

## Windows (`GhosttyPetWin/`)

Native Win32 in Rust (a per-pixel-alpha layered window).

```sh
cargo build --release --manifest-path GhosttyPetWin/Cargo.toml
```

## Controls

Drag to move; scroll or `+` / `-` to resize; right-click or Escape to quit.

Build output stays ignored.
