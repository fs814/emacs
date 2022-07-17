#include <config.h>

//#import "xwidget.h"

#include "triangle.h"

#import "VulkanView.h"
#import "VulkanDelegate.h"

static CVReturn displayLinkOutputCallback(CVDisplayLinkRef displayLink,
                                          const CVTimeStamp *inNow,
                                          const CVTimeStamp *inOutputTime,
                                          CVOptionFlags flagsIn,
                                          CVOptionFlags *flagsOut,
                                          void *displayLinkContext) {
  @autoreleasepool {
    auto vulkanExample = static_cast<VulkanExample *>(displayLinkContext);
    vulkanExample->displayLinkOutputCb();
  }
  return kCVReturnSuccess;
}

@implementation XwVulkanView : MTKView
NSPoint _mVulkanClickStart;
VulkanDelegate* _mVulkanRenderer;
CVDisplayLinkRef displayLink;
VulkanExampleBase* vulkanExample;


- (id)initWithFrame:(CGRect)frameRect
             device:(nullable id<MTLDevice>)device
            xwidget:(struct xwidget *)xw {
  self = [super initWithFrame:frameRect device:device];
  if (self) {
    self.xw = xw;
    _mVulkanRenderer = [[VulkanDelegate alloc] initWithVulkanView:self];
    vulkanExample = (VulkanExampleBase*)_mVulkanRenderer->_vulkanExampleBase;
    [self setDelegate:_mVulkanRenderer];
  }
  return self;
}

- (void)viewDidMoveToWindow {
  CVDisplayLinkCreateWithActiveCGDisplays(&displayLink);
  CVDisplayLinkSetOutputCallback(displayLink, &displayLinkOutputCallback,
                                 vulkanExample);
  CVDisplayLinkStart(displayLink);
}

- (void)dealloc {
  [super dealloc];
  [_mVulkanRenderer release];
}

- (BOOL)acceptsFirstResponder {
  return YES;
}

- (void)mouseDown:(NSEvent *)event {
  //[self.xw->xv->emacswindow mouseDown:event];
  [super mouseUp:event];
  _mVulkanClickStart = [self convertPoint:[event locationInWindow] fromView:nil];
}

- (void)mouseUp:(NSEvent *)event {
  //[self.xw->xv->emacswindow mouseUp:event];
  [super mouseUp:event];
}

- (void)mouseDragged:(NSEvent *)event {
  NSPoint p = [self convertPoint:[event locationInWindow] fromView:nil];
  NSLog(@"Mousedrag delta %f %f", p.x - _mVulkanClickStart.x, p.y - _mVulkanClickStart.y);
}

- (void)keyDown:(NSEvent *)event {
  NSString *c = [event charactersIgnoringModifiers];
  if ([c isEqual:@"q"]) {
    NSLog(@"keyDown q key");
  } else {
    [super keyDown:event];
  }
}
@end
