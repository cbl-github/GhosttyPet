#import "PetView.h"

// Pixel-art ghost rendered as a grid of square cells. Only the eyes move, so we
// store the body once (kGhostBody) and keep just the three differing face rows
// per frame (kGhostFaces) -- the four "frames" cost almost no extra memory.
// Legend: 'b' bright Ghostty blue (outer rim), 'k' black (inner outline + face),
//         'w' white (body fill), '.' transparent.
enum { kGridWidth = 14, kGridHeight = 14 };
enum { kFaceTop = 4, kFaceRows = 3 };  // the only rows that differ between frames

// The constant ghost body. The kFaceRows rows starting at kFaceTop are a plain
// white belly here; they get overwritten per frame by kGhostFaces below.
static const char *const kGhostBody[kGridHeight] = {
    "...bbbbbbbb...",
    "..bkkkkkkkkb..",
    ".bkwwwwwwwwkb.",
    "bkwwwwwwwwwwkb",
    "bkwwwwwwwwwwkb",
    "bkwwwwwwwwwwkb",
    "bkwwwwwwwwwwkb",
    "bkwwwwwwwwwwkb",
    "bkwwwwwwwwwwkb",
    "bkwwwwwwwwwwkb",
    "bkwwwwwwwwwwkb",
    "bkwkwwkkwwkwkb",
    ".kk.kk..kk.kk.",
    ".bb.bb..bb.bb.",
};

// The only animated pixels: four eye/face variants (">-", ">>", "@@", "--").
static const char *const kGhostFaces[4][kFaceRows] = {
    {"bkwkwwwwwwwwkb", "bkwwkwwwkkkwkb", "bkwkwwwwwwwwkb"},  // ">-"
    {"bkwkwwwwwkwwkb", "bkwwkwwwwwkwkb", "bkwkwwwwwkwwkb"},  // ">>"
    {"bkwkkkwwkkkwkb", "bkwkwkwwkwkwkb", "bkwkkkwwkkkwkb"},  // "@@"
    {"bkwwwwwwwwwwkb", "bkwkkkwwkkkwkb", "bkwwwwwwwwwwkb"},  // "--"
};

@interface PetView ()
@property(nonatomic, strong) NSTimer *animationTimer;
@property(nonatomic) CGFloat phase;
@property(nonatomic) NSInteger tickCount;
@property(nonatomic) NSInteger faceIndex;
@property(nonatomic) NSPoint dragStartMouse;
@property(nonatomic) NSPoint dragStartWindowOrigin;
@end

@implementation PetView

- (instancetype)initWithFrame:(NSRect)frame {
  self = [super initWithFrame:frame];
  if (self) {
    self.phase = 0.0;
    self.tickCount = 0;
    self.faceIndex = 0;

    // Block timer with a weak self so the timer does not retain the view: that
    // breaks the view<->timer retain cycle and lets -dealloc actually run.
    // Common run-loop modes keep the animation alive during drag tracking.
    __weak PetView *weakSelf = self;
    self.animationTimer = [NSTimer timerWithTimeInterval:(1.0 / 18.0)
                                                 repeats:YES
                                                   block:^(NSTimer *timer) {
                                                     [weakSelf animationTick:timer];
                                                   }];
    [NSRunLoop.mainRunLoop addTimer:self.animationTimer forMode:NSRunLoopCommonModes];
    // Slack lets the OS coalesce these wakeups with others and cut idle power.
    self.animationTimer.tolerance = (1.0 / 18.0) * 0.1;
  }
  return self;
}

- (void)dealloc {
  [self.animationTimer invalidate];
}

- (BOOL)isOpaque {
  return NO;
}

- (BOOL)acceptsFirstResponder {
  return YES;
}

- (void)drawRect:(NSRect)dirtyRect {
  @autoreleasepool {
    (void)dirtyRect;
    [NSColor.clearColor setFill];
    NSRectFill(self.bounds);

    CGFloat bounce = sin(self.phase * 2.0) * 5.0;
    CGFloat pulse = 1.0 + sin(self.phase * 1.4) * 0.02;

    // Square, centered drawing area so the pixels stay square.
    CGFloat side = (MIN(NSWidth(self.bounds), NSHeight(self.bounds)) - 24.0) * pulse;
    if (side < 1.0) {
      return;  // window too small to draw a meaningful ghost
    }
    NSRect petRect = NSMakeRect(NSMidX(self.bounds) - side / 2.0,
                                NSMidY(self.bounds) - side / 2.0 + bounce,
                                side, side);

    [self drawGhostInRect:petRect];
  }
}

- (void)animationTick:(NSTimer *)timer {
  (void)timer;

  // Don't spend CPU animating a pet nobody can see (another Space, behind a
  // fullscreen app, minimized...). The tick resumes cleanly once it's visible.
  NSWindow *window = self.window;
  if (window && !(window.occlusionState & NSWindowOcclusionStateVisible)) {
    return;
  }

  // Wrap at 10*pi -- the smallest phase where both sin(phase*2) and
  // sin(phase*1.4) complete whole cycles, so the wrap is seamless and phase
  // never grows large enough to lose float precision.
  self.phase += 0.12;
  if (self.phase >= 10.0 * M_PI) {
    self.phase -= 10.0 * M_PI;
  }
  self.tickCount += 1;
  if (self.tickCount % 54 == 0) {
    self.faceIndex = (self.faceIndex + 1) % 4;
  }
  self.needsDisplay = YES;
}

- (void)drawGhostInRect:(NSRect)rect {
  static NSColor *blue;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    blue = [NSColor colorWithCalibratedRed:0.02 green:0.05 blue:0.95 alpha:1.0];
  });

  NSGraphicsContext *context = NSGraphicsContext.currentContext;
  BOOL savedAntialias = context.shouldAntialias;
  context.shouldAntialias = NO;  // crisp pixel edges, no seams

  // Group the cells by color and flush each color in one NSRectFillList call
  // instead of a setFill + fill per cell -- ~200 fills become three. The
  // buffers live on the stack, so a repaint allocates and frees nothing.
  NSRect blueRects[kGridWidth * kGridHeight];
  NSRect blackRects[kGridWidth * kGridHeight];
  NSRect whiteRects[kGridWidth * kGridHeight];
  NSInteger blueCount = 0, blackCount = 0, whiteCount = 0;

  for (NSInteger row = 0; row < kGridHeight; row++) {
    BOOL faceRow = (row >= kFaceTop && row < kFaceTop + kFaceRows);
    const char *line =
        faceRow ? kGhostFaces[self.faceIndex][row - kFaceTop] : kGhostBody[row];
    for (NSInteger col = 0; col < kGridWidth; col++) {
      char pixel = line[col];
      if (pixel == '.') {
        continue;  // transparent
      }

      // Cumulative boundaries so adjacent cells tile exactly (no gaps).
      CGFloat x0 = NSMinX(rect) + NSWidth(rect) * (CGFloat)col / (CGFloat)kGridWidth;
      CGFloat x1 = NSMinX(rect) + NSWidth(rect) * (CGFloat)(col + 1) / (CGFloat)kGridWidth;
      // Row 0 is the TOP of the grid; AppKit's y axis grows upward.
      CGFloat y0 =
          NSMinY(rect) + NSHeight(rect) * (CGFloat)(kGridHeight - 1 - row) / (CGFloat)kGridHeight;
      CGFloat y1 =
          NSMinY(rect) + NSHeight(rect) * (CGFloat)(kGridHeight - row) / (CGFloat)kGridHeight;
      NSRect cell = NSMakeRect(x0, y0, x1 - x0, y1 - y0);

      switch (pixel) {
      case 'b':
        blueRects[blueCount++] = cell;
        break;
      case 'k':
        blackRects[blackCount++] = cell;
        break;
      case 'w':
        whiteRects[whiteCount++] = cell;
        break;
      default:
        break;
      }
    }
  }

  [blue setFill];
  NSRectFillList(blueRects, blueCount);
  [NSColor.blackColor setFill];
  NSRectFillList(blackRects, blackCount);
  [NSColor.whiteColor setFill];
  NSRectFillList(whiteRects, whiteCount);

  context.shouldAntialias = savedAntialias;
}

- (void)mouseDown:(NSEvent *)event {
  (void)event;
  self.dragStartMouse = NSEvent.mouseLocation;
  self.dragStartWindowOrigin = self.window.frame.origin;
  [self.window makeFirstResponder:self];
}

- (void)mouseDragged:(NSEvent *)event {
  (void)event;
  NSPoint currentMouse = NSEvent.mouseLocation;
  NSPoint nextOrigin = NSMakePoint(
      self.dragStartWindowOrigin.x + currentMouse.x - self.dragStartMouse.x,
      self.dragStartWindowOrigin.y + currentMouse.y - self.dragStartMouse.y);
  [self.window setFrameOrigin:nextOrigin];
}

- (void)rightMouseDown:(NSEvent *)event {
  (void)event;
  [NSApp terminate:nil];
}

- (void)keyDown:(NSEvent *)event {
  if (event.keyCode == 53 ||
      [event.charactersIgnoringModifiers isEqualToString:@"\033"]) {
    [NSApp terminate:nil];
    return;
  }
  [super keyDown:event];
}

@end
