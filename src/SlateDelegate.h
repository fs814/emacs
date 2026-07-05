#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>

#import <MetalKit/MetalKit.h>

@interface SlateDelegate : NSObject <MTKViewDelegate>

- (nonnull instancetype)initWithSlateView:(nonnull MTKView *)mtkView;

/* Forward host input into the embedded Slate widget tree.  Coordinates are in
   the MTKView's own points; the delegate converts to the offscreen render
   target's pixel space (accounting for backing scale).  No-ops until the engine
   is ready.  Used by the interactive "slate viewer" (Starship gallery) mode. */
- (void)forwardMouseMoveTo:(NSPoint)viewPoint;
- (void)forwardMouseButton:(int)button down:(BOOL)down at:(NSPoint)viewPoint;
- (void)forwardScroll:(CGFloat)deltaY;
- (void)forwardKey:(int)keyCode down:(BOOL)down
             shift:(BOOL)shift ctrl:(BOOL)ctrl alt:(BOOL)alt cmd:(BOOL)cmd;
- (void)forwardChar:(unichar)codepoint;

/* Stop the embedded engine game thread and hard-exit the process.  Called
   from a kill-emacs-hook, which runs during Fkill_emacs BEFORE the C exit()
   that would otherwise run UE's static destructors and crash the host. */
+ (void)shutdownEngineAndExit;

@end
