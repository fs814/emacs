#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>

/* GodotDelegate owns a layer-backed NSView whose layer hosts the embedded
   Godot editor's rendered content via a CALayerHost bound to the CAContext id
   published by libGodotOffscreen (the embedded macOS DisplayServer renders into
   a CAMetalLayer wrapped in a CAContext; CALayerHost displays it in-process).

   Unlike the slate/metal delegates, there is NO per-frame blit: Godot renders
   into its own layer and we simply host it.  The engine runs on its own game
   thread inside the shim; we poll the context id until it is ready. */
@interface GodotDelegate : NSObject

- (nonnull instancetype)initWithGodotView:(nonnull NSView *)view
                                   editor:(BOOL)editor
                                  project:(nullable const char *)projectPath;

/* Track the host view's size/scale into the embedded engine. */
- (void)resizeToPixels:(NSSize)pixelSize;

/* Forward host input into the embedded Godot instance.  Points are in the
   view's (flipped, top-left origin) coordinate space; libGodotOffscreen scales
   them to render pixels.  `mods` is a bitmask: 1=shift 2=ctrl 4=alt 8=cmd. */
- (void)forwardMouseButton:(int)button down:(BOOL)down at:(NSPoint)pt mods:(int)mods doubleClick:(BOOL)doubleClick;
- (void)forwardMouseMoveTo:(NSPoint)pt relative:(NSPoint)rel mods:(int)mods;
- (void)forwardScroll:(CGFloat)deltaY at:(NSPoint)pt mods:(int)mods;
- (void)forwardKey:(int)keyCode down:(BOOL)down mods:(int)mods unicode:(uint32_t)unicode;

/* Stop the embedded engine and hard-exit the process.  Called from a
   kill-emacs-hook before the C exit() that would run Godot's static
   destructors on the host thread. */
+ (void)shutdownEngineAndExit;

@end
