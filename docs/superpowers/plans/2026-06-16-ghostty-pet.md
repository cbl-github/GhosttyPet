# Ghostty Pet Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a macOS-only transparent desktop pet with the clean Ghostty source-animation style and a low-memory native implementation.

**Architecture:** Create a minimal Objective-C/AppKit `.app` bundle. Use a single custom `NSView` to draw the ghost with CoreGraphics paths and animate via a lightweight timer.

**Tech Stack:** Objective-C, AppKit, CoreGraphics, clang, shell tests.

---

### Task 1: Build Scaffold And Dependency Tests

**Files:**
- Create: `GhosttyPet/Makefile`
- Create: `GhosttyPet/tests/test_bundle.sh`
- Create: `GhosttyPet/src/main.m`
- Create: `GhosttyPet/src/PetView.h`
- Create: `GhosttyPet/src/PetView.m`

- [ ] **Step 1: Write the failing bundle test**

```sh
#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

test -x "build/GhosttyPet.app/Contents/MacOS/GhosttyPet"
plutil -lint "build/GhosttyPet.app/Contents/Info.plist" >/dev/null

if otool -L "build/GhosttyPet.app/Contents/MacOS/GhosttyPet" | grep -E 'WebKit|AVFoundation'; then
  echo "Unexpected heavyweight framework linked" >&2
  exit 1
fi

otool -L "build/GhosttyPet.app/Contents/MacOS/GhosttyPet" | grep -q 'AppKit.framework'
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash GhosttyPet/tests/test_bundle.sh`

Expected: fail because `build/GhosttyPet.app/Contents/MacOS/GhosttyPet` does not exist.

- [ ] **Step 3: Add a minimal Makefile and app entrypoint**

Create a `Makefile` that compiles `src/main.m` and `src/PetView.m` with `clang`, links AppKit, and creates `build/GhosttyPet.app`.

- [ ] **Step 4: Add placeholder Objective-C files**

Create `main.m`, `PetView.h`, and `PetView.m` with enough code to launch an app and show a transparent window.

- [ ] **Step 5: Run the test to verify it passes**

Run: `make -C GhosttyPet test`

Expected: build succeeds and `test_bundle.sh` exits 0.

### Task 2: Vector Pet Drawing And Animation

**Files:**
- Modify: `GhosttyPet/src/PetView.h`
- Modify: `GhosttyPet/src/PetView.m`

- [ ] **Step 1: Write a drawing source test**

Add a shell assertion to `GhosttyPet/tests/test_bundle.sh` that `PetView.m` contains `drawGhostInRect`, `NSBezierPath`, `setLineWidth`, and does not contain `NSImage`, `AVPlayer`, or `WebView`.

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash GhosttyPet/tests/test_bundle.sh`

Expected: fail because drawing symbols are missing.

- [ ] **Step 3: Implement CoreGraphics/AppKit drawing**

Draw the ghost body using layered `NSBezierPath`s: blue outer stroke, black inner stroke, white fill, and face marks.

- [ ] **Step 4: Add lightweight animation**

Use an `NSTimer` around 24 fps to update phase, bounce, scale, and face variant, then call `setNeedsDisplay:`.

- [ ] **Step 5: Run the test to verify it passes**

Run: `make -C GhosttyPet test`

Expected: build and source-boundary tests pass.

### Task 3: Interaction And Smoke Verification

**Files:**
- Modify: `GhosttyPet/src/PetView.m`
- Modify: `GhosttyPet/src/main.m`
- Create: `GhosttyPet/README.md`

- [ ] **Step 1: Add interaction assertions**

Extend `test_bundle.sh` to assert that the source implements `mouseDragged`, `rightMouseDown`, and `keyDown`.

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash GhosttyPet/tests/test_bundle.sh`

Expected: fail until interaction methods exist.

- [ ] **Step 3: Implement drag and quit behavior**

Use mouse events to drag the window. Quit on right-click and Escape.

- [ ] **Step 4: Add README usage**

Document build, run, and quit commands.

- [ ] **Step 5: Verify**

Run:

```sh
make -C GhosttyPet clean test
open GhosttyPet/build/GhosttyPet.app
```

Expected: app builds, tests pass, and a transparent floating pet appears.
