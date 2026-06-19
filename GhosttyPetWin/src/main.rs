// GhosttyPet for Windows — a tiny pixel-art ghost desktop pet.
//
// Same idea as the macOS build: a frameless, transparent, always-on-top,
// draggable pet drawn from a 14x14 grid of square cells. It uses only the
// native Win32 API (a per-pixel-alpha layered window updated with GDI), so
// there is no Electron, WebView, image atlas, or heavyweight runtime — the
// pixels are computed every frame into a small DIB and pushed to the screen
// with UpdateLayeredWindow.
//
// Like the macOS build, only the eyes move: the body is stored once (BODY) and
// only the three face rows change between frames (FACES). The hop is quantized
// to whole pixels so the art stays crisp and bounces in retro steps at any size.

#![windows_subsystem = "windows"]

use std::f64::consts::PI;
use std::mem::{size_of, zeroed};
use std::ptr::{null, null_mut};

use windows_sys::Win32::Foundation::*;
use windows_sys::Win32::Graphics::Gdi::*;
use windows_sys::Win32::System::LibraryLoader::*;
use windows_sys::Win32::UI::Input::KeyboardAndMouse::*;
use windows_sys::Win32::UI::WindowsAndMessaging::*;

const GRID: usize = 14; // the ghost is a GRID x GRID block of square cells
const FACE_TOP: usize = 4; // first animated (face) row
const FACE_ROWS: usize = 3; // number of animated rows

const MIN_SIZE: i32 = 80; // smallest square window side, in pixels
const MAX_SIZE: i32 = 480; // largest square window side, in pixels

// Premultiplied BGRA packed as 0xAARRGGBB (what a 32-bit top-down DIB expects).
// Colors match the macOS build: bright Ghostty blue rim, black outline, white body.
const BLUE: u32 = 0xFF05_0DF2;
const BLACK: u32 = 0xFF00_0000;
const WHITE: u32 = 0xFFFF_FFFF;

// The constant ghost body. The FACE_ROWS rows starting at FACE_TOP are a plain
// white belly here; they get overwritten per frame by FACES below.
const BODY: [&[u8; GRID]; GRID] = [
    b"...bbbbbbbb...",
    b"..bkkkkkkkkb..",
    b".bkwwwwwwwwkb.",
    b"bkwwwwwwwwwwkb",
    b"bkwwwwwwwwwwkb",
    b"bkwwwwwwwwwwkb",
    b"bkwwwwwwwwwwkb",
    b"bkwwwwwwwwwwkb",
    b"bkwwwwwwwwwwkb",
    b"bkwwwwwwwwwwkb",
    b"bkwwwwwwwwwwkb",
    b"bkwkwwkkwwkwkb",
    b".kk.kk..kk.kk.",
    b".bb.bb..bb.bb.",
];

// The only animated pixels: four eye/face variants (">-", ">>", "@@", "--").
const FACES: [[&[u8; GRID]; FACE_ROWS]; 4] = [
    [b"bkwkwwwwwwwwkb", b"bkwwkwwwkkkwkb", b"bkwkwwwwwwwwkb"], // ">-"
    [b"bkwkwwwwwkwwkb", b"bkwwkwwwwwkwkb", b"bkwkwwwwwkwwkb"], // ">>"
    [b"bkwkkkwwkkkwkb", b"bkwkwkwwkwkwkb", b"bkwkkkwwkkkwkb"], // "@@"
    [b"bkwwwwwwwwwwkb", b"bkwkkkwwkkkwkb", b"bkwwwwwwwwwwkb"], // "--"
];

/// All mutable app state. A single instance lives for the program's lifetime and
/// is reached from the window procedure through the STATE pointer below.
struct State {
    hwnd: HWND,
    screen_dc: HDC,
    mem_dc: HDC,
    bitmap: HBITMAP,
    bits: *mut u32, // top-down BGRA pixels, size*size of them
    size: i32,      // square window side, in pixels
    x: i32,         // window left, in screen pixels
    y: i32,         // window top, in screen pixels
    phase: f64,
    tick: u64,
    face: usize,
    dragging: bool,
    drag_anchor: POINT,    // cursor position when the drag began
    win_anchor: (i32, i32), // window position when the drag began
}

// Single window, single thread: a plain pointer is enough and avoids the
// 32/64-bit quirks of GWLP_USERDATA.
static mut STATE: *mut State = null_mut();

impl State {
    /// (Re)create the DIB section the ghost is drawn into, at `size` x `size`.
    unsafe fn make_dib(&mut self, size: i32) {
        let mut bmi: BITMAPINFO = zeroed();
        bmi.bmiHeader.biSize = size_of::<BITMAPINFOHEADER>() as u32;
        bmi.bmiHeader.biWidth = size;
        bmi.bmiHeader.biHeight = -size; // negative => top-down rows
        bmi.bmiHeader.biPlanes = 1;
        bmi.bmiHeader.biBitCount = 32;
        bmi.bmiHeader.biCompression = 0; // BI_RGB

        let mut bits: *mut core::ffi::c_void = null_mut();
        let bitmap = CreateDIBSection(self.mem_dc, &bmi, DIB_RGB_COLORS, &mut bits, null_mut(), 0);
        SelectObject(self.mem_dc, bitmap as HGDIOBJ);
        if !self.bitmap.is_null() {
            DeleteObject(self.bitmap as HGDIOBJ);
        }
        self.bitmap = bitmap;
        self.bits = bits as *mut u32;
        self.size = size;
    }

    /// Resize the square pet about its center, clamped to the allowed range.
    unsafe fn resize_to(&mut self, new_size: i32) {
        let s = new_size.clamp(MIN_SIZE, MAX_SIZE);
        if s == self.size {
            return;
        }
        // Keep the center fixed.
        self.x += (self.size - s) / 2;
        self.y += (self.size - s) / 2;
        self.make_dib(s);
        self.render();
    }

    /// Compute the current frame into the DIB and push it to the screen.
    unsafe fn render(&mut self) {
        let w = self.size;
        let buf = std::slice::from_raw_parts_mut(self.bits, (w * w) as usize);
        buf.fill(0); // transparent

        // Size every cell to a whole number of pixels so the art stays crisp,
        // and reserve ~20% of the box as headroom for the hop. The grid side is
        // therefore an exact multiple of the cell size.
        let cell = (w as f64 * 0.80 / GRID as f64).floor() as i32;
        if cell >= 1 {
            let grid = cell * GRID as i32;

            // Pixel-style hop: a bouncing arc quantized to whole pixels, so the
            // ghost jumps in crisp steps instead of gliding sub-pixel.
            let hop_max = (cell as f64 * 2.0).floor() as i32;
            let hop = ((self.phase * 1.6).sin().abs() * hop_max as f64).round() as i32;

            // Center the hop arc on the window; "up" is decreasing y (top-down).
            let origin_x = (((w - grid) as f64) / 2.0).round() as i32;
            let rest_top = (((w - grid) as f64) / 2.0 + hop_max as f64 / 2.0).round() as i32;
            let top_y = rest_top - hop;

            for r in 0..GRID {
                let line = if (FACE_TOP..FACE_TOP + FACE_ROWS).contains(&r) {
                    FACES[self.face][r - FACE_TOP]
                } else {
                    BODY[r]
                };
                for c in 0..GRID {
                    let color = match line[c] {
                        b'b' => BLUE,
                        b'k' => BLACK,
                        b'w' => WHITE,
                        _ => continue, // '.' transparent
                    };
                    let cx = origin_x + c as i32 * cell;
                    let cy = top_y + r as i32 * cell;
                    for py in 0..cell {
                        let y = cy + py;
                        if y < 0 || y >= w {
                            continue;
                        }
                        let row = (y * w) as usize;
                        for px in 0..cell {
                            let x = cx + px;
                            if x >= 0 && x < w {
                                buf[row + x as usize] = color;
                            }
                        }
                    }
                }
            }
        }

        let blend = BLENDFUNCTION {
            BlendOp: AC_SRC_OVER as u8,
            BlendFlags: 0,
            SourceConstantAlpha: 255,
            AlphaFormat: AC_SRC_ALPHA as u8,
        };
        let size = SIZE { cx: w, cy: w };
        let src = POINT { x: 0, y: 0 };
        let dst = POINT { x: self.x, y: self.y };
        UpdateLayeredWindow(
            self.hwnd,
            self.screen_dc,
            &dst,
            &size,
            self.mem_dc,
            &src,
            0,
            &blend,
            ULW_ALPHA,
        );
    }
}

unsafe extern "system" fn wndproc(hwnd: HWND, msg: u32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
    if STATE.is_null() {
        return DefWindowProcW(hwnd, msg, wparam, lparam);
    }
    let st = &mut *STATE;

    match msg {
        WM_TIMER => {
            st.phase += 0.12;
            // Wrap at 10*pi, where sin(phase*1.6) completes whole cycles, so the
            // wrap is seamless and phase never grows large enough to lose precision.
            if st.phase >= 10.0 * PI {
                st.phase -= 10.0 * PI;
            }
            st.tick += 1;
            if st.tick % 54 == 0 {
                st.face = (st.face + 1) % 4;
            }
            st.render();
            0
        }
        WM_LBUTTONDOWN => {
            SetForegroundWindow(hwnd); // take key focus so Escape works
            SetCapture(hwnd);
            let mut p: POINT = zeroed();
            GetCursorPos(&mut p);
            st.drag_anchor = p;
            st.win_anchor = (st.x, st.y);
            st.dragging = true;
            0
        }
        WM_MOUSEMOVE => {
            if st.dragging {
                let mut p: POINT = zeroed();
                GetCursorPos(&mut p);
                st.x = st.win_anchor.0 + (p.x - st.drag_anchor.x);
                st.y = st.win_anchor.1 + (p.y - st.drag_anchor.y);
                st.render();
            }
            0
        }
        WM_LBUTTONUP => {
            st.dragging = false;
            ReleaseCapture();
            0
        }
        WM_RBUTTONDOWN => {
            PostQuitMessage(0);
            0
        }
        WM_MOUSEWHEEL => {
            // Scroll up to grow, down to shrink (one notch == WHEEL_DELTA == 120).
            let delta = ((wparam >> 16) as u16) as i16 as i32;
            st.resize_to(st.size + delta * 16 / 120);
            0
        }
        WM_KEYDOWN => {
            let vk = wparam as u16;
            if vk == VK_ESCAPE {
                PostQuitMessage(0);
                0
            } else if vk == VK_OEM_PLUS || vk == VK_ADD {
                st.resize_to(st.size + 24);
                0
            } else if vk == VK_OEM_MINUS || vk == VK_SUBTRACT {
                st.resize_to(st.size - 24);
                0
            } else {
                DefWindowProcW(hwnd, msg, wparam, lparam)
            }
        }
        WM_DESTROY => {
            PostQuitMessage(0);
            0
        }
        _ => DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}

fn wide(s: &str) -> Vec<u16> {
    s.encode_utf16().chain(std::iter::once(0)).collect()
}

fn main() {
    unsafe {
        let hinstance = GetModuleHandleW(null());
        let class_name = wide("GhosttyPetWindow");

        let mut wc: WNDCLASSW = zeroed();
        wc.lpfnWndProc = Some(wndproc);
        wc.hInstance = hinstance;
        wc.hCursor = LoadCursorW(null_mut(), IDC_ARROW);
        wc.lpszClassName = class_name.as_ptr();
        RegisterClassW(&wc);

        let size = 150i32;
        let x = (GetSystemMetrics(SM_CXSCREEN) - size) / 2;
        let y = (GetSystemMetrics(SM_CYSCREEN) - size) / 2;
        let title = wide("GhosttyPet");

        let hwnd = CreateWindowExW(
            WS_EX_LAYERED | WS_EX_TOPMOST | WS_EX_TOOLWINDOW,
            class_name.as_ptr(),
            title.as_ptr(),
            WS_POPUP,
            x,
            y,
            size,
            size,
            null_mut(),
            null_mut(),
            hinstance,
            null(),
        );
        if hwnd.is_null() {
            return;
        }

        let mut state = Box::new(State {
            hwnd,
            screen_dc: GetDC(null_mut()),
            mem_dc: CreateCompatibleDC(null_mut()),
            bitmap: null_mut(),
            bits: null_mut(),
            size,
            x,
            y,
            phase: 0.0,
            tick: 0,
            face: 0,
            dragging: false,
            drag_anchor: zeroed(),
            win_anchor: (x, y),
        });
        state.make_dib(size);
        STATE = &mut *state;

        ShowWindow(hwnd, SW_SHOWNOACTIVATE);
        SetForegroundWindow(hwnd);
        state.render();

        SetTimer(hwnd, 1, 55, None); // ~18 fps

        let mut msg: MSG = zeroed();
        while GetMessageW(&mut msg, null_mut(), 0, 0) > 0 {
            TranslateMessage(&msg);
            DispatchMessageW(&msg);
        }

        // Best-effort cleanup before exit.
        KillTimer(hwnd, 1);
        if !state.bitmap.is_null() {
            DeleteObject(state.bitmap as HGDIOBJ);
        }
        DeleteDC(state.mem_dc);
        ReleaseDC(null_mut(), state.screen_dc);
        STATE = null_mut();
    }
}
