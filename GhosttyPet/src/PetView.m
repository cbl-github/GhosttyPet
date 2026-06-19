#import "PetView.h"
#include <math.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

// "Boo", a cute Ghostty ghost. The ghost lives in a 64x64 design-unit space and
// is drawn each frame by a small signed-distance-field rasterizer with
// super-sampled anti-aliasing, so it stays smooth and cute at any size. The
// premultiplied-BGRA buffer is blitted as a single CGImage in -drawRect:. A
// 60fps animation state machine gives it life (float, blink, glance, hop, wave,
// wiggle, tilt, spin, click/drag reactions, drowsy sleep). This is the exact
// same design and math as the Windows build (GhosttyPetWin/src/main.rs).

// ---------------------------------------------------------------------------
// Palette (straight-alpha RGB; alpha supplied per use).
// ---------------------------------------------------------------------------
static const float RIM[3] = {0x1B / 255.0f, 0x6F / 255.0f, 0xF0 / 255.0f};
static const float RIM_HI[3] = {0x6E / 255.0f, 0x93 / 255.0f, 0xFF / 255.0f};
static const float INNER[3] = {0x2B / 255.0f, 0x2F / 255.0f, 0x8C / 255.0f};
static const float WHITE[3] = {0xF8 / 255.0f, 0xFB / 255.0f, 0xFF / 255.0f};
static const float SHADE[3] = {0xDC / 255.0f, 0xE7 / 255.0f, 0xF5 / 255.0f};
static const float EYE[3] = {0x16 / 255.0f, 0x1A / 255.0f, 0x33 / 255.0f};
static const float MOUTH_PINK[3] = {0xE9 / 255.0f, 0x6A / 255.0f, 0x8B / 255.0f};
static const float BLUSH[3] = {0xFF / 255.0f, 0x9D / 255.0f, 0xB4 / 255.0f};
static const float SPARK[3] = {0x8F / 255.0f, 0xD0 / 255.0f, 0xFF / 255.0f};
static const float SHADOW[3] = {0x14 / 255.0f, 0x1A / 255.0f, 0x40 / 255.0f};
static const float PUREWHITE[3] = {1.0f, 1.0f, 1.0f};
static const float ZCOLOR[3] = {0.7f, 0.85f, 1.0f};

static const CGFloat kMinPetSize = 80.0;
static const CGFloat kMaxPetSize = 480.0;

#define ANCHOR_X 32.0f
#define ANCHOR_Y 50.0f
#define GROUND_Y 51.0f

// ---------------------------------------------------------------------------
// Small math helpers
// ---------------------------------------------------------------------------
static inline float clampf(float x, float a, float b) { return x < a ? a : (x > b ? b : x); }
static inline float mixf(float a, float b, float t) { return a + (b - a) * t; }
static inline float smoothstep(float e0, float e1, float x) {
  float t = clampf((x - e0) / (e1 - e0), 0.0f, 1.0f);
  return t * t * (3.0f - 2.0f * t);
}
static inline float ease_in_quad(float t) { return t * t; }
static inline float ease_out_quad(float t) { return 1.0f - (1.0f - t) * (1.0f - t); }
static inline float ease_out_cubic(float t) { float u = 1.0f - t; return 1.0f - u * u * u; }
static inline float ease_out_back(float t) {
  float c1 = 1.70158f, c3 = c1 + 1.0f, u = t - 1.0f;
  return 1.0f + c3 * u * u * u + c1 * u * u;
}
static inline float ease_in_out_back(float t) {
  if (t < 0.5f) {
    float a = 2.0f * t;
    return a * a * (3.6f * a - 2.6f) / 2.0f;
  } else {
    float u = 2.0f * t - 2.0f;
    return (u * u * (3.6f * u + 2.6f) + 2.0f) / 2.0f;
  }
}

static inline float sd_circle(float px, float py, float cx, float cy, float r) {
  float dx = px - cx, dy = py - cy;
  return sqrtf(dx * dx + dy * dy) - r;
}
static inline float sd_round_box(float px, float py, float cx, float cy, float hx, float hy, float r) {
  float dx = fabsf(px - cx) - (hx - r);
  float dy = fabsf(py - cy) - (hy - r);
  float ox = fmaxf(dx, 0.0f), oy = fmaxf(dy, 0.0f);
  return sqrtf(ox * ox + oy * oy) + fminf(fmaxf(dx, dy), 0.0f) - r;
}
static inline float sd_segment(float px, float py, float ax, float ay, float bx, float by, float r) {
  float pax = px - ax, pay = py - ay, bax = bx - ax, bay = by - ay;
  float denom = bax * bax + bay * bay;
  float h = denom > 0.0f ? clampf((pax * bax + pay * bay) / denom, 0.0f, 1.0f) : 0.0f;
  float dx = pax - bax * h, dy = pay - bay * h;
  return sqrtf(dx * dx + dy * dy) - r;
}
static inline float sd_ellipse(float px, float py, float cx, float cy, float rx, float ry) {
  float nx = (px - cx) / rx, ny = (py - cy) / ry;
  float k = sqrtf(nx * nx + ny * ny);
  return (k - 1.0f) * fminf(rx, ry);
}

typedef struct { float r, g, b, a; } Col;
static inline Col over_col(Col dst, Col src) {
  float ia = 1.0f - src.a;
  Col o = {src.r + dst.r * ia, src.g + dst.g * ia, src.b + dst.b * ia, src.a + dst.a * ia};
  return o;
}
static inline Col lay(const float c[3], float a) {
  Col o = {c[0] * a, c[1] * a, c[2] * a, a};
  return o;
}

// ---------------------------------------------------------------------------
// Per-frame parameters the rasterizer reads.
// ---------------------------------------------------------------------------
typedef struct {
  float offX, offY, sx, sy, skew, rot, faceYaw;
  float eyeOpen, pupilDx, pupilDy, mouthOpen, mouthCurve, blush;
  float armL, armLLen, armR, armRLen;
  float shadowRx, shadowA;
} Frame;

static Frame frame_idle(void) {
  Frame f = {0};
  f.sx = 1.0f; f.sy = 1.0f;
  f.eyeOpen = 1.0f; f.mouthCurve = 1.0f; f.blush = 1.0f;
  f.armL = 26.0f; f.armLLen = 3.0f; f.armR = 26.0f; f.armRLen = 3.0f;
  f.shadowRx = 16.0f; f.shadowA = 0.27f;
  return f;
}

typedef struct { float x, y, vx, vy, age, life; unsigned char kind; } Particle;

// ---------------------------------------------------------------------------
// Rasterizer
// ---------------------------------------------------------------------------
static void inverse_transform(float px, float py, const Frame *f, float *ox, float *oy) {
  float x = px - f->offX;
  float y = py - f->offY;
  if (f->rot != 0.0f) {
    float s = sinf(-f->rot), c = cosf(-f->rot);
    float ax = x - ANCHOR_X, ay = y - ANCHOR_Y;
    x = ANCHOR_X + ax * c - ay * s;
    y = ANCHOR_Y + ax * s + ay * c;
  }
  x -= f->skew * (y - ANCHOR_Y);
  x = ANCHOR_X + (x - ANCHOR_X) / f->sx;
  y = ANCHOR_Y + (y - ANCHOR_Y) / f->sy;
  *ox = x; *oy = y;
}

static void arm_hand(float shx, float shy, float angDeg, float len, float side, float *hx, float *hy) {
  float a = angDeg * (float)M_PI / 180.0f;
  *hx = shx + side * len * sinf(a);
  *hy = shy + len * cosf(a);
}

static float body_sdf(float mx, float my, const Frame *f) {
  float d = sd_circle(mx, my, 32.0f, 22.0f, 13.0f);
  d = fminf(d, sd_round_box(mx, my, 32.0f, 33.5f, 13.0f, 12.5f, 5.0f));
  d = fminf(d, sd_circle(mx, my, 23.33f, 45.5f, 4.4f));
  d = fminf(d, sd_circle(mx, my, 32.0f, 46.0f, 5.0f));
  d = fminf(d, sd_circle(mx, my, 40.67f, 45.5f, 4.4f));
  float lhx, lhy, rhx, rhy;
  arm_hand(20.0f, 37.0f, f->armL, f->armLLen, -1.0f, &lhx, &lhy);
  arm_hand(44.0f, 37.0f, f->armR, f->armRLen, 1.0f, &rhx, &rhy);
  d = fminf(d, sd_segment(mx, my, 20.0f, 37.0f, lhx, lhy, 3.1f));
  d = fminf(d, sd_segment(mx, my, 44.0f, 37.0f, rhx, rhy, 3.1f));
  return d;
}

static Col shade_px(float px, float py, const Frame *f) {
  Col acc = {0, 0, 0, 0};
  float aa = 0.6f;

  float sdv = sd_ellipse(px, py, 32.0f, GROUND_Y, f->shadowRx, 4.0f);
  float scov = smoothstep(aa, -aa, sdv);
  if (scov > 0.0f) acc = over_col(acc, lay(SHADOW, scov * f->shadowA));

  float mx, my;
  inverse_transform(px, py, f, &mx, &my);

  if (mx > -8.0f && mx < 72.0f && my > -8.0f && my < 60.0f) {
    float d = body_sdf(mx, my, f);
    float cov = smoothstep(aa, -aa, d);
    if (cov > 0.0f) {
      float shadeAmt = smoothstep(0.0f, 26.0f, my - mx * 0.25f) * 0.16f;
      float col[3] = {mixf(WHITE[0], SHADE[0], shadeAmt), mixf(WHITE[1], SHADE[1], shadeAmt),
                      mixf(WHITE[2], SHADE[2], shadeAmt)};
      float hd = sqrtf((mx - 25.0f) * (mx - 25.0f) + (my - 17.0f) * (my - 17.0f));
      float hi = (1.0f - smoothstep(0.0f, 11.0f, hd)) * 0.28f;
      col[0] = mixf(col[0], 1.0f, hi); col[1] = mixf(col[1], 1.0f, hi); col[2] = mixf(col[2], 1.0f, hi);
      float inner = smoothstep(-3.6f, -2.2f, d) * 0.35f;
      col[0] = mixf(col[0], INNER[0], inner); col[1] = mixf(col[1], INNER[1], inner); col[2] = mixf(col[2], INNER[2], inner);
      float rimt = smoothstep(-2.2f, -0.4f, d);
      float rimLit = smoothstep(0.0f, 18.0f, (32.0f - mx) + (22.0f - my));
      float rimCol[3] = {mixf(RIM[0], RIM_HI[0], rimLit), mixf(RIM[1], RIM_HI[1], rimLit),
                         mixf(RIM[2], RIM_HI[2], rimLit)};
      col[0] = mixf(col[0], rimCol[0], rimt); col[1] = mixf(col[1], rimCol[1], rimt); col[2] = mixf(col[2], rimCol[2], rimt);
      acc = over_col(acc, lay(col, cov));

      float fy = f->faceYaw * 6.0f;
      for (int si = 0; si < 2; si++) {
        float s = si == 0 ? -1.0f : 1.0f;
        float bd = sd_ellipse(mx, my, 32.0f + s * 13.0f + fy, 37.0f, 3.6f, 2.3f);
        float bc = smoothstep(1.2f, -1.2f, bd);
        if (bc > 0.0f) acc = over_col(acc, lay(BLUSH, bc * 0.55f * f->blush * cov));
      }
      float eo = clampf(f->eyeOpen, 0.0f, 1.3f);
      for (int si = 0; si < 2; si++) {
        float s = si == 0 ? -1.0f : 1.0f;
        float ex = 32.0f + s * 9.0f + fy + f->pupilDx * 0.6f;
        float ey = 30.0f + f->pupilDy * 0.6f;
        if (eo > 0.12f) {
          float ed = sd_ellipse(mx, my, ex, ey, 3.4f, 4.8f * eo);
          float ec = smoothstep(0.8f, -0.8f, ed);
          if (ec > 0.0f) acc = over_col(acc, lay(EYE, ec * cov));
          if (eo > 0.45f) {
            float cd = sd_circle(mx, my, ex - 1.2f, ey - 1.7f, 1.4f);
            acc = over_col(acc, lay(PUREWHITE, smoothstep(0.6f, -0.6f, cd) * cov));
            float cd2 = sd_circle(mx, my, ex + 1.1f, ey + 1.6f, 0.8f);
            acc = over_col(acc, lay(PUREWHITE, smoothstep(0.5f, -0.5f, cd2) * 0.8f * cov));
          }
        } else {
          float ld = fabsf(sd_circle(mx, my, ex, ey - 2.6f, 3.6f)) - 0.7f;
          float lc = smoothstep(0.6f, -0.6f, ld) * smoothstep(-2.0f, 0.0f, my - ey);
          acc = over_col(acc, lay(EYE, lc * cov));
        }
      }
      float mxx = 32.0f + fy;
      if (f->mouthOpen > 0.05f) {
        float md = sd_ellipse(mx, my, mxx, 40.0f, 2.2f + f->mouthOpen, 1.8f + 3.0f * f->mouthOpen);
        acc = over_col(acc, lay(MOUTH_PINK, smoothstep(0.7f, -0.7f, md) * cov));
        float rimM = smoothstep(0.9f, 0.0f, fabsf(md));
        acc = over_col(acc, lay(EYE, rimM * 0.8f * cov));
      } else {
        float cyc = 39.0f - f->mouthCurve * 2.4f;
        float md = fabsf(sd_circle(mx, my, mxx, cyc, 3.0f)) - 0.75f;
        float side = f->mouthCurve >= 0.0f ? smoothstep(-1.5f, 0.5f, my - cyc)
                                           : smoothstep(1.5f, -0.5f, my - cyc);
        float mc = smoothstep(0.6f, -0.6f, md) * side * smoothstep(3.4f, 2.0f, fabsf(mx - mxx));
        acc = over_col(acc, lay(EYE, mc * cov));
      }
    }
  }
  return acc;
}

static inline uint32_t pack(Col c) {
  float a = clampf(c.a, 0.0f, 1.0f);
  uint32_t r = (uint32_t)(clampf(c.r, 0.0f, a) * 255.0f + 0.5f);
  uint32_t g = (uint32_t)(clampf(c.g, 0.0f, a) * 255.0f + 0.5f);
  uint32_t b = (uint32_t)(clampf(c.b, 0.0f, a) * 255.0f + 0.5f);
  uint32_t a8 = (uint32_t)(a * 255.0f + 0.5f);
  return (a8 << 24) | (r << 16) | (g << 8) | b;
}

static Col unpack(uint32_t v) {
  Col c = {((v >> 16) & 0xff) / 255.0f, ((v >> 8) & 0xff) / 255.0f, (v & 0xff) / 255.0f,
           ((v >> 24) & 0xff) / 255.0f};
  return c;
}

static void paint_ghost(uint32_t *buf, int size, const Frame *f, const Particle *particles, int pcount) {
  memset(buf, 0, (size_t)size * size * 4);
  float scale = size / 64.0f;
  int ss = size <= 192 ? 3 : 2;
  float inv = 1.0f / (float)(ss * ss);
  for (int py = 0; py < size; py++) {
    for (int px = 0; px < size; px++) {
      Col acc = {0, 0, 0, 0};
      for (int sy = 0; sy < ss; sy++) {
        for (int sx = 0; sx < ss; sx++) {
          float dx = (px + (sx + 0.5f) / ss) / scale;
          float dy = (py + (sy + 0.5f) / ss) / scale;
          Col c = shade_px(dx, dy, f);
          acc.r += c.r; acc.g += c.g; acc.b += c.b; acc.a += c.a;
        }
      }
      Col mean = {acc.r * inv, acc.g * inv, acc.b * inv, acc.a * inv};
      buf[py * size + px] = pack(mean);
    }
  }
  for (int i = 0; i < pcount; i++) {
    const Particle *p = &particles[i];
    float t = p->age / p->life;
    if (t >= 1.0f) continue;
    float a = (1.0f - t) * 0.9f;
    const float *col = p->kind == 0 ? SPARK : ZCOLOR;
    float r = p->kind == 0 ? 2.0f : 2.6f;
    int cxp = (int)(p->x * scale), cyp = (int)(p->y * scale);
    int rr = (int)ceilf(r * scale) + 1;
    int y0 = cyp - rr < 0 ? 0 : cyp - rr, y1 = cyp + rr > size ? size : cyp + rr;
    int x0 = cxp - rr < 0 ? 0 : cxp - rr, x1 = cxp + rr > size ? size : cxp + rr;
    for (int yy = y0; yy < y1; yy++) {
      for (int xx = x0; xx < x1; xx++) {
        float ddx = (xx + 0.5f) / scale - p->x;
        float ddy = (yy + 0.5f) / scale - p->y;
        float dist = sqrtf(ddx * ddx + ddy * ddy);
        float cross = (1.0f - smoothstep(0.0f, r, fabsf(ddx))) * (1.0f - smoothstep(0.0f, r * 0.35f, fabsf(ddy))) +
                      (1.0f - smoothstep(0.0f, r, fabsf(ddy))) * (1.0f - smoothstep(0.0f, r * 0.35f, fabsf(ddx)));
        float core = 1.0f - smoothstep(0.0f, r * 0.5f, dist);
        float cov = clampf(cross + core, 0.0f, 1.0f) * a;
        if (cov > 0.0f) {
          int idx = yy * size + xx;
          buf[idx] = pack(over_col(unpack(buf[idx]), lay(col, cov)));
        }
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Animation state machine (mirrors GhosttyPetWin/src/main.rs)
// ---------------------------------------------------------------------------
typedef enum { ActIdle, ActLook, ActHop, ActWave, ActWiggle, ActTilt, ActSpin, ActSurprise, ActYawn, ActSleep, ActWake } Act;

#define MAX_PARTICLES 40
typedef struct {
  uint32_t rng;
  Act act;
  float actStart, actDur, lookDir, nextAct, nextBlink, blinkStart;
  int blinkDouble;
  float lastInteract;
  Particle particles[MAX_PARTICLES];
  int pcount;
  float lastSpawn, prevT;
  int dragging;
  float velX, velY, relStart, relAmpX, relAmpY;
} Anim;

static uint32_t xs(uint32_t *s) {
  uint32_t x = *s;
  x ^= x << 13; x ^= x >> 17; x ^= x << 5;
  *s = x; return x;
}
static float randf(uint32_t *s) { return (float)xs(s) / (float)UINT32_MAX; }
static float randr(uint32_t *s, float a, float b) { return a + (b - a) * randf(s); }

static void anim_init(Anim *a) {
  memset(a, 0, sizeof(*a));
  a->rng = (arc4random() | 1u);
  a->act = ActWave;
  a->actDur = 1100.0f;
  a->lookDir = 1.0f;
  a->nextAct = 2600.0f;
  a->nextBlink = 1800.0f;
  a->blinkStart = -999.0f;
  a->relStart = -999.0f;
}
static void anim_start(Anim *a, Act act, float t, float dur) {
  a->act = act; a->actStart = t; a->actDur = dur;
}
static void anim_interacted(Anim *a, float t) {
  a->lastInteract = t;
  if (a->act == ActSleep || a->act == ActYawn) anim_start(a, ActWake, t, 480.0f);
}
static void anim_spawn(Anim *a, int n, unsigned char kind) {
  for (int i = 0; i < n && a->pcount < MAX_PARTICLES; i++) {
    float ang = randr(&a->rng, 0.0f, 2.0f * (float)M_PI);
    float sp = randr(&a->rng, 0.2f, 0.6f);
    Particle p = {32.0f + randr(&a->rng, -12.0f, 12.0f), 26.0f + randr(&a->rng, -10.0f, 8.0f),
                  cosf(ang) * sp, sinf(ang) * sp - 0.2f, 0.0f, randr(&a->rng, 600.0f, 1000.0f), kind};
    a->particles[a->pcount++] = p;
  }
}

static void anim_update(Anim *a, float t) {
  float dt = clampf(t - a->prevT, 0.0f, 100.0f);
  a->prevT = t;

  for (int i = 0; i < a->pcount; i++) {
    a->particles[i].x += a->particles[i].vx * dt * 0.06f;
    a->particles[i].y += a->particles[i].vy * dt * 0.06f;
    a->particles[i].age += dt;
  }
  int w = 0;
  for (int i = 0; i < a->pcount; i++)
    if (a->particles[i].age < a->particles[i].life) a->particles[w++] = a->particles[i];
  a->pcount = w;

  if (a->act != ActSleep && t >= a->nextBlink) {
    a->blinkStart = t;
    a->blinkDouble = randf(&a->rng) < 0.15f;
    a->nextBlink = t + randr(&a->rng, 2500.0f, 6000.0f);
  }

  float elapsed = t - a->actStart;
  int done = (a->act != ActIdle && a->act != ActSleep) && elapsed >= a->actDur;
  if (done) {
    if (a->act == ActYawn) {
      anim_start(a, ActSleep, t, 1.0e9f);
    } else if (a->act == ActWake) {
      a->act = ActIdle; a->lastInteract = t; a->nextAct = t + randr(&a->rng, 1500.0f, 4000.0f);
    } else {
      a->act = ActIdle; a->nextAct = t + randr(&a->rng, 1500.0f, 4000.0f);
    }
  }

  if (a->act == ActIdle && !a->dragging && t - a->lastInteract > 22000.0f)
    anim_start(a, ActYawn, t, 1300.0f);

  if (a->act == ActIdle && !a->dragging && t >= a->nextAct) {
    float r = randf(&a->rng);
    if (r < 0.26f) anim_start(a, ActHop, t, 640.0f);
    else if (r < 0.48f) { a->lookDir = randf(&a->rng) < 0.5f ? -1.0f : 1.0f; anim_start(a, ActLook, t, 1400.0f); }
    else if (r < 0.62f) { anim_start(a, ActWiggle, t, 850.0f); anim_spawn(a, 3, 0); }
    else if (r < 0.74f) anim_start(a, ActWave, t, 1100.0f);
    else if (r < 0.82f) anim_start(a, ActTilt, t, 900.0f);
    else if (r < 0.86f) { anim_start(a, ActSpin, t, 720.0f); anim_spawn(a, 6, 0); }
    else a->nextAct = t + randr(&a->rng, 1200.0f, 2600.0f);
  }

  if (a->act == ActSleep && t - a->lastSpawn > 1500.0f && a->pcount < MAX_PARTICLES) {
    a->lastSpawn = t;
    Particle p = {40.0f, 18.0f, 0.25f, -0.5f, 0.0f, 1400.0f, 1};
    a->particles[a->pcount++] = p;
  }
}

static void hop_frame(Frame *f, float le) {
  if (le < 110.0f) {
    float p = le / 110.0f;
    f->sy *= mixf(1.0f, 0.84f, p); f->sx *= mixf(1.0f, 1.10f, p);
    f->offY += 2.0f * p; f->eyeOpen = mixf(1.0f, 0.7f, p);
    f->armL = 18.0f; f->armR = 18.0f;
  } else if (le < 150.0f) {
    f->sy *= 1.16f; f->sx *= 0.92f;
    f->armL = 150.0f; f->armR = 150.0f; f->armLLen = 7.0f; f->armRLen = 7.0f;
  } else if (le < 470.0f) {
    float p = (le - 150.0f) / 320.0f;
    f->offY -= 11.0f * sinf((float)M_PI * p);
    f->armL = 150.0f; f->armR = 150.0f; f->armLLen = 7.0f; f->armRLen = 7.0f;
  } else if (le < 560.0f) {
    float p = (le - 470.0f) / 90.0f, k = 1.0f - fabsf(p - 0.5f) * 2.0f;
    f->sy *= mixf(1.0f, 0.84f, k); f->sx *= mixf(1.0f, 1.10f, k);
    f->offY += 1.5f * k; f->eyeOpen = 0.78f;
  } else {
    float p = (le - 560.0f) / 80.0f, s = ease_out_back(p);
    f->sy *= mixf(0.84f, 1.0f, s); f->sx *= mixf(1.10f, 1.0f, s);
  }
}

static Frame anim_frame(const Anim *a, float t) {
  Frame f = frame_idle();
  float bob = sinf(2.0f * (float)M_PI * t / 2600.0f);
  f.offY = 1.5f * bob;
  f.sy = 1.0f - 0.025f * bob;
  f.sx = 1.0f + 0.025f * bob;
  f.offX = 4.0f * sinf(2.0f * (float)M_PI * t / 5600.0f);
  f.skew = 0.015f * sinf(2.0f * (float)M_PI * t / 4300.0f);
  f.pupilDx = 0.4f * sinf(2.0f * (float)M_PI * t / 5600.0f);

  float le = t - a->actStart;
  switch (a->act) {
    case ActIdle: break;
    case ActLook: {
      float p = clampf(le / a->actDur, 0.0f, 1.0f);
      float amt = p < 0.25f ? ease_out_cubic(p / 0.25f) : (p < 0.65f ? 1.0f : 1.0f - ease_out_cubic((p - 0.65f) / 0.35f));
      f.pupilDx = a->lookDir * 1.4f * amt; f.pupilDy = -0.3f * amt;
      f.faceYaw = a->lookDir * 0.10f * amt; f.offX += a->lookDir * 1.2f * amt;
    } break;
    case ActHop: hop_frame(&f, le); break;
    case ActWave: {
      float p = clampf(le / a->actDur, 0.0f, 1.0f);
      float raise = ease_out_back(fminf(p / 0.16f, 1.0f));
      f.armR = mixf(26.0f, 152.0f, raise);
      f.armRLen = mixf(3.0f, 10.0f, raise);
      if (p > 0.16f && p < 0.82f) f.armR += 18.0f * sinf(2.0f * (float)M_PI * (le - 180.0f) / 300.0f);
      if (p >= 0.82f) { float q = (p - 0.82f) / 0.18f; f.armR = mixf(f.armR, 26.0f, q); f.armRLen = mixf(10.0f, 3.0f, q); }
      f.skew -= 0.04f * fmaxf(1.0f - fabsf(p - 0.5f) * 2.0f, 0.0f);
      f.faceYaw -= 0.06f; f.eyeOpen = 0.7f; f.mouthCurve = 1.0f; f.blush = 1.3f;
      f.offY -= 1.0f * sinf((float)M_PI * p);
    } break;
    case ActWiggle: {
      float p = clampf(le / a->actDur, 0.0f, 1.0f);
      f.rot = (6.0f * (float)M_PI / 180.0f) * sinf(2.0f * (float)M_PI * le / 140.0f) * (1.0f - p);
      f.eyeOpen = 0.55f; f.mouthCurve = 1.0f; f.blush = 1.35f;
    } break;
    case ActTilt: {
      float p = clampf(le / a->actDur, 0.0f, 1.0f);
      float amt = p < 0.28f ? ease_out_cubic(p / 0.28f) : (p < 0.72f ? 1.0f : 1.0f - ease_out_cubic((p - 0.72f) / 0.28f));
      f.rot = (11.0f * (float)M_PI / 180.0f) * amt; f.faceYaw = 0.05f * amt;
      f.pupilDy = -0.6f * amt; f.mouthOpen = 0.25f * amt;
    } break;
    case ActSpin: {
      float p = clampf(le / a->actDur, 0.0f, 1.0f);
      f.rot = ease_in_out_back(p) * 2.0f * (float)M_PI;
      float pulse = cosf(2.0f * (float)M_PI * p);
      f.sx = 1.0f + 0.12f * pulse; f.sy = 1.0f - 0.12f * pulse;
      f.offY -= 3.0f * sinf((float)M_PI * p); f.eyeOpen = 0.4f;
      f.armL = 150.0f; f.armLLen = 6.0f; f.armR = 150.0f; f.armRLen = 6.0f; f.mouthCurve = 1.0f;
    } break;
    case ActSurprise: {
      float p = clampf(le / a->actDur, 0.0f, 1.0f);
      float pop = p < 0.18f ? ease_out_quad(p / 0.18f) : 1.0f - (p - 0.18f) / 0.82f;
      f.sy = 1.0f + 0.20f * pop; f.sx = 1.0f - 0.06f * pop; f.offY -= 4.0f * pop;
      f.eyeOpen = 1.0f + 0.25f * pop; f.mouthOpen = pop;
      f.rot = (3.0f * (float)M_PI / 180.0f) * sinf(2.0f * (float)M_PI * le / 120.0f) * (1.0f - p);
    } break;
    case ActYawn: {
      float p = clampf(le / a->actDur, 0.0f, 1.0f);
      float o = p < 0.31f ? p / 0.31f : (p < 0.62f ? 1.0f : 1.0f - (p - 0.62f) / 0.38f);
      f.sy = 1.0f + 0.12f * o; f.sx = 1.0f - 0.06f * o; f.offY -= 1.0f * o;
      f.mouthOpen = o; f.eyeOpen = 1.0f - 0.85f * o;
      f.armL = mixf(26.0f, 120.0f, o); f.armR = mixf(26.0f, 120.0f, o);
      f.armLLen = mixf(3.0f, 4.5f, o); f.armRLen = mixf(3.0f, 4.5f, o);
    } break;
    case ActSleep: {
      float s = sinf(2.0f * (float)M_PI * t / 3200.0f);
      f.offY = 0.8f * s; f.sy = 1.0f + 0.05f * s;
      f.rot = 6.0f * (float)M_PI / 180.0f; f.faceYaw = 0.06f;
      f.eyeOpen = 0.06f; f.mouthCurve = 0.0f; f.blush = 0.6f;
    } break;
    case ActWake: {
      float p = clampf(le / a->actDur, 0.0f, 1.0f);
      f.eyeOpen = mixf(0.08f, 1.15f, ease_out_back(fminf(p / 0.25f, 1.0f)));
      f.offY -= 2.0f * (1.0f - p); f.mouthOpen = 0.3f * (1.0f - p);
    } break;
  }

  if (a->dragging) {
    f.skew += clampf(-a->velX * 0.012f, -0.18f, 0.18f);
    f.offY += clampf(a->velY * 0.02f, -2.5f, 2.5f);
    float speed = sqrtf(a->velX * a->velX + a->velY * a->velY);
    f.sy = 1.0f + 0.04f * fminf(speed / 30.0f, 1.0f);
    f.eyeOpen = fmaxf(f.eyeOpen, 1.1f);
    f.pupilDx = clampf(-a->velX * 0.03f, -2.0f, 2.0f);
    f.rot += (-a->velX * 0.4f) * (float)M_PI / 180.0f;
    f.armL = 70.0f; f.armR = 70.0f; f.armLLen = 5.0f; f.armRLen = 5.0f;
  } else if (t - a->relStart < 520.0f) {
    float tt = (t - a->relStart) / 1000.0f;
    float env = expf(-0.35f * 22.0f * tt);
    float osc = cosf(22.0f * sqrtf(1.0f - 0.35f * 0.35f) * tt);
    f.skew += a->relAmpX * 0.01f * env * osc;
    f.offY += a->relAmpY * 0.02f * env * osc;
  }

  float bdt = t - a->blinkStart;
  if (bdt >= 0.0f && bdt < 150.0f) {
    float bp = bdt / 150.0f;
    float close = bp < 0.47f ? ease_in_quad(bp / 0.47f) : 1.0f - ease_out_quad((bp - 0.47f) / 0.53f);
    f.eyeOpen = fminf(f.eyeOpen, 1.0f - 0.94f * close);
  } else if (a->blinkDouble && bdt >= 190.0f && bdt < 340.0f) {
    float bp = (bdt - 190.0f) / 150.0f;
    float close = bp < 0.47f ? ease_in_quad(bp / 0.47f) : 1.0f - ease_out_quad((bp - 0.47f) / 0.53f);
    f.eyeOpen = fminf(f.eyeOpen, 1.0f - 0.94f * close);
  }

  float lift = fmaxf(-f.offY, 0.0f);
  f.shadowRx = 16.0f + lift * 0.7f;
  f.shadowA = mixf(0.30f, 0.12f, fminf(lift / 12.0f, 1.0f));
  return f;
}

// ---------------------------------------------------------------------------
// PetView (AppKit glue)
// ---------------------------------------------------------------------------
@interface PetView () {
  Anim _anim;
  uint32_t *_buf;
  int _bufSide;
  double _start;
  NSPoint _dragStartMouse;
  NSPoint _dragStartWindowOrigin;
  NSPoint _lastMouse;
  BOOL _dragging;
}
@property(nonatomic, strong) NSTimer *animationTimer;
@end

@implementation PetView

- (double)nowMs {
  return ([NSProcessInfo processInfo].systemUptime - _start) * 1000.0;
}

- (instancetype)initWithFrame:(NSRect)frame {
  self = [super initWithFrame:frame];
  if (self) {
    _start = [NSProcessInfo processInfo].systemUptime;
    anim_init(&_anim);

    __weak PetView *weakSelf = self;
    self.animationTimer = [NSTimer timerWithTimeInterval:(1.0 / 60.0)
                                                 repeats:YES
                                                   block:^(NSTimer *timer) {
                                                     (void)timer;
                                                     PetView *s = weakSelf;
                                                     if (s.window &&
                                                         !(s.window.occlusionState & NSWindowOcclusionStateVisible)) {
                                                       return; // don't animate a hidden pet
                                                     }
                                                     s.needsDisplay = YES;
                                                   }];
    [NSRunLoop.mainRunLoop addTimer:self.animationTimer forMode:NSRunLoopCommonModes];
    self.animationTimer.tolerance = (1.0 / 60.0) * 0.1;
  }
  return self;
}

- (void)dealloc {
  [self.animationTimer invalidate];
  free(_buf);
}

- (BOOL)isOpaque { return NO; }
- (BOOL)acceptsFirstResponder { return YES; }

- (void)ensureBufferSide:(int)side {
  if (side != _bufSide || _buf == NULL) {
    free(_buf);
    _buf = (uint32_t *)malloc((size_t)side * side * 4);
    _bufSide = side;
  }
}

- (void)drawRect:(NSRect)dirtyRect {
  (void)dirtyRect;
  NSRect b = self.bounds;
  CGFloat bs = self.window ? self.window.backingScaleFactor : 1.0;
  if (bs < 1.0) bs = 1.0;
  int side = (int)lround(MIN(NSWidth(b), NSHeight(b)) * bs);
  if (side < 1) return;
  [self ensureBufferSide:side];
  if (_buf == NULL) return;

  float t = (float)[self nowMs];
  anim_update(&_anim, t);
  Frame f = anim_frame(&_anim, t);
  paint_ghost(_buf, side, &f, _anim.particles, _anim.pcount);

  CGContextRef ctx = [[NSGraphicsContext currentContext] CGContext];
  CGContextClearRect(ctx, CGRectMake(0, 0, NSWidth(b), NSHeight(b)));

  CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
  CGDataProviderRef prov =
      CGDataProviderCreateWithData(NULL, _buf, (size_t)side * side * 4, NULL);
  CGImageRef img = CGImageCreate(side, side, 8, 32, (size_t)side * 4, cs,
                                 kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little,
                                 prov, NULL, false, kCGRenderingIntentDefault);
  CGContextSaveGState(ctx);
  CGContextTranslateCTM(ctx, 0, NSHeight(b)); // our buffer is top-down
  CGContextScaleCTM(ctx, 1, -1);
  CGContextSetInterpolationQuality(ctx, kCGInterpolationHigh);
  CGContextDrawImage(ctx, CGRectMake(0, 0, NSWidth(b), NSHeight(b)), img);
  CGContextRestoreGState(ctx);

  CGImageRelease(img);
  CGDataProviderRelease(prov);
  CGColorSpaceRelease(cs);
}

// --- resize (about center), clamped ---
- (void)resizePetToSide:(CGFloat)side {
  side = MAX(kMinPetSize, MIN(kMaxPetSize, side));
  NSWindow *window = self.window;
  if (window == nil) return;
  NSRect frame = window.frame;
  NSRect next = NSMakeRect(round(NSMidX(frame) - side / 2.0), round(NSMidY(frame) - side / 2.0), side, side);
  [window setFrame:next display:YES];
}

- (void)scrollWheel:(NSEvent *)event {
  CGFloat step = event.scrollingDeltaY;
  if (!event.hasPreciseScrollingDeltas) step *= 6.0;
  [self resizePetToSide:NSWidth(self.window.frame) + step];
  anim_interacted(&_anim, (float)[self nowMs]);
}

- (void)magnifyWithEvent:(NSEvent *)event {
  [self resizePetToSide:NSWidth(self.window.frame) * (1.0 + event.magnification)];
  anim_interacted(&_anim, (float)[self nowMs]);
}

- (void)mouseDown:(NSEvent *)event {
  (void)event;
  _dragStartMouse = NSEvent.mouseLocation;
  _dragStartWindowOrigin = self.window.frame.origin;
  _lastMouse = _dragStartMouse;
  _dragging = YES;
  _anim.dragging = 1;
  float t = (float)[self nowMs];
  anim_interacted(&_anim, t);
  anim_start(&_anim, ActSurprise, t, 480.0f);
  [self.window makeFirstResponder:self];
}

- (void)mouseDragged:(NSEvent *)event {
  (void)event;
  NSPoint m = NSEvent.mouseLocation;
  NSPoint origin = NSMakePoint(_dragStartWindowOrigin.x + m.x - _dragStartMouse.x,
                               _dragStartWindowOrigin.y + m.y - _dragStartMouse.y);
  [self.window setFrameOrigin:origin];
  // velocity (screen y is up on macOS; flip so "down" is positive like the spec)
  float vx = (float)(m.x - _lastMouse.x);
  float vy = (float)(_lastMouse.y - m.y);
  _anim.velX = mixf(_anim.velX, vx, 0.4f);
  _anim.velY = mixf(_anim.velY, vy, 0.4f);
  _lastMouse = m;
  anim_interacted(&_anim, (float)[self nowMs]);
  self.needsDisplay = YES;
}

- (void)mouseUp:(NSEvent *)event {
  (void)event;
  if (!_dragging) return;
  _dragging = NO;
  _anim.dragging = 0;
  float t = (float)[self nowMs];
  _anim.relStart = t;
  _anim.relAmpX = _anim.velX;
  _anim.relAmpY = _anim.velY;
  NSPoint m = NSEvent.mouseLocation;
  CGFloat moved = fabs(m.x - _dragStartMouse.x) + fabs(m.y - _dragStartMouse.y);
  if (moved < 3.0) {
    anim_start(&_anim, ActHop, t, 640.0f); // a poke -> happy hop
  } else {
    _anim.act = ActIdle;
  }
  _anim.velX = 0.0f;
  _anim.velY = 0.0f;
}

- (void)rightMouseDown:(NSEvent *)event {
  (void)event;
  [NSApp terminate:nil];
}

- (void)keyDown:(NSEvent *)event {
  float t = (float)[self nowMs];
  anim_interacted(&_anim, t);
  NSString *chars = event.charactersIgnoringModifiers;
  if (event.keyCode == 53 || [chars isEqualToString:@"\033"]) {
    [NSApp terminate:nil];
    return;
  }
  if ([chars isEqualToString:@"+"] || [chars isEqualToString:@"="]) {
    [self resizePetToSide:NSWidth(self.window.frame) + 24.0];
    return;
  }
  if ([chars isEqualToString:@"-"] || [chars isEqualToString:@"_"]) {
    [self resizePetToSide:NSWidth(self.window.frame) - 24.0];
    return;
  }
  if ([chars isEqualToString:@" "]) {
    anim_start(&_anim, ActSpin, t, 720.0f); // space = do a trick!
    anim_spawn(&_anim, 6, 0);
    return;
  }
  [super keyDown:event];
}

@end
