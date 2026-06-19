#import "PetView.h"

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
    CGFloat pulse = 1.0 + sin(self.phase * 1.4) * 0.018;
    NSRect petRect = NSInsetRect(self.bounds, 26, 22);
    petRect.origin.y += bounce;
    CGFloat widthDelta = petRect.size.width * (pulse - 1.0);
    CGFloat heightDelta = petRect.size.height * (pulse - 1.0);
    petRect = NSInsetRect(petRect, -widthDelta / 2.0, -heightDelta / 2.0);

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

- (NSPoint)pointInRect:(NSRect)rect x:(CGFloat)x y:(CGFloat)y {
  return NSMakePoint(NSMinX(rect) + NSWidth(rect) * x,
                     NSMinY(rect) + NSHeight(rect) * y);
}

- (NSBezierPath *)ghostBodyPathInRect:(NSRect)rect {
  NSBezierPath *path = [NSBezierPath bezierPath];
  [path moveToPoint:[self pointInRect:rect x:0.50 y:0.96]];
  [path curveToPoint:[self pointInRect:rect x:0.12 y:0.56]
       controlPoint1:[self pointInRect:rect x:0.26 y:0.96]
       controlPoint2:[self pointInRect:rect x:0.12 y:0.82]];
  [path lineToPoint:[self pointInRect:rect x:0.12 y:0.30]];
  [path curveToPoint:[self pointInRect:rect x:0.24 y:0.18]
       controlPoint1:[self pointInRect:rect x:0.12 y:0.22]
       controlPoint2:[self pointInRect:rect x:0.17 y:0.14]];
  [path curveToPoint:[self pointInRect:rect x:0.38 y:0.18]
       controlPoint1:[self pointInRect:rect x:0.29 y:0.22]
       controlPoint2:[self pointInRect:rect x:0.33 y:0.22]];
  [path curveToPoint:[self pointInRect:rect x:0.50 y:0.18]
       controlPoint1:[self pointInRect:rect x:0.42 y:0.14]
       controlPoint2:[self pointInRect:rect x:0.46 y:0.14]];
  [path curveToPoint:[self pointInRect:rect x:0.62 y:0.18]
       controlPoint1:[self pointInRect:rect x:0.54 y:0.22]
       controlPoint2:[self pointInRect:rect x:0.58 y:0.22]];
  [path curveToPoint:[self pointInRect:rect x:0.76 y:0.18]
       controlPoint1:[self pointInRect:rect x:0.67 y:0.14]
       controlPoint2:[self pointInRect:rect x:0.71 y:0.14]];
  [path curveToPoint:[self pointInRect:rect x:0.88 y:0.30]
       controlPoint1:[self pointInRect:rect x:0.83 y:0.14]
       controlPoint2:[self pointInRect:rect x:0.88 y:0.22]];
  [path lineToPoint:[self pointInRect:rect x:0.88 y:0.56]];
  [path curveToPoint:[self pointInRect:rect x:0.50 y:0.96]
       controlPoint1:[self pointInRect:rect x:0.88 y:0.82]
       controlPoint2:[self pointInRect:rect x:0.74 y:0.96]];
  [path closePath];
  return path;
}

- (void)strokeLineFrom:(NSPoint)start to:(NSPoint)end width:(CGFloat)width {
  NSBezierPath *line = [NSBezierPath bezierPath];
  line.lineCapStyle = NSLineCapStyleRound;
  line.lineJoinStyle = NSLineJoinStyleRound;
  [line setLineWidth:width];
  [line moveToPoint:start];
  [line lineToPoint:end];
  [line stroke];
}

- (void)drawChevronInRect:(NSRect)rect centerX:(CGFloat)x centerY:(CGFloat)y scale:(CGFloat)scale {
  CGFloat w = NSWidth(rect) * 0.13 * scale;
  CGFloat h = NSHeight(rect) * 0.11 * scale;
  CGFloat cx = NSMinX(rect) + NSWidth(rect) * x;
  CGFloat cy = NSMinY(rect) + NSHeight(rect) * y;
  CGFloat lineWidth = NSWidth(rect) * 0.052 * scale;

  NSBezierPath *path = [NSBezierPath bezierPath];
  path.lineCapStyle = NSLineCapStyleRound;
  path.lineJoinStyle = NSLineJoinStyleRound;
  [path setLineWidth:lineWidth];
  [path moveToPoint:NSMakePoint(cx - w / 2.0, cy + h / 2.0)];
  [path lineToPoint:NSMakePoint(cx + w / 2.0, cy)];
  [path lineToPoint:NSMakePoint(cx - w / 2.0, cy - h / 2.0)];
  [path stroke];
}

- (void)drawDashInRect:(NSRect)rect centerX:(CGFloat)x centerY:(CGFloat)y {
  CGFloat cx = NSMinX(rect) + NSWidth(rect) * x;
  CGFloat cy = NSMinY(rect) + NSHeight(rect) * y;
  CGFloat halfWidth = NSWidth(rect) * 0.08;
  CGFloat lineWidth = NSWidth(rect) * 0.052;
  [self strokeLineFrom:NSMakePoint(cx - halfWidth, cy)
                    to:NSMakePoint(cx + halfWidth, cy)
                 width:lineWidth];
}

- (void)drawAtFaceInRect:(NSRect)rect {
  NSString *text = @"@@";
  static NSDictionary<NSAttributedStringKey, id> *attrs;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    attrs = @{
      NSFontAttributeName: [NSFont monospacedSystemFontOfSize:44.0 weight:NSFontWeightBlack],
      NSForegroundColorAttributeName: NSColor.blackColor
    };
  });
  NSSize size = [text sizeWithAttributes:attrs];
  NSPoint point = NSMakePoint(NSMidX(rect) - size.width / 2.0,
                              NSMinY(rect) + NSHeight(rect) * 0.49);
  [text drawAtPoint:point withAttributes:attrs];
}

- (void)drawGhostFaceInRect:(NSRect)rect {
  [NSColor.blackColor setStroke];
  [NSColor.blackColor setFill];

  switch (self.faceIndex) {
  case 1:
    [self drawChevronInRect:rect centerX:0.40 centerY:0.61 scale:1.0];
    [self drawChevronInRect:rect centerX:0.64 centerY:0.61 scale:1.0];
    break;
  case 2:
    [self drawAtFaceInRect:rect];
    break;
  case 3:
    [self drawDashInRect:rect centerX:0.38 centerY:0.61];
    [self drawDashInRect:rect centerX:0.64 centerY:0.61];
    break;
  default:
    [self drawChevronInRect:rect centerX:0.40 centerY:0.61 scale:1.0];
    [self drawDashInRect:rect centerX:0.66 centerY:0.61];
    break;
  }
}

- (void)drawGhostInRect:(NSRect)rect {
  NSBezierPath *body = [self ghostBodyPathInRect:rect];

  static NSColor *blue;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    blue = [NSColor colorWithCalibratedRed:0.02 green:0.05 blue:0.95 alpha:1.0];
  });

  [blue setStroke];
  [body setLineWidth:26.0];
  [body stroke];

  [NSColor.blackColor setStroke];
  [body setLineWidth:14.0];
  [body stroke];

  [NSColor.whiteColor setFill];
  [body fill];

  [self drawGhostFaceInRect:rect];
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
