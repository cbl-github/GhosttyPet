#import "PetView.h"

// Pixel-art ghost rendered as a grid of square cells.
// Legend: 'b' bright Ghostty blue (outer rim), 'k' black (inner outline + face),
//         'w' white (body fill), 'd' dark blue (optional shade), '.' transparent.
// Four animation frames differ ONLY in the face rows (4-6); the body is identical.
enum { kGridWidth = 14, kGridHeight = 14 };

static const char *const kGhostFrames[4][kGridHeight] = {
    {// face ">-"
     "...bbbbbbbb...",
     "..bkkkkkkkkb..",
     ".bkwwwwwwwwkb.",
     "bkwwwwwwwwwwkb",
     "bkwkwwwwwwwwkb",
     "bkwwkwwwkkkwkb",
     "bkwkwwwwwwwwkb",
     "bkwwwwwwwwwwkb",
     "bkwwwwwwwwwwkb",
     "bkwwwwwwwwwwkb",
     "bkwwwwwwwwwwkb",
     "bkwkwwkkwwkwkb",
     ".kk.kk..kk.kk.",
     ".bb.bb..bb.bb."},
    {// face ">>"
     "...bbbbbbbb...",
     "..bkkkkkkkkb..",
     ".bkwwwwwwwwkb.",
     "bkwwwwwwwwwwkb",
     "bkwkwwwwwkwwkb",
     "bkwwkwwwwwkwkb",
     "bkwkwwwwwkwwkb",
     "bkwwwwwwwwwwkb",
     "bkwwwwwwwwwwkb",
     "bkwwwwwwwwwwkb",
     "bkwwwwwwwwwwkb",
     "bkwkwwkkwwkwkb",
     ".kk.kk..kk.kk.",
     ".bb.bb..bb.bb."},
    {// face "@@"
     "...bbbbbbbb...",
     "..bkkkkkkkkb..",
     ".bkwwwwwwwwkb.",
     "bkwwwwwwwwwwkb",
     "bkwkkkwwkkkwkb",
     "bkwkwkwwkwkwkb",
     "bkwkkkwwkkkwkb",
     "bkwwwwwwwwwwkb",
     "bkwwwwwwwwwwkb",
     "bkwwwwwwwwwwkb",
     "bkwwwwwwwwwwkb",
     "bkwkwwkkwwkwkb",
     ".kk.kk..kk.kk.",
     ".bb.bb..bb.bb."},
    {// face "--"
     "...bbbbbbbb...",
     "..bkkkkkkkkb..",
     ".bkwwwwwwwwkb.",
     "bkwwwwwwwwwwkb",
     "bkwwwwwwwwwwkb",
     "bkwkkkwwkkkwkb",
     "bkwwwwwwwwwwkb",
     "bkwwwwwwwwwwkb",
     "bkwwwwwwwwwwkb",
     "bkwwwwwwwwwwkb",
     "bkwwwwwwwwwwkb",
     "bkwkwwkkwwkwkb",
     ".kk.kk..kk.kk.",
     ".bb.bb..bb.bb."},
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

    self.animationTimer = [NSTimer timerWithTimeInterval:(1.0 / 18.0)
                                                  target:self
                                                selector:@selector(animationTick:)
                                                userInfo:nil
                                                 repeats:YES];
    [NSRunLoop.mainRunLoop addTimer:self.animationTimer forMode:NSRunLoopCommonModes];
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
  @autoreleasepool {
    (void)timer;
    self.phase += 0.12;
    self.tickCount += 1;
    if (self.tickCount % 54 == 0) {
      self.faceIndex = (self.faceIndex + 1) % 4;
    }
    self.needsDisplay = YES;
  }
}

- (NSColor *)colorForPixel:(char)pixel {
  static NSColor *blue;
  static NSColor *shade;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    blue = [NSColor colorWithCalibratedRed:0.02 green:0.05 blue:0.95 alpha:1.0];
    shade = [NSColor colorWithCalibratedRed:0.01 green:0.02 blue:0.55 alpha:1.0];
  });

  switch (pixel) {
  case 'b':
    return blue;
  case 'k':
    return NSColor.blackColor;
  case 'w':
    return NSColor.whiteColor;
  case 'd':
    return shade;
  default:
    return nil;  // '.' transparent
  }
}

- (void)drawGhostInRect:(NSRect)rect {
  NSGraphicsContext *context = NSGraphicsContext.currentContext;
  BOOL savedAntialias = context.shouldAntialias;
  context.shouldAntialias = NO;  // crisp pixel edges, no seams

  for (NSInteger row = 0; row < kGridHeight; row++) {
    const char *line = kGhostFrames[self.faceIndex][row];
    for (NSInteger col = 0; col < kGridWidth; col++) {
      NSColor *color = [self colorForPixel:line[col]];
      if (color == nil) {
        continue;
      }

      // Cumulative boundaries so adjacent cells tile exactly (no gaps).
      CGFloat x0 = NSMinX(rect) + NSWidth(rect) * (CGFloat)col / (CGFloat)kGridWidth;
      CGFloat x1 = NSMinX(rect) + NSWidth(rect) * (CGFloat)(col + 1) / (CGFloat)kGridWidth;
      // Row 0 is the TOP of the grid; AppKit's y axis grows upward.
      CGFloat y0 =
          NSMinY(rect) + NSHeight(rect) * (CGFloat)(kGridHeight - 1 - row) / (CGFloat)kGridHeight;
      CGFloat y1 =
          NSMinY(rect) + NSHeight(rect) * (CGFloat)(kGridHeight - row) / (CGFloat)kGridHeight;

      [color setFill];
      NSRectFill(NSMakeRect(x0, y0, x1 - x0, y1 - y0));
    }
  }

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
