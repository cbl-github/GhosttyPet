#import <AppKit/AppKit.h>
#import "PetView.h"

@interface PetWindow : NSPanel
@end

@implementation PetWindow

- (BOOL)canBecomeKeyWindow {
  return YES;
}

- (BOOL)canBecomeMainWindow {
  return YES;
}

@end

@interface AppDelegate : NSObject <NSApplicationDelegate>
@property(nonatomic, strong) PetWindow *window;
@end

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
  (void)notification;

  NSRect frame = NSMakeRect(0, 0, 150, 150);
  NSScreen *screen = NSScreen.mainScreen;
  if (screen != nil) {
    NSRect visible = screen.visibleFrame;
    frame.origin.x = NSMidX(visible) - NSWidth(frame) / 2.0;
    frame.origin.y = NSMidY(visible) - NSHeight(frame) / 2.0;
  }

  self.window = [[PetWindow alloc] initWithContentRect:frame
                                             styleMask:NSWindowStyleMaskBorderless
                                               backing:NSBackingStoreBuffered
                                                 defer:NO];
  self.window.opaque = NO;
  self.window.backgroundColor = NSColor.clearColor;
  self.window.hasShadow = NO;
  self.window.level = NSFloatingWindowLevel;
  self.window.hidesOnDeactivate = NO;
  self.window.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces |
                                   NSWindowCollectionBehaviorFullScreenAuxiliary;
  self.window.releasedWhenClosed = NO;

  PetView *view = [[PetView alloc] initWithFrame:NSMakeRect(0, 0, 150, 150)];
  self.window.contentView = view;
  [self.window makeKeyAndOrderFront:nil];
  [self.window orderFrontRegardless];
  [self.window makeFirstResponder:view];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
  (void)sender;
  return YES;
}

@end

int main(int argc, const char *argv[]) {
  (void)argc;
  (void)argv;

  @autoreleasepool {
    NSApplication *app = NSApplication.sharedApplication;
    app.activationPolicy = NSApplicationActivationPolicyAccessory;
    AppDelegate *delegate = [[AppDelegate alloc] init];
    app.delegate = delegate;
    [app run];
  }

  return 0;
}
