// GhosttyPet for Windows -- "Boo", a cute Ghostty ghost desktop pet.
//
// A frameless, transparent, always-on-top, draggable, resizable pet drawn
// natively with the Win32 API (a per-pixel-alpha layered window updated with
// GDI). No Electron, WebView, image atlas, or runtime -- the ghost is computed
// every frame with a small signed-distance-field rasterizer and pushed to the
// screen with UpdateLayeredWindow.
//
// The ghost lives in a 64x64 design-unit space and is drawn with anti-aliased
// SDF coverage (super-sampled), so it stays smooth and cute at any size. A
// 60fps animation state machine gives it life: it floats and breathes, blinks,
// glances around, hops with squash & stretch, waves, wiggles, tilts its head,
// spins, reacts to clicks, wobbles while dragged, and dozes off when left alone.

#![windows_subsystem = "windows"]

use std::f32::consts::PI;
use std::mem::{size_of, zeroed};
use std::ptr::{null, null_mut};
use std::time::Instant;

use windows_sys::Win32::Foundation::*;
use windows_sys::Win32::Graphics::Gdi::*;
use windows_sys::Win32::System::LibraryLoader::*;
use windows_sys::Win32::UI::Input::KeyboardAndMouse::*;
use windows_sys::Win32::UI::WindowsAndMessaging::*;

// ---------------------------------------------------------------------------
// Palette (straight-alpha RGB; alpha supplied per use).
// ---------------------------------------------------------------------------
const RIM: [f32; 3] = [0x1B as f32 / 255.0, 0x6F as f32 / 255.0, 0xF0 as f32 / 255.0];
const RIM_HI: [f32; 3] = [0x6E as f32 / 255.0, 0x93 as f32 / 255.0, 0xFF as f32 / 255.0];
const INNER: [f32; 3] = [0x2B as f32 / 255.0, 0x2F as f32 / 255.0, 0x8C as f32 / 255.0];
const WHITE: [f32; 3] = [0xF8 as f32 / 255.0, 0xFB as f32 / 255.0, 0xFF as f32 / 255.0];
const SHADE: [f32; 3] = [0xDC as f32 / 255.0, 0xE7 as f32 / 255.0, 0xF5 as f32 / 255.0];
const EYE: [f32; 3] = [0x16 as f32 / 255.0, 0x1A as f32 / 255.0, 0x33 as f32 / 255.0];
const MOUTH_PINK: [f32; 3] = [0xE9 as f32 / 255.0, 0x6A as f32 / 255.0, 0x8B as f32 / 255.0];
const BLUSH: [f32; 3] = [0xFF as f32 / 255.0, 0x9D as f32 / 255.0, 0xB4 as f32 / 255.0];
const SPARK: [f32; 3] = [0x8F as f32 / 255.0, 0xD0 as f32 / 255.0, 0xFF as f32 / 255.0];
const SHADOW: [f32; 3] = [0x14 as f32 / 255.0, 0x1A as f32 / 255.0, 0x40 as f32 / 255.0];

const MIN_SIZE: i32 = 80;
const MAX_SIZE: i32 = 480;

// Anchor for squash/skew/rotation: the ghost's hem (its "feet").
const ANCHOR: (f32, f32) = (32.0, 50.0);
const GROUND_Y: f32 = 51.0; // contact-shadow line, in design units

// ---------------------------------------------------------------------------
// Small math helpers
// ---------------------------------------------------------------------------
fn clampf(x: f32, a: f32, b: f32) -> f32 {
    if x < a {
        a
    } else if x > b {
        b
    } else {
        x
    }
}
fn mixf(a: f32, b: f32, t: f32) -> f32 {
    a + (b - a) * t
}
fn smoothstep(e0: f32, e1: f32, x: f32) -> f32 {
    let t = clampf((x - e0) / (e1 - e0), 0.0, 1.0);
    t * t * (3.0 - 2.0 * t)
}
fn ease_in_quad(t: f32) -> f32 {
    t * t
}
fn ease_out_quad(t: f32) -> f32 {
    1.0 - (1.0 - t) * (1.0 - t)
}
fn ease_out_cubic(t: f32) -> f32 {
    let u = 1.0 - t;
    1.0 - u * u * u
}
fn ease_out_back(t: f32) -> f32 {
    let c1 = 1.70158;
    let c3 = c1 + 1.0;
    let u = t - 1.0;
    1.0 + c3 * u * u * u + c1 * u * u
}
fn ease_in_out_back(t: f32) -> f32 {
    // symmetric overshoot, used for the spin
    if t < 0.5 {
        (2.0 * t).powi(2) * (3.6 * (2.0 * t) - 2.6) / 2.0
    } else {
        let u = 2.0 * t - 2.0;
        (u * u * (3.6 * u + 2.6) + 2.0) / 2.0
    }
}

// signed distance to a circle / rounded box / capsule segment / ellipse
fn sd_circle(px: f32, py: f32, cx: f32, cy: f32, r: f32) -> f32 {
    ((px - cx).powi(2) + (py - cy).powi(2)).sqrt() - r
}
fn sd_round_box(px: f32, py: f32, cx: f32, cy: f32, hx: f32, hy: f32, r: f32) -> f32 {
    let dx = (px - cx).abs() - (hx - r);
    let dy = (py - cy).abs() - (hy - r);
    let ox = dx.max(0.0);
    let oy = dy.max(0.0);
    (ox * ox + oy * oy).sqrt() + dx.max(dy).min(0.0) - r
}
fn sd_segment(px: f32, py: f32, ax: f32, ay: f32, bx: f32, by: f32, r: f32) -> f32 {
    let pax = px - ax;
    let pay = py - ay;
    let bax = bx - ax;
    let bay = by - ay;
    let denom = bax * bax + bay * bay;
    let h = if denom > 0.0 {
        clampf((pax * bax + pay * bay) / denom, 0.0, 1.0)
    } else {
        0.0
    };
    let dx = pax - bax * h;
    let dy = pay - bay * h;
    (dx * dx + dy * dy).sqrt() - r
}
fn sd_ellipse(px: f32, py: f32, cx: f32, cy: f32, rx: f32, ry: f32) -> f32 {
    // cheap approximate ellipse SDF (good enough for AA fill)
    let nx = (px - cx) / rx;
    let ny = (py - cy) / ry;
    let k = (nx * nx + ny * ny).sqrt();
    (k - 1.0) * rx.min(ry)
}

// premultiplied-alpha "over" composite (src over dst)
fn over(dst: [f32; 4], src: [f32; 4]) -> [f32; 4] {
    let ia = 1.0 - src[3];
    [
        src[0] + dst[0] * ia,
        src[1] + dst[1] * ia,
        src[2] + dst[2] * ia,
        src[3] + dst[3] * ia,
    ]
}
// straight color + coverage -> premultiplied layer
fn lay(c: [f32; 3], a: f32) -> [f32; 4] {
    [c[0] * a, c[1] * a, c[2] * a, a]
}

// ---------------------------------------------------------------------------
// Per-frame parameters the rasterizer reads (the "shared contract").
// ---------------------------------------------------------------------------
#[derive(Clone, Copy)]
struct Frame {
    off_x: f32,
    off_y: f32,
    sx: f32,
    sy: f32,
    skew: f32,
    rot: f32, // radians
    face_yaw: f32,
    eye_open: f32,
    pupil_dx: f32,
    pupil_dy: f32,
    mouth_open: f32,
    mouth_curve: f32, // +1 smile, -1 frown
    blush: f32,
    arm_l: f32, // angle from "down", degrees (outward positive)
    arm_l_len: f32,
    arm_r: f32,
    arm_r_len: f32,
    shadow_rx: f32,
    shadow_a: f32,
}
impl Frame {
    fn idle() -> Frame {
        Frame {
            off_x: 0.0,
            off_y: 0.0,
            sx: 1.0,
            sy: 1.0,
            skew: 0.0,
            rot: 0.0,
            face_yaw: 0.0,
            eye_open: 1.0,
            pupil_dx: 0.0,
            pupil_dy: 0.0,
            mouth_open: 0.0,
            mouth_curve: 1.0,
            blush: 1.0,
            arm_l: 26.0,
            arm_l_len: 3.0,
            arm_r: 26.0,
            arm_r_len: 3.0,
            shadow_rx: 16.0,
            shadow_a: 0.27,
        }
    }
}

#[derive(Clone, Copy)]
struct Particle {
    x: f32,
    y: f32,
    vx: f32,
    vy: f32,
    age: f32,
    life: f32,
    kind: u8, // 0 sparkle, 1 sleep "z"
}

// ---------------------------------------------------------------------------
// The rasterizer: straight (px,py) in design units -> premultiplied RGBA.
// ---------------------------------------------------------------------------
fn inverse_transform(px: f32, py: f32, f: &Frame) -> (f32, f32) {
    let mut x = px - f.off_x;
    let mut y = py - f.off_y;
    if f.rot != 0.0 {
        let (s, c) = (-f.rot).sin_cos();
        let ax = x - ANCHOR.0;
        let ay = y - ANCHOR.1;
        x = ANCHOR.0 + ax * c - ay * s;
        y = ANCHOR.1 + ax * s + ay * c;
    }
    x -= f.skew * (y - ANCHOR.1);
    x = ANCHOR.0 + (x - ANCHOR.0) / f.sx;
    y = ANCHOR.1 + (y - ANCHOR.1) / f.sy;
    (x, y)
}

fn body_sdf(mx: f32, my: f32, f: &Frame) -> f32 {
    // dome + rounded torso + three hem scallops
    let mut d = sd_circle(mx, my, 32.0, 22.0, 13.0);
    d = d.min(sd_round_box(mx, my, 32.0, 33.5, 13.0, 12.5, 5.0));
    d = d.min(sd_circle(mx, my, 23.33, 45.5, 4.4));
    d = d.min(sd_circle(mx, my, 32.0, 46.0, 5.0));
    d = d.min(sd_circle(mx, my, 40.67, 45.5, 4.4));
    // arms (capsule nubs) unioned in so they share the rim
    let (lhx, lhy) = arm_hand((20.0, 37.0), f.arm_l, f.arm_l_len, -1.0);
    let (rhx, rhy) = arm_hand((44.0, 37.0), f.arm_r, f.arm_r_len, 1.0);
    d = d.min(sd_segment(mx, my, 20.0, 37.0, lhx, lhy, 3.1));
    d = d.min(sd_segment(mx, my, 44.0, 37.0, rhx, rhy, 3.1));
    d
}

fn arm_hand(sh: (f32, f32), ang_deg: f32, len: f32, side: f32) -> (f32, f32) {
    let a = ang_deg.to_radians();
    (sh.0 + side * len * a.sin(), sh.1 + len * a.cos())
}

// straight design-space pixel -> premultiplied RGBA
fn shade(px: f32, py: f32, f: &Frame) -> [f32; 4] {
    let mut acc = [0.0f32; 4];
    let aa = 0.6; // feather (design units); scaled implicitly by SS

    // contact shadow, on the ground, behind the body
    let sd = sd_ellipse(px, py, 32.0, GROUND_Y, f.shadow_rx, 4.0);
    let scov = smoothstep(aa, -aa, sd);
    if scov > 0.0 {
        acc = over(acc, lay(SHADOW, scov * f.shadow_a));
    }

    let (mx, my) = inverse_transform(px, py, f);

    // cheap bbox cull for the body/face
    if mx > -8.0 && mx < 72.0 && my > -8.0 && my < 60.0 {
        let d = body_sdf(mx, my, f);
        let cov = smoothstep(aa, -aa, d);
        if cov > 0.0 {
            // body fill with cool shading + glossy top highlight
            let shade_amt = smoothstep(0.0, 26.0, my - mx * 0.25) * 0.16;
            let mut col = [
                mixf(WHITE[0], SHADE[0], shade_amt),
                mixf(WHITE[1], SHADE[1], shade_amt),
                mixf(WHITE[2], SHADE[2], shade_amt),
            ];
            let hi = (1.0 - smoothstep(0.0, 11.0, ((mx - 25.0).powi(2) + (my - 17.0).powi(2)).sqrt())) * 0.28;
            col = [mixf(col[0], 1.0, hi), mixf(col[1], 1.0, hi), mixf(col[2], 1.0, hi)];
            // inner indigo line, then bright rim toward the edge
            let inner = smoothstep(-3.6, -2.2, d) * 0.35;
            col = [
                mixf(col[0], INNER[0], inner),
                mixf(col[1], INNER[1], inner),
                mixf(col[2], INNER[2], inner),
            ];
            let rimt = smoothstep(-2.2, -0.4, d);
            // upper-left of the rim catches light
            let rim_lit = smoothstep(0.0, 18.0, (32.0 - mx) + (22.0 - my));
            let rim_col = [
                mixf(RIM[0], RIM_HI[0], rim_lit),
                mixf(RIM[1], RIM_HI[1], rim_lit),
                mixf(RIM[2], RIM_HI[2], rim_lit),
            ];
            col = [
                mixf(col[0], rim_col[0], rimt),
                mixf(col[1], rim_col[1], rimt),
                mixf(col[2], rim_col[2], rimt),
            ];
            acc = over(acc, lay(col, cov));

            // ---- face (only painted where the body is) ----
            let fy = f.face_yaw * 6.0;
            // blush
            for s in [-1.0f32, 1.0] {
                let bd = sd_ellipse(mx, my, 32.0 + s * 13.0 + fy, 37.0, 3.6, 2.3);
                let bc = smoothstep(1.2, -1.2, bd);
                if bc > 0.0 {
                    acc = over(acc, lay(BLUSH, bc * 0.55 * f.blush * cov));
                }
            }
            // eyes
            let eo = clampf(f.eye_open, 0.0, 1.3);
            for s in [-1.0f32, 1.0] {
                let ex = 32.0 + s * 9.0 + fy + f.pupil_dx * 0.6;
                let ey = 30.0 + f.pupil_dy * 0.6;
                if eo > 0.12 {
                    let ed = sd_ellipse(mx, my, ex, ey, 3.4, 4.8 * eo);
                    let ec = smoothstep(0.8, -0.8, ed);
                    if ec > 0.0 {
                        acc = over(acc, lay(EYE, ec * cov));
                    }
                    // catchlights
                    if eo > 0.45 {
                        let cd = sd_circle(mx, my, ex - 1.2, ey - 1.7, 1.4);
                        let cc = smoothstep(0.6, -0.6, cd);
                        acc = over(acc, lay([1.0, 1.0, 1.0], cc * cov));
                        let cd2 = sd_circle(mx, my, ex + 1.1, ey + 1.6, 0.8);
                        let cc2 = smoothstep(0.5, -0.5, cd2);
                        acc = over(acc, lay([1.0, 1.0, 1.0], cc2 * 0.8 * cov));
                    }
                } else {
                    // closed: a soft lash arc
                    let ld = (sd_circle(mx, my, ex, ey - 2.6, 3.6)).abs() - 0.7;
                    let lc = smoothstep(0.6, -0.6, ld) * smoothstep(-2.0, 0.0, my - ey);
                    acc = over(acc, lay(EYE, lc * cov));
                }
            }
            // mouth at (32, 39): smile arc, or an open "o"
            let mxx = 32.0 + fy;
            if f.mouth_open > 0.05 {
                let md = sd_ellipse(mx, my, mxx, 40.0, 2.2 + f.mouth_open, 1.8 + 3.0 * f.mouth_open);
                let mc = smoothstep(0.7, -0.7, md);
                acc = over(acc, lay(MOUTH_PINK, mc * cov));
                let rim_m = smoothstep(0.9, 0.0, md.abs());
                acc = over(acc, lay(EYE, rim_m * 0.8 * cov));
            } else {
                // smile: lower arc of a circle, curve sign from mouth_curve
                let cyc = 39.0 - f.mouth_curve * 2.4;
                let md = (sd_circle(mx, my, mxx, cyc, 3.0)).abs() - 0.75;
                let side = if f.mouth_curve >= 0.0 {
                    smoothstep(-1.5, 0.5, my - cyc)
                } else {
                    smoothstep(1.5, -0.5, my - cyc)
                };
                let mc = smoothstep(0.6, -0.6, md) * side * smoothstep(3.4, 2.0, (mx - mxx).abs());
                acc = over(acc, lay(EYE, mc * cov));
            }
        }
    }
    acc
}

fn pack(c: [f32; 4]) -> u32 {
    let a = clampf(c[3], 0.0, 1.0);
    let r = (clampf(c[0], 0.0, a) * 255.0 + 0.5) as u32;
    let g = (clampf(c[1], 0.0, a) * 255.0 + 0.5) as u32;
    let b = (clampf(c[2], 0.0, a) * 255.0 + 0.5) as u32;
    let a8 = (a * 255.0 + 0.5) as u32;
    (a8 << 24) | (r << 16) | (g << 8) | b
}

// Render one frame into a `size`x`size` premultiplied-BGRA buffer.
fn paint(buf: &mut [u32], size: i32, f: &Frame, particles: &[Particle]) {
    let n = (size * size) as usize;
    for p in buf[..n].iter_mut() {
        *p = 0;
    }
    let scale = size as f32 / 64.0;
    let ss: i32 = if size <= 192 { 3 } else { 2 };
    let inv = 1.0 / (ss * ss) as f32;
    for py in 0..size {
        for px in 0..size {
            let mut acc = [0.0f32; 4];
            for sy in 0..ss {
                for sx in 0..ss {
                    let dx = (px as f32 + (sx as f32 + 0.5) / ss as f32) / scale;
                    let dy = (py as f32 + (sy as f32 + 0.5) / ss as f32) / scale;
                    let c = shade(dx, dy, f);
                    acc[0] += c[0];
                    acc[1] += c[1];
                    acc[2] += c[2];
                    acc[3] += c[3];
                }
            }
            buf[(py * size + px) as usize] =
                pack([acc[0] * inv, acc[1] * inv, acc[2] * inv, acc[3] * inv]);
        }
    }
    // particles drawn on top, in design space (sparkles / sleepy z's)
    for p in particles {
        let t = p.age / p.life;
        if t >= 1.0 {
            continue;
        }
        let a = (1.0 - t) * 0.9;
        let col = if p.kind == 0 { SPARK } else { [0.7, 0.85, 1.0] };
        let r = if p.kind == 0 { 2.0 } else { 2.6 };
        let cxp = (p.x * scale) as i32;
        let cyp = (p.y * scale) as i32;
        let rr = (r * scale).ceil() as i32 + 1;
        for yy in (cyp - rr).max(0)..(cyp + rr).min(size) {
            for xx in (cxp - rr).max(0)..(cxp + rr).min(size) {
                let ddx = (xx as f32 + 0.5) / scale - p.x;
                let ddy = (yy as f32 + 0.5) / scale - p.y;
                // little 4-point sparkle: bright center, thin cross
                let dist = (ddx * ddx + ddy * ddy).sqrt();
                let cross = (1.0 - smoothstep(0.0, r, ddx.abs())) * (1.0 - smoothstep(0.0, r * 0.35, ddy.abs()))
                    + (1.0 - smoothstep(0.0, r, ddy.abs())) * (1.0 - smoothstep(0.0, r * 0.35, ddx.abs()));
                let core = 1.0 - smoothstep(0.0, r * 0.5, dist);
                let cov = clampf(cross + core, 0.0, 1.0) * a;
                if cov > 0.0 {
                    let i = (yy * size + xx) as usize;
                    let dst = unpack(buf[i]);
                    buf[i] = pack(over(dst, lay(col, cov)));
                }
            }
        }
    }
}

fn unpack(v: u32) -> [f32; 4] {
    let a = ((v >> 24) & 0xff) as f32 / 255.0;
    let r = ((v >> 16) & 0xff) as f32 / 255.0;
    let g = ((v >> 8) & 0xff) as f32 / 255.0;
    let b = (v & 0xff) as f32 / 255.0;
    [r, g, b, a] // already premultiplied
}

// ---------------------------------------------------------------------------
// Animation state machine
// ---------------------------------------------------------------------------
#[derive(Clone, Copy, PartialEq)]
enum Act {
    Idle,
    Look,
    Hop,
    Wave,
    Wiggle,
    Tilt,
    Spin,
    Surprise,
    Yawn,
    Sleep,
    Wake,
}

struct Anim {
    rng: u32,
    act: Act,
    act_start: f32,
    act_dur: f32,
    look_dir: f32,
    next_act: f32,
    next_blink: f32,
    blink_start: f32,
    blink_double: bool,
    last_interact: f32,
    particles: Vec<Particle>,
    last_spawn: f32,
    prev_t: f32,
    // drag
    dragging: bool,
    vel_x: f32,
    vel_y: f32,
    rel_start: f32,
    rel_amp_x: f32,
    rel_amp_y: f32,
}

fn xs(s: &mut u32) -> u32 {
    let mut x = *s;
    x ^= x << 13;
    x ^= x >> 17;
    x ^= x << 5;
    *s = x;
    x
}
fn randf(s: &mut u32) -> f32 {
    (xs(s) as f32) / (u32::MAX as f32)
}
fn randr(s: &mut u32, a: f32, b: f32) -> f32 {
    a + (b - a) * randf(s)
}

impl Anim {
    fn new() -> Anim {
        let seed = std::process::id().wrapping_mul(2654435761).max(1);
        Anim {
            rng: seed | 1,
            act: Act::Wave, // say hello on launch
            act_start: 0.0,
            act_dur: 1100.0,
            look_dir: 1.0,
            next_act: 2600.0,
            next_blink: 1800.0,
            blink_start: -999.0,
            blink_double: false,
            last_interact: 0.0,
            particles: Vec::new(),
            last_spawn: 0.0,
            prev_t: 0.0,
            dragging: false,
            vel_x: 0.0,
            vel_y: 0.0,
            rel_start: -999.0,
            rel_amp_x: 0.0,
            rel_amp_y: 0.0,
        }
    }

    fn interacted(&mut self, t: f32) {
        self.last_interact = t;
        if self.act == Act::Sleep || self.act == Act::Yawn {
            self.start(Act::Wake, t, 480.0);
        }
    }

    fn start(&mut self, a: Act, t: f32, dur: f32) {
        self.act = a;
        self.act_start = t;
        self.act_dur = dur;
    }

    fn spawn_sparkles(&mut self, n: i32, kind: u8) {
        for _ in 0..n {
            let ang = randr(&mut self.rng, 0.0, 2.0 * PI);
            let sp = randr(&mut self.rng, 0.2, 0.6);
            self.particles.push(Particle {
                x: 32.0 + randr(&mut self.rng, -12.0, 12.0),
                y: 26.0 + randr(&mut self.rng, -10.0, 8.0),
                vx: ang.cos() * sp,
                vy: ang.sin() * sp - 0.2,
                age: 0.0,
                life: randr(&mut self.rng, 600.0, 1000.0),
                kind,
            });
        }
    }

    fn update(&mut self, t: f32) {
        let dt = (t - self.prev_t).clamp(0.0, 100.0);
        self.prev_t = t;

        // advance particles
        for p in self.particles.iter_mut() {
            p.x += p.vx * dt * 0.06;
            p.y += p.vy * dt * 0.06;
            p.age += dt;
        }
        self.particles.retain(|p| p.age < p.life);

        // blink scheduler (independent overlay, paused while asleep)
        if self.act != Act::Sleep && t >= self.next_blink {
            self.blink_start = t;
            self.blink_double = randf(&mut self.rng) < 0.15;
            self.next_blink = t + randr(&mut self.rng, 2500.0, 6000.0);
        }

        // finish current one-shot action
        let elapsed = t - self.act_start;
        let action_done = !matches!(self.act, Act::Idle | Act::Sleep) && elapsed >= self.act_dur;
        if action_done {
            if self.act == Act::Yawn {
                self.start(Act::Sleep, t, 1.0e9);
            } else if self.act == Act::Wake {
                self.act = Act::Idle;
                self.last_interact = t;
                self.next_act = t + randr(&mut self.rng, 1500.0, 4000.0);
            } else {
                self.act = Act::Idle;
                self.next_act = t + randr(&mut self.rng, 1500.0, 4000.0);
            }
        }

        // drowsy -> yawn -> sleep
        if self.act == Act::Idle && !self.dragging && t - self.last_interact > 22000.0 {
            self.start(Act::Yawn, t, 1300.0);
        }

        // idle action picker
        if self.act == Act::Idle && !self.dragging && t >= self.next_act {
            let r = randf(&mut self.rng);
            if r < 0.26 {
                self.start(Act::Hop, t, 640.0);
            } else if r < 0.48 {
                self.look_dir = if randf(&mut self.rng) < 0.5 { -1.0 } else { 1.0 };
                self.start(Act::Look, t, 1400.0);
            } else if r < 0.62 {
                self.start(Act::Wiggle, t, 850.0);
                self.spawn_sparkles(3, 0);
            } else if r < 0.74 {
                self.start(Act::Wave, t, 1100.0);
            } else if r < 0.82 {
                self.start(Act::Tilt, t, 900.0);
            } else if r < 0.86 {
                self.start(Act::Spin, t, 720.0);
                self.spawn_sparkles(6, 0);
            } else {
                // micro-pause: just float a bit longer
                self.next_act = t + randr(&mut self.rng, 1200.0, 2600.0);
            }
        }

        // sleepy z's
        if self.act == Act::Sleep && t - self.last_spawn > 1500.0 {
            self.last_spawn = t;
            self.particles.push(Particle {
                x: 40.0,
                y: 18.0,
                vx: 0.25,
                vy: -0.5,
                age: 0.0,
                life: 1400.0,
                kind: 1,
            });
        }
    }

    fn frame(&self, t: f32) -> Frame {
        let mut f = Frame::idle();

        // --- always-on idle float + breathe + sway ---
        let bob = (2.0 * PI * t / 2600.0).sin();
        f.off_y = 1.5 * bob;
        f.sy = 1.0 - 0.025 * bob;
        f.sx = 1.0 + 0.025 * bob;
        f.off_x = 4.0 * (2.0 * PI * t / 5600.0).sin();
        f.skew = 0.015 * (2.0 * PI * t / 4300.0).sin();
        f.pupil_dx = 0.4 * (2.0 * PI * t / 5600.0).sin();

        let le = t - self.act_start; // local time in action
        match self.act {
            Act::Idle => {}
            Act::Look => {
                let p = (le / self.act_dur).clamp(0.0, 1.0);
                let amt = if p < 0.25 {
                    ease_out_cubic(p / 0.25)
                } else if p < 0.65 {
                    1.0
                } else {
                    1.0 - ease_out_cubic((p - 0.65) / 0.35)
                };
                f.pupil_dx = self.look_dir * 1.4 * amt;
                f.pupil_dy = -0.3 * amt;
                f.face_yaw = self.look_dir * 0.10 * amt;
                f.off_x += self.look_dir * 1.2 * amt;
            }
            Act::Hop => {
                hop_frame(&mut f, le);
            }
            Act::Wave => {
                let p = (le / self.act_dur).clamp(0.0, 1.0);
                let raise = ease_out_back((p / 0.16).min(1.0));
                f.arm_r = mixf(26.0, 152.0, raise);
                f.arm_r_len = mixf(3.0, 10.0, raise);
                if p > 0.16 && p < 0.82 {
                    f.arm_r += 18.0 * (2.0 * PI * (le - 180.0) / 300.0).sin();
                }
                if p >= 0.82 {
                    let q = (p - 0.82) / 0.18;
                    f.arm_r = mixf(f.arm_r, 26.0, q);
                    f.arm_r_len = mixf(10.0, 3.0, q);
                }
                f.skew -= 0.04 * (1.0 - (p - 0.5).abs() * 2.0).max(0.0);
                f.face_yaw -= 0.06;
                f.eye_open = 0.7;
                f.mouth_curve = 1.0;
                f.blush = 1.3;
                f.off_y -= 1.0 * (PI * p).sin();
            }
            Act::Wiggle => {
                let p = (le / self.act_dur).clamp(0.0, 1.0);
                f.rot = (6.0_f32).to_radians() * (2.0 * PI * le / 140.0).sin() * (1.0 - p);
                f.eye_open = 0.55;
                f.mouth_curve = 1.0;
                f.blush = 1.35;
            }
            Act::Tilt => {
                let p = (le / self.act_dur).clamp(0.0, 1.0);
                let amt = if p < 0.28 {
                    ease_out_cubic(p / 0.28)
                } else if p < 0.72 {
                    1.0
                } else {
                    1.0 - ease_out_cubic((p - 0.72) / 0.28)
                };
                f.rot = (11.0_f32).to_radians() * amt;
                f.face_yaw = 0.05 * amt;
                f.pupil_dy = -0.6 * amt;
                f.mouth_open = 0.25 * amt;
            }
            Act::Spin => {
                let p = (le / self.act_dur).clamp(0.0, 1.0);
                f.rot = ease_in_out_back(p) * 2.0 * PI;
                let pulse = (2.0 * PI * p).cos();
                f.sx = 1.0 + 0.12 * pulse;
                f.sy = 1.0 - 0.12 * pulse;
                f.off_y -= 3.0 * (PI * p).sin();
                f.eye_open = 0.4;
                f.arm_l = 150.0;
                f.arm_l_len = 6.0;
                f.arm_r = 150.0;
                f.arm_r_len = 6.0;
                f.mouth_curve = 1.0;
            }
            Act::Surprise => {
                let p = (le / self.act_dur).clamp(0.0, 1.0);
                let pop = if p < 0.18 { ease_out_quad(p / 0.18) } else { 1.0 - (p - 0.18) / 0.82 };
                f.sy = 1.0 + 0.20 * pop;
                f.sx = 1.0 - 0.06 * pop;
                f.off_y -= 4.0 * pop;
                f.eye_open = 1.0 + 0.25 * pop;
                f.mouth_open = pop;
                f.rot = (3.0_f32).to_radians() * (2.0 * PI * le / 120.0).sin() * (1.0 - p);
            }
            Act::Yawn => {
                let p = (le / self.act_dur).clamp(0.0, 1.0);
                let o = if p < 0.31 { p / 0.31 } else if p < 0.62 { 1.0 } else { 1.0 - (p - 0.62) / 0.38 };
                f.sy = 1.0 + 0.12 * o;
                f.sx = 1.0 - 0.06 * o;
                f.off_y -= 1.0 * o;
                f.mouth_open = o;
                f.eye_open = 1.0 - 0.85 * o;
                f.arm_l = mixf(26.0, 120.0, o);
                f.arm_r = mixf(26.0, 120.0, o);
                f.arm_l_len = mixf(3.0, 4.5, o);
                f.arm_r_len = mixf(3.0, 4.5, o);
            }
            Act::Sleep => {
                let s = (2.0 * PI * t / 3200.0).sin();
                f.off_y = 0.8 * s;
                f.sy = 1.0 + 0.05 * s;
                f.rot = (6.0_f32).to_radians();
                f.face_yaw = 0.06;
                f.eye_open = 0.06;
                f.mouth_curve = 0.0;
                f.blush = 0.6;
            }
            Act::Wake => {
                let p = (le / self.act_dur).clamp(0.0, 1.0);
                f.eye_open = mixf(0.08, 1.15, ease_out_back((p / 0.25).min(1.0)));
                f.off_y -= 2.0 * (1.0 - p);
                f.mouth_open = 0.3 * (1.0 - p);
            }
        }

        // --- drag wobble overrides ---
        if self.dragging {
            f.skew += clampf(-self.vel_x * 0.012, -0.18, 0.18);
            f.off_y += clampf(self.vel_y * 0.02, -2.5, 2.5);
            let speed = (self.vel_x * self.vel_x + self.vel_y * self.vel_y).sqrt();
            f.sy = 1.0 + 0.04 * (speed / 30.0).min(1.0);
            f.eye_open = f.eye_open.max(1.1);
            f.pupil_dx = clampf(-self.vel_x * 0.03, -2.0, 2.0);
            f.rot += (-self.vel_x * 0.4).to_radians();
            f.arm_l = 70.0;
            f.arm_r = 70.0;
            f.arm_l_len = 5.0;
            f.arm_r_len = 5.0;
        } else if t - self.rel_start < 520.0 {
            // release bounce: damped spring back to rest
            let tt = (t - self.rel_start) / 1000.0;
            let env = (-0.35 * 22.0 * tt).exp();
            let osc = (22.0 * (1.0f32 - 0.35 * 0.35).sqrt() * tt).cos();
            f.skew += self.rel_amp_x * 0.01 * env * osc;
            f.off_y += self.rel_amp_y * 0.02 * env * osc;
        }

        // --- blink overlay (eyes only) ---
        let bdt = t - self.blink_start;
        if bdt >= 0.0 && bdt < 150.0 {
            let bp = bdt / 150.0;
            let close = if bp < 0.47 { ease_in_quad(bp / 0.47) } else { 1.0 - ease_out_quad((bp - 0.47) / 0.53) };
            f.eye_open = f.eye_open.min(1.0 - 0.94 * close);
        } else if self.blink_double && bdt >= 190.0 && bdt < 340.0 {
            let bp = (bdt - 190.0) / 150.0;
            let close = if bp < 0.47 { ease_in_quad(bp / 0.47) } else { 1.0 - ease_out_quad((bp - 0.47) / 0.53) };
            f.eye_open = f.eye_open.min(1.0 - 0.94 * close);
        }

        // contact shadow follows the hop height
        let lift = (-f.off_y).max(0.0);
        f.shadow_rx = 16.0 + lift * 0.7;
        f.shadow_a = mixf(0.30, 0.12, (lift / 12.0).min(1.0));
        f
    }
}

fn hop_frame(f: &mut Frame, le: f32) {
    // 0-110 antic, 110-150 launch, 150-470 air, 470-560 land, 560-640 rebound
    if le < 110.0 {
        let p = le / 110.0;
        f.sy *= mixf(1.0, 0.84, p);
        f.sx *= mixf(1.0, 1.10, p);
        f.off_y += 2.0 * p;
        f.eye_open = mixf(1.0, 0.7, p);
        f.arm_l = 18.0;
        f.arm_r = 18.0;
    } else if le < 150.0 {
        f.sy *= 1.16;
        f.sx *= 0.92;
        f.arm_l = 150.0;
        f.arm_r = 150.0;
        f.arm_l_len = 7.0;
        f.arm_r_len = 7.0;
    } else if le < 470.0 {
        let p = (le - 150.0) / 320.0;
        f.off_y -= 11.0 * (PI * p).sin();
        f.arm_l = 150.0;
        f.arm_r = 150.0;
        f.arm_l_len = 7.0;
        f.arm_r_len = 7.0;
    } else if le < 560.0 {
        let p = (le - 470.0) / 90.0;
        f.sy *= mixf(1.0, 0.84, 1.0 - (p - 0.5).abs() * 2.0);
        f.sx *= mixf(1.0, 1.10, 1.0 - (p - 0.5).abs() * 2.0);
        f.off_y += 1.5 * (1.0 - (p - 0.5).abs() * 2.0);
        f.eye_open = 0.78;
    } else {
        let p = (le - 560.0) / 80.0;
        let s = ease_out_back(p);
        f.sy *= mixf(0.84, 1.0, s);
        f.sx *= mixf(1.10, 1.0, s);
    }
}

// ---------------------------------------------------------------------------
// Window / Win32 plumbing
// ---------------------------------------------------------------------------
struct State {
    hwnd: HWND,
    screen_dc: HDC,
    mem_dc: HDC,
    bitmap: HBITMAP,
    default_bitmap: HGDIOBJ,
    bits: *mut u32,
    size: i32,
    x: i32,
    y: i32,
    start: Instant,
    anim: Anim,
    dragging: bool,
    drag_anchor: POINT,
    win_anchor: (i32, i32),
    last_cursor: POINT,
    wheel_accum: i32,
}

static mut STATE: *mut State = null_mut();

impl State {
    unsafe fn make_dib(&mut self, size: i32) {
        let mut bmi: BITMAPINFO = zeroed();
        bmi.bmiHeader.biSize = size_of::<BITMAPINFOHEADER>() as u32;
        bmi.bmiHeader.biWidth = size;
        bmi.bmiHeader.biHeight = -size;
        bmi.bmiHeader.biPlanes = 1;
        bmi.bmiHeader.biBitCount = 32;
        bmi.bmiHeader.biCompression = 0;
        let mut bits: *mut core::ffi::c_void = null_mut();
        let bitmap = CreateDIBSection(self.mem_dc, &bmi, DIB_RGB_COLORS, &mut bits, null_mut(), 0);
        let prev = SelectObject(self.mem_dc, bitmap as HGDIOBJ);
        if self.default_bitmap.is_null() {
            self.default_bitmap = prev;
        }
        if !self.bitmap.is_null() {
            DeleteObject(self.bitmap as HGDIOBJ);
        }
        self.bitmap = bitmap;
        self.bits = bits as *mut u32;
        self.size = size;
    }

    unsafe fn resize_to(&mut self, new_size: i32) {
        let s = new_size.clamp(MIN_SIZE, MAX_SIZE);
        if s == self.size {
            return;
        }
        self.x += (self.size - s) / 2;
        self.y += (self.size - s) / 2;
        self.make_dib(s);
        self.render();
    }

    unsafe fn render(&mut self) {
        let t = self.start.elapsed().as_secs_f32() * 1000.0;
        self.anim.update(t);
        let f = self.anim.frame(t);
        let buf = std::slice::from_raw_parts_mut(self.bits, (self.size * self.size) as usize);
        paint(buf, self.size, &f, &self.anim.particles);

        let blend = BLENDFUNCTION {
            BlendOp: AC_SRC_OVER as u8,
            BlendFlags: 0,
            SourceConstantAlpha: 255,
            AlphaFormat: AC_SRC_ALPHA as u8,
        };
        let size = SIZE { cx: self.size, cy: self.size };
        let src = POINT { x: 0, y: 0 };
        let dst = POINT { x: self.x, y: self.y };
        UpdateLayeredWindow(
            self.hwnd, self.screen_dc, &dst, &size, self.mem_dc, &src, 0, &blend, ULW_ALPHA,
        );
    }
}

unsafe extern "system" fn wndproc(hwnd: HWND, msg: u32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
    if STATE.is_null() {
        return DefWindowProcW(hwnd, msg, wparam, lparam);
    }
    let st = &mut *STATE;
    let t = st.start.elapsed().as_secs_f32() * 1000.0;

    match msg {
        WM_TIMER => {
            st.render();
            0
        }
        WM_LBUTTONDOWN => {
            SetForegroundWindow(hwnd);
            SetFocus(hwnd);
            SetCapture(hwnd);
            let mut p: POINT = zeroed();
            GetCursorPos(&mut p);
            st.drag_anchor = p;
            st.last_cursor = p;
            st.win_anchor = (st.x, st.y);
            st.dragging = true;
            st.anim.dragging = true;
            st.anim.interacted(t);
            st.anim.start(Act::Surprise, t, 480.0);
            0
        }
        WM_MOUSEMOVE => {
            if st.dragging {
                let mut p: POINT = zeroed();
                GetCursorPos(&mut p);
                st.x = st.win_anchor.0 + (p.x - st.drag_anchor.x);
                st.y = st.win_anchor.1 + (p.y - st.drag_anchor.y);
                // low-pass velocity for the wobble
                let vx = (p.x - st.last_cursor.x) as f32;
                let vy = (p.y - st.last_cursor.y) as f32;
                st.anim.vel_x = mixf(st.anim.vel_x, vx, 0.4);
                st.anim.vel_y = mixf(st.anim.vel_y, vy, 0.4);
                st.last_cursor = p;
                st.anim.interacted(t);
                st.render();
            }
            0
        }
        WM_LBUTTONUP => {
            if st.dragging {
                st.dragging = false;
                st.anim.dragging = false;
                ReleaseCapture();
                st.anim.rel_start = t;
                st.anim.rel_amp_x = st.anim.vel_x;
                st.anim.rel_amp_y = st.anim.vel_y;
                let moved = (st.x - st.win_anchor.0).abs() + (st.y - st.win_anchor.1).abs();
                if moved < 3 {
                    st.anim.start(Act::Hop, t, 640.0); // a poke -> happy hop
                } else {
                    st.anim.act = Act::Idle;
                }
                st.anim.vel_x = 0.0;
                st.anim.vel_y = 0.0;
            }
            0
        }
        WM_RBUTTONDOWN => {
            PostQuitMessage(0);
            0
        }
        WM_MOUSEWHEEL => {
            let delta = ((wparam >> 16) as u16) as i16 as i32;
            st.wheel_accum += delta;
            let steps = st.wheel_accum / 120;
            if steps != 0 {
                st.wheel_accum -= steps * 120;
                st.resize_to(st.size + steps * 16);
            }
            st.anim.interacted(t);
            0
        }
        WM_KEYDOWN => {
            let vk = wparam as u16;
            st.anim.interacted(t);
            if vk == VK_ESCAPE {
                PostQuitMessage(0);
                0
            } else if vk == VK_OEM_PLUS || vk == VK_ADD {
                st.resize_to(st.size + 24);
                0
            } else if vk == VK_OEM_MINUS || vk == VK_SUBTRACT {
                st.resize_to(st.size - 24);
                0
            } else if vk == VK_SPACE {
                st.anim.start(Act::Spin, t, 720.0); // space = do a trick!
                st.anim.spawn_sparkles(6, 0);
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
            x, y, size, size,
            null_mut(), null_mut(), hinstance, null(),
        );
        if hwnd.is_null() {
            return;
        }

        let mut state = Box::new(State {
            hwnd,
            screen_dc: GetDC(null_mut()),
            mem_dc: CreateCompatibleDC(null_mut()),
            bitmap: null_mut(),
            default_bitmap: null_mut(),
            bits: null_mut(),
            size,
            x,
            y,
            start: Instant::now(),
            anim: Anim::new(),
            dragging: false,
            drag_anchor: zeroed(),
            win_anchor: (x, y),
            last_cursor: zeroed(),
            wheel_accum: 0,
        });
        state.make_dib(size);
        STATE = &mut *state;

        ShowWindow(hwnd, SW_SHOWNOACTIVATE);
        SetForegroundWindow(hwnd);
        SetFocus(hwnd);
        state.render();
        SetTimer(hwnd, 1, 16, None); // ~60fps

        let mut msg: MSG = zeroed();
        while GetMessageW(&mut msg, null_mut(), 0, 0) > 0 {
            TranslateMessage(&msg);
            DispatchMessageW(&msg);
        }

        KillTimer(hwnd, 1);
        if !state.default_bitmap.is_null() {
            SelectObject(state.mem_dc, state.default_bitmap);
        }
        if !state.bitmap.is_null() {
            DeleteObject(state.bitmap as HGDIOBJ);
        }
        DeleteDC(state.mem_dc);
        ReleaseDC(null_mut(), state.screen_dc);
        STATE = null_mut();
    }
}
