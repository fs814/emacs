/* NS Cocoa part implementation of xwidget and webkit widget.

Copyright (C) 2019-2026 Free Software Foundation, Inc.

This file is part of GNU Emacs.

GNU Emacs is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or (at
your option) any later version.

GNU Emacs is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with GNU Emacs.  If not, see <https://www.gnu.org/licenses/>.  */

#include <config.h>

#include "blockinput.h"
#include "buffer.h"
#include "dispextern.h"
#include "frame.h"
#include "lisp.h"
#include "nsterm.h"
#include "xwidget.h"

//#import "triangle.h"
//#include "vulkanexamplebase.h"

#import <AppKit/AppKit.h>
#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>
#import <WebKit/WebKit.h>
#import <simd/simd.h>

#import "LcRender.h"
#import "LcShaderTypes.h"

#ifdef HAVE_FILAMENT
#import "FilamentDelegate.h"
#endif
#ifdef HAVE_SLATE
#import "SlateDelegate.h"
#endif
#ifdef HAVE_GODOT
#import "GodotDelegate.h"
#endif
#ifdef HAVE_VULKAN
#import "VulkanView.h"

#import "VulkanDelegate.h"
#endif
#ifdef HAVE_BGFX
#import "BgfxDelegate.h"
#endif
#ifdef HAVE_DAWN
#import "DawnDelegate.h"
#endif


/* Thoughts on NS Cocoa xwidget and webkit2:

   Webkit2 process architecture seems to be very hostile for offscreen
   rendering techniques, which is used by GTK xwidget implementation;
   Specifically NSView level view sharing / copying is not working.

   *** So only one view can be associated with a model. ***

   With this decision, implementation is plain and can expect best out
   of webkit2's rationale.  But process and session structures will
   diverge from GTK xwidget.  Though, cosmetically similar usages can
   be presented and will be preferred, if agreeable.

   For other widget types, OSR seems possible, but will not care for a
   while.  */

/* Xwidget webkit.  */

@interface XwWebView
    : WKWebView <WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler>
@property struct xwidget *xw;
/* Map url to whether javascript is blocked by
   'Content-Security-Policy' sandbox without allow-scripts.  */
@property(retain) NSMutableDictionary *urlScriptBlocked;
@end
@implementation XwWebView : WKWebView

- (id) initWithFrame:(CGRect)frame
      configuration:(WKWebViewConfiguration *)configuration
            xwidget:(struct xwidget *)xw {
  /* Script controller to add script message handler and user script.  */
  WKUserContentController *scriptor = [[[WKUserContentController alloc] init]
                                        autorelease];
  configuration.userContentController = scriptor;

  /* Enable inspect element context menu item for debugging.  */
  [configuration.preferences setValue:@YES forKey:@"developerExtrasEnabled"];

#if 0 /* Plugins are not supported by Mac OS X anymore.  */
  Lisp_Object enablePlugins =
    Fintern (build_string ("xwidget-webkit-enable-plugins"), Qnil);

  if (!EQ (Fsymbol_value (enablePlugins), Qnil))
    configuration.preferences.plugInsEnabled = YES;
#endif

  self = [super initWithFrame:frame configuration:configuration];
  if (self)
    {
      self.xw = xw;
      self.urlScriptBlocked = [[[NSMutableDictionary alloc] init]
                                autorelease];
      self.navigationDelegate = self;
      self.UIDelegate = self;
      self.customUserAgent =
        @"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_12_6)"
        @" AppleWebKit/603.3.8 (KHTML, like Gecko)"
        @" Version/11.0.1 Safari/603.3.8";
      [scriptor addScriptMessageHandler:self name:@"keyDown"];
      WKUserScript *userScript = [[[WKUserScript alloc]
                                    initWithSource:xwScript
                                     injectionTime:
                                      WKUserScriptInjectionTimeAtDocumentStart
                                    forMainFrameOnly:NO] autorelease];
      [scriptor addUserScript:userScript];
    }
  return self;
}

/* These 4 functions emulate the behavior of webkit_view_load_changed_cb
   in the GTK implementation*/
- (void) webView:(WKWebView *)webView
didFinishNavigation:(WKNavigation *)navigation
{
  if (EQ (Fbuffer_live_p (self.xw->buffer), Qt))
    store_xwidget_event_string (self.xw, "load-changed", "load-finished");
}

- (void) webView:(WKWebView *)webView
didStartProvisionalNavigation:(WKNavigation *)navigation
{
  if (EQ (Fbuffer_live_p (self.xw->buffer), Qt))
    store_xwidget_event_string (self.xw, "load-changed", "load-started");
}

- (void) webView:(WKWebView *)webView
didReceiveServerRedirectForProvisionalNavigation:(WKNavigation *)navigation
{
  if (EQ (Fbuffer_live_p (self.xw->buffer), Qt))
    store_xwidget_event_string (self.xw, "load-changed", "load-redirected");
}

/* Start loading WKWebView */
- (void) webView:(WKWebView *)webView
didCommitNavigation:(WKNavigation *)navigation
{
  if (EQ (Fbuffer_live_p (self.xw->buffer), Qt))
    store_xwidget_event_string (self.xw, "load-changed", "load-committed");
}

- (void) webView:(WKWebView *)webView
decidePolicyForNavigationAction:(WKNavigationAction *)navigationAction
decisionHandler:(void (^)(WKNavigationActionPolicy))decisionHandler
{
  switch (navigationAction.navigationType) {
  case WKNavigationTypeLinkActivated:
    decisionHandler(WKNavigationActionPolicyAllow);
    break;
  default:
    /* decisionHandler (WKNavigationActionPolicyCancel); */
    decisionHandler (WKNavigationActionPolicyAllow);
    break;
  }
}

- (void) webView:(WKWebView *)webView
decidePolicyForNavigationResponse:(WKNavigationResponse *)navigationResponse
decisionHandler:(void (^)(WKNavigationResponsePolicy))decisionHandler
{
  if (!navigationResponse.canShowMIMEType)
    {
      NSString *url = navigationResponse.response.URL.absoluteString;
      NSString *mimetype = navigationResponse.response.MIMEType;
      NSString *filename = navigationResponse.response.suggestedFilename;
      decisionHandler (WKNavigationResponsePolicyCancel);
      store_xwidget_download_callback_event (self.xw,
                                             url.UTF8String,
                                             mimetype.UTF8String,
                                             filename.UTF8String);
      return;
    }
  decisionHandler (WKNavigationResponsePolicyAllow);

  self.urlScriptBlocked[navigationResponse.response.URL] =
      [NSNumber numberWithBool:NO];
  if ([navigationResponse.response isKindOfClass:[NSHTTPURLResponse class]]) {
    NSDictionary *headers =
        ((NSHTTPURLResponse *)navigationResponse.response).allHeaderFields;
    NSString *value = headers[@"Content-Security-Policy"];
    if (value) {
      /* TODO: Sloppy parsing of 'Content-Security-Policy' value.  */
      NSRange sandbox = [value rangeOfString:@"sandbox"];
      if (sandbox.location != NSNotFound &&
          (sandbox.location == 0 ||
           [value characterAtIndex:(sandbox.location - 1)] == ' ' ||
           [value characterAtIndex:(sandbox.location - 1)] == ';')) {
        NSRange allowScripts = [value rangeOfString:@"allow-scripts"];
        if (allowScripts.location == NSNotFound ||
            allowScripts.location < sandbox.location)
          self.urlScriptBlocked[navigationResponse.response.URL] =
              [NSNumber numberWithBool:YES];
      }
    }
  }
}

/* No additional new webview or emacs window will be created
   for <a ... target="_blank">.  */
- (WKWebView *) webView:(WKWebView *)webView
createWebViewWithConfiguration:(WKWebViewConfiguration *)configuration
   forNavigationAction:(WKNavigationAction *)navigationAction
        windowFeatures:(WKWindowFeatures *)windowFeatures
{
  if (!navigationAction.targetFrame.isMainFrame)
    [webView loadRequest:navigationAction.request];
  return nil;
}

/* Open panel for file upload.  */
- (void) webView:(WKWebView *)webView
runOpenPanelWithParameters:(WKOpenPanelParameters *)parameters
initiatedByFrame:(WKFrameInfo *)frame
completionHandler:(void (^)(NSArray<NSURL *> *URLs))completionHandler
{
  NSOpenPanel *openPanel = [NSOpenPanel openPanel];
  openPanel.canChooseFiles = YES;
  openPanel.canChooseDirectories = NO;
  openPanel.allowsMultipleSelection = parameters.allowsMultipleSelection;
  if ([openPanel runModal] == NSModalResponseOK)
    completionHandler(openPanel.URLs);
  else
    completionHandler(nil);
}

/* By forwarding mouse events to emacs view (frame)
   - Mouse click in webview selects the window contains the webview.
   - Correct mouse hand/arrow/I-beam is displayed (TODO: not perfect yet).
*/

- (void) mouseDown:(NSEvent *)event
{
  [self.xw->xv->emacswindow mouseDown:event];
  [super mouseDown:event];
}

- (void) mouseUp:(NSEvent *)event
{
  [self.xw->xv->emacswindow mouseUp:event];
  [super mouseUp:event];
}

/* Basically we want keyboard events handled by emacs unless an input
   element has focus.  Especially, while incremental search, we set
   emacs as first responder to avoid focus held in an input element
   with matching text.  */

- (void) keyDown:(NSEvent *)event
{
  Lisp_Object var = Fintern (build_string ("isearch-mode"), Qnil);
  Lisp_Object val = buffer_local_value (var, Fcurrent_buffer ());
  if (!EQ (val, Qunbound) && !EQ (val, Qnil))
    {
      [self.window makeFirstResponder:self.xw->xv->emacswindow];
      [self.xw->xv->emacswindow keyDown:event];
      return;
    }

  /* Emacs handles keyboard events when javascript is blocked.  */
  if ([self.urlScriptBlocked[self.URL] boolValue]) {
    [self.xw->xv->emacswindow keyDown:event];
    return;
  }

  [self evaluateJavaScript:@"xwHasFocus()"
         completionHandler:^(id result, NSError *error) {
           if (error) {
             /* xwHasFocus() may be undefined when no HTML document is
                loaded (e.g. metal/blank xwidget sessions), which makes
                WebKit raise a ReferenceError on every keystroke.  Treat
                any evaluation error as "no web focus" and forward the
                key to Emacs, without spamming the system log.  */
             [self.xw->xv->emacswindow keyDown:event];
           } else if (result) {
             NSNumber *hasFocus = result; /* __NSCFBoolean */
             if (!hasFocus.boolValue)
               [self.xw->xv->emacswindow keyDown:event];
             else
               [super keyDown:event];
           }
         }];
}

- (void) interpretKeyEvents:(NSArray<NSEvent *> *)eventArray
{
  /* We should do nothing and do not forward (default implementation
     if we not override here) to let emacs collect key events and ask
     interpretKeyEvents to its superclass.  */
}

static NSString *xwScript;
+ (void) initialize
{
  /* Find out if an input element has focus.
     Message to script message handler when 'C-g' key down.  */
  if (!xwScript)
    xwScript = @"function xwHasFocus() {"
               @"  var ae = document.activeElement;"
               @"  if (ae) {"
               @"    var name = ae.nodeName;"
               @"    return name == 'INPUT' || name == 'TEXTAREA';"
               @"  } else {"
               @"    return false;"
               @"  }"
               @"}"
               @"function xwKeyDown(event) {"
               @"  if (event.ctrlKey && event.key == 'g') {"
               @"    window.webkit.messageHandlers.keyDown.postMessage('C-g');"
               @"  }"
               @"}"
               @"document.addEventListener('keydown', xwKeyDown);";
}

/* Confirming to WKScriptMessageHandler, listens concerning keyDown in
   webkit. Currently 'C-g'.  */
- (void) userContentController:(WKUserContentController *)userContentController
      didReceiveScriptMessage:(WKScriptMessage *)message
{
  if ([message.body isEqualToString:@"C-g"])
    {
      /* Just give up focus, no relay "C-g" to emacs, another "C-g"
         follows will be handled by emacs.  */
      [self.window makeFirstResponder:self.xw->xv->emacswindow];
    }
}

@end

// const char shadersSrc[] = R"""(
//         #include <metal_stdlib>
//         using namespace metal;
//         vertex float4 vertFunc (
//             const device packed_float3* vertexArray [[buffer(0)]],
//             unsigned int vID[[vertex_id]])
//         {
//             return float4(vertexArray[vID], 1.0);
//         }
//         fragment half4 fragFunc ()
//         {
//             return half4(1.0);
//         }
//     )""";

@interface XwMetalView : MTKView
//@property(nonatomic, strong) id<MTLTexture> texture;
@property struct xwidget *xw;
@end

@implementation XwMetalView : MTKView
NSPoint _mClickStart;
AAPLRenderer *_mRenderer;

- (id)initWithFrame:(CGRect)frameRect
             device:(nullable id<MTLDevice>)device
            xwidget:(struct xwidget *)xw {
  self = [super initWithFrame:frameRect device:device];
  if (self) {
    self.xw = xw;
    _mRenderer = [[AAPLRenderer alloc] initWithMetalKitView:self];
    [self setDelegate:_mRenderer];
  }
  return self;
}

- (void)dealloc {
  [super dealloc];
  [_mRenderer release];
}

- (BOOL)acceptsFirstResponder {
  return YES;
}

- (void)mouseDown:(NSEvent *)event {
  [self.xw->xv->emacswindow mouseDown:event];
  [super mouseUp:event];
  _mClickStart = [self convertPoint:[event locationInWindow] fromView:nil];
}

- (void)mouseUp:(NSEvent *)event {
  [self.xw->xv->emacswindow mouseUp:event];
  [super mouseUp:event];
}

- (void)mouseDragged:(NSEvent *)event {
  NSPoint p = [self convertPoint:[event locationInWindow] fromView:nil];
  NSLog(@"Mousedrag delta %f %f", p.x - _mClickStart.x, p.y - _mClickStart.y);
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

#ifdef HAVE_FILAMENT
NSString *XwFilamentViewDidSizeChange = @"XwFilamentViewDidSizeChange";

@interface XwFilamentView : MTKView
//@property(nonatomic, strong) id<MTLTexture> texture;
@property struct xwidget *xw;
@end

@implementation XwFilamentView : MTKView
NSPoint _mClickStart;
FilamentDelegate *filamentDelegate;
NSSize _viewSize;

- (id)initWithFrame:(CGRect)frameRect
             device:(nullable id<MTLDevice>)device
            xwidget:(struct xwidget *)xw {
  self = [super initWithFrame:frameRect device:device];
  if (self) {
    self.xw = xw;
    _mRenderer = [[FilamentDelegate alloc] initWithFilamentView:self];
    [self setDelegate:_mRenderer];
  }
  return self;
}

- (void)dealloc {
  [super dealloc];
  [_mRenderer release];
}

- (BOOL)acceptsFirstResponder {
  return YES;
}

- (void)mouseDown:(NSEvent *)event {
  [self.xw->xv->emacswindow mouseDown:event];
  [super mouseUp:event];
  _mClickStart = [self convertPoint:[event locationInWindow] fromView:nil];
}

- (void)mouseUp:(NSEvent *)event {
  [self.xw->xv->emacswindow mouseUp:event];
  [super mouseUp:event];
}

- (void)mouseDragged:(NSEvent *)event {
  NSPoint p = [self convertPoint:[event locationInWindow] fromView:nil];
  NSLog(@"Mousedrag delta %f %f", p.x - _mClickStart.x, p.y - _mClickStart.y);
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
#endif /* HAVE_FILAMENT */

#ifdef HAVE_BGFX
@interface XwBgfxView : MTKView
@property struct xwidget *xw;
@end

@implementation XwBgfxView : MTKView
BgfxDelegate *bgfxDelegate;

- (id)initWithFrame:(CGRect)frameRect
             device:(nullable id<MTLDevice>)device
            xwidget:(struct xwidget *)xw {
  self = [super initWithFrame:frameRect device:device];
  if (self) {
    self.xw = xw;
    bgfxDelegate = [[BgfxDelegate alloc] initWithBgfxView:self];
    [self setDelegate:bgfxDelegate];
  }
  return self;
}

- (void)dealloc {
  [bgfxDelegate release];
  [super dealloc];
}

- (BOOL)acceptsFirstResponder {
  return YES;
}

- (void)keyDown:(NSEvent *)event {
  [self.xw->xv->emacswindow keyDown:event];
}
@end
#endif /* HAVE_BGFX */

#ifdef HAVE_DAWN
@interface XwDawnView : MTKView
@property struct xwidget *xw;
@end

@implementation XwDawnView : MTKView
DawnDelegate *dawnDelegate;

- (id)initWithFrame:(CGRect)frameRect
             device:(nullable id<MTLDevice>)device
            xwidget:(struct xwidget *)xw {
  self = [super initWithFrame:frameRect device:device];
  if (self) {
    self.xw = xw;
    dawnDelegate = [[DawnDelegate alloc] initWithDawnView:self];
    [self setDelegate:dawnDelegate];
  }
  return self;
}

- (void)dealloc {
  [dawnDelegate release];
  [super dealloc];
}

- (BOOL)acceptsFirstResponder {
  return YES;
}

- (void)keyDown:(NSEvent *)event {
  [self.xw->xv->emacswindow keyDown:event];
}
@end
#endif /* HAVE_DAWN */

#ifdef HAVE_SLATE
@interface XwSlateView : MTKView
@property struct xwidget *xw;
@end

@implementation XwSlateView : MTKView
SlateDelegate *slateDelegate;

- (id)initWithFrame:(CGRect)frameRect
             device:(nullable id<MTLDevice>)device
            xwidget:(struct xwidget *)xw {
  self = [super initWithFrame:frameRect device:device];
  if (self) {
    self.xw = xw;
    slateDelegate = [[SlateDelegate alloc] initWithSlateView:self];
    [self setDelegate:slateDelegate];
  }
  return self;
}

- (void)dealloc {
  [slateDelegate release];
  [super dealloc];
}

- (BOOL)acceptsFirstResponder {
  return YES;
}

/* Forward mouse + keyboard into the embedded Slate widget tree so the
   interactive "slate viewer" (Starship gallery) is clickable.  Mouse events
   drive the gallery directly; keyboard is delivered to Slate AND still routed
   to Emacs's frame so global bindings (C-x b, C-g, ...) keep working. */
- (NSPoint)slatePointForEvent:(NSEvent *)event {
  return [self convertPoint:event.locationInWindow fromView:nil];
}

- (void)mouseMoved:(NSEvent *)event {
  [slateDelegate forwardMouseMoveTo:[self slatePointForEvent:event]];
}

- (void)mouseDragged:(NSEvent *)event {
  [slateDelegate forwardMouseMoveTo:[self slatePointForEvent:event]];
}

- (void)mouseDown:(NSEvent *)event {
  [self.window makeFirstResponder:self];
  [slateDelegate forwardMouseButton:0 down:YES at:[self slatePointForEvent:event]];
}

- (void)mouseUp:(NSEvent *)event {
  [slateDelegate forwardMouseButton:0 down:NO at:[self slatePointForEvent:event]];
}

- (void)rightMouseDown:(NSEvent *)event {
  [slateDelegate forwardMouseButton:1 down:YES at:[self slatePointForEvent:event]];
}

- (void)rightMouseUp:(NSEvent *)event {
  [slateDelegate forwardMouseButton:1 down:NO at:[self slatePointForEvent:event]];
}

- (void)scrollWheel:(NSEvent *)event {
  [slateDelegate forwardScroll:event.scrollingDeltaY];
}

- (void)keyDown:(NSEvent *)event {
  /* Deliver to Slate (virtual-key + characters), then let Emacs see it too so
     global keybindings continue to function. */
  NSEventModifierFlags m = event.modifierFlags;
  [slateDelegate forwardKey:(int)event.keyCode down:YES
                      shift:(m & NSEventModifierFlagShift) != 0
                       ctrl:(m & NSEventModifierFlagControl) != 0
                        alt:(m & NSEventModifierFlagOption) != 0
                        cmd:(m & NSEventModifierFlagCommand) != 0];
  NSString *chars = event.characters;
  for (NSUInteger i = 0; i < chars.length; i++)
    [slateDelegate forwardChar:[chars characterAtIndex:i]];
  [self.xw->xv->emacswindow keyDown:event];
}

- (void)keyUp:(NSEvent *)event {
  NSEventModifierFlags m = event.modifierFlags;
  [slateDelegate forwardKey:(int)event.keyCode down:NO
                      shift:(m & NSEventModifierFlagShift) != 0
                       ctrl:(m & NSEventModifierFlagControl) != 0
                        alt:(m & NSEventModifierFlagOption) != 0
                        cmd:(m & NSEventModifierFlagCommand) != 0];
}
@end
#endif /* HAVE_SLATE */

#ifdef HAVE_GODOT
/* The godot xwidget is a plain layer-backed NSView; GodotDelegate hosts the
   embedded Godot editor's CAContext via a CALayerHost sublayer (no MTKView,
   no per-frame blit).  Keyboard is routed to Emacs's frame so global bindings
   keep working (input injection into Godot is a TODO). */
@interface XwGodotView : NSView {
  NSPoint _lastGodotMousePoint;
  BOOL _hasLastGodotMousePoint;
}
@property struct xwidget *xw;
@end

@implementation XwGodotView
GodotDelegate *godotDelegate;

- (id)initWithFrame:(CGRect)frameRect
            xwidget:(struct xwidget *)xw
             editor:(BOOL)editor
            project:(const char *)project {
  self = [super initWithFrame:frameRect];
  if (self) {
    self.xw = xw;
    self.wantsLayer = YES;
    self.layer.masksToBounds = YES;
    godotDelegate = [[GodotDelegate alloc] initWithGodotView:self
                                                      editor:editor
                                                     project:project];
  }
  return self;
}

- (void)dealloc {
  [godotDelegate release];
  [super dealloc];
}

- (BOOL)acceptsFirstResponder {
  return YES;
}

/* Let the first click both focus the widget AND reach Godot (e.g. clicking a
   toolbar button in one gesture), like a normal editor surface. */
- (BOOL)acceptsFirstMouse:(NSEvent *)event {
  return YES;
}

- (BOOL)isFlipped {
  return YES;
}

/* A tracking area so -mouseMoved: fires for hover (button highlights, resize
   cursors, etc.) even when no button is held. */
- (void)updateTrackingAreas {
  for (NSTrackingArea *ta in [self.trackingAreas copy])
    [self removeTrackingArea:ta];
  NSTrackingArea *area = [[[NSTrackingArea alloc]
    initWithRect:self.bounds
         options:(NSTrackingMouseMoved | NSTrackingActiveInKeyWindow |
                  NSTrackingInVisibleRect)
           owner:self
        userInfo:nil] autorelease];
  [self addTrackingArea:area];
  [super updateTrackingAreas];
}

- (void)resizeGodotToBounds {
  const CGFloat scale = self.window ? self.window.backingScaleFactor
                                    : (NSScreen.mainScreen ? NSScreen.mainScreen.backingScaleFactor : 1.0);
  [godotDelegate resizeToPixels:NSMakeSize(self.bounds.size.width * scale,
                                           self.bounds.size.height * scale)];
}

- (void)viewDidMoveToWindow {
  [super viewDidMoveToWindow];
  [self resizeGodotToBounds];
}

- (void)layout {
  [super layout];
  [self resizeGodotToBounds];
}

/* Keep the hosted layer sized to the view. */
- (void)setFrameSize:(NSSize)newSize {
  [super setFrameSize:newSize];
  [self resizeGodotToBounds];
}

/* View-space point (flipped: top-left origin, points) for an event. */
- (NSPoint)godotPointForEvent:(NSEvent *)event {
  return [self convertPoint:event.locationInWindow fromView:nil];
}

- (NSPoint)godotRelativePointForPoint:(NSPoint)point {
  NSPoint rel = NSMakePoint(0, 0);
  if (_hasLastGodotMousePoint)
    rel = NSMakePoint(point.x - _lastGodotMousePoint.x,
                      point.y - _lastGodotMousePoint.y);
  _lastGodotMousePoint = point;
  _hasLastGodotMousePoint = YES;
  return rel;
}

- (void)forwardGodotMouseMoveEvent:(NSEvent *)event {
  NSPoint point = [self godotPointForEvent:event];
  [godotDelegate forwardMouseMoveTo:point
                           relative:[self godotRelativePointForPoint:point]
                                mods:[self godotModsForEvent:event]];
}

/* Godot modifier bitmask: 1=shift 2=ctrl 4=alt 8=cmd. */
- (int)godotModsForEvent:(NSEvent *)event {
  NSEventModifierFlags m = event.modifierFlags;
  int mods = 0;
  if (m & NSEventModifierFlagShift)   mods |= 1;
  if (m & NSEventModifierFlagControl) mods |= 2;
  if (m & NSEventModifierFlagOption)  mods |= 4;
  if (m & NSEventModifierFlagCommand) mods |= 8;
  return mods;
}

- (void)mouseMoved:(NSEvent *)event {
  [self forwardGodotMouseMoveEvent:event];
}

- (void)mouseDragged:(NSEvent *)event {
  [self forwardGodotMouseMoveEvent:event];
}

- (void)rightMouseDragged:(NSEvent *)event {
  [self forwardGodotMouseMoveEvent:event];
}

- (void)otherMouseDragged:(NSEvent *)event {
  [self forwardGodotMouseMoveEvent:event];
}

- (void)mouseDown:(NSEvent *)event {
  [self.window makeFirstResponder:self];
  NSPoint point = [self godotPointForEvent:event];
  [self godotRelativePointForPoint:point];
  [godotDelegate forwardMouseButton:0 down:YES at:point
                              mods:[self godotModsForEvent:event]
                       doubleClick:event.clickCount >= 2];
}

- (void)mouseUp:(NSEvent *)event {
  NSPoint point = [self godotPointForEvent:event];
  [self godotRelativePointForPoint:point];
  [godotDelegate forwardMouseButton:0 down:NO at:point
                              mods:[self godotModsForEvent:event]
                       doubleClick:NO];
}

- (void)rightMouseDown:(NSEvent *)event {
  [self.window makeFirstResponder:self];
  NSPoint point = [self godotPointForEvent:event];
  [self godotRelativePointForPoint:point];
  [godotDelegate forwardMouseButton:1 down:YES at:point
                              mods:[self godotModsForEvent:event]
                       doubleClick:event.clickCount >= 2];
}

- (void)rightMouseUp:(NSEvent *)event {
  NSPoint point = [self godotPointForEvent:event];
  [self godotRelativePointForPoint:point];
  [godotDelegate forwardMouseButton:1 down:NO at:point
                              mods:[self godotModsForEvent:event]
                       doubleClick:NO];
}

- (void)otherMouseDown:(NSEvent *)event {
  [self.window makeFirstResponder:self];
  NSPoint point = [self godotPointForEvent:event];
  [self godotRelativePointForPoint:point];
  [godotDelegate forwardMouseButton:2 down:YES at:point
                              mods:[self godotModsForEvent:event]
                       doubleClick:event.clickCount >= 2];
}

- (void)otherMouseUp:(NSEvent *)event {
  NSPoint point = [self godotPointForEvent:event];
  [self godotRelativePointForPoint:point];
  [godotDelegate forwardMouseButton:2 down:NO at:point
                              mods:[self godotModsForEvent:event]
                       doubleClick:NO];
}

- (void)scrollWheel:(NSEvent *)event {
  /* Positive deltaY = scroll up in Godot (WHEEL_UP).  Use precise deltas when
     available (trackpad), else the line-based scrollingDeltaY. */
  CGFloat dy = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY * 0.1
                                               : event.scrollingDeltaY;
  if (dy != 0.0)
    [godotDelegate forwardScroll:dy at:[self godotPointForEvent:event]
                            mods:[self godotModsForEvent:event]];
}

- (void)keyDown:(NSEvent *)event {
  /* Deliver to Godot (virtual keycode + typed unicode), then let Emacs see it
     too so global keybindings (C-x b, C-g, ...) keep working. */
  int mods = [self godotModsForEvent:event];
  NSString *chars = event.characters;
  uint32_t unicode = (chars.length > 0) ? [chars characterAtIndex:0] : 0;
  [godotDelegate forwardKey:(int)event.keyCode down:YES mods:mods unicode:unicode];
  [self.xw->xv->emacswindow keyDown:event];
}

- (void)keyUp:(NSEvent *)event {
  int mods = [self godotModsForEvent:event];
  [godotDelegate forwardKey:(int)event.keyCode down:NO mods:mods unicode:0];
}
@end
#endif /* HAVE_GODOT */

/* Xwidget webkit commands.  */

bool nsxwidget_is_web_view(struct xwidget *xw) {
  return xw->xwWidget != NULL && [xw->xwWidget isKindOfClass:WKWebView.class];
}

bool nsxwidget_is_metal_view(struct xwidget *xw) {
  return xw->xwWidget != NULL && [xw->xwWidget isKindOfClass:MTKView.class];
}

/* Called from the xwidget-slate-shutdown DEFUN (wired to kill-emacs-hook).
   Stops the embedded Unreal engine and hard-exits, before Emacs's exit()
   runs the engine's static destructors (which crash for an embedded engine). */
void nsxwidget_slate_shutdown(void) {
  [SlateDelegate shutdownEngineAndExit];
}

/* Called from the xwidget-godot-shutdown DEFUN (wired to kill-emacs-hook).
   Hard-exits before Emacs's exit() runs the embedded Godot engine's static
   destructors. */
void nsxwidget_godot_shutdown(void) {
#ifdef HAVE_GODOT
  [GodotDelegate shutdownEngineAndExit];
#endif
}

Lisp_Object nsxwidget_webkit_uri(struct xwidget *xw) {
  XwWebView *xwWebView = (XwWebView *)xw->xwWidget;
  return [xwWebView.URL.absoluteString lispString];
}

Lisp_Object nsxwidget_webkit_title(struct xwidget *xw) {
  XwWebView *xwWebView = (XwWebView *)xw->xwWidget;
  return [xwWebView.title lispString];
}

/* @Note ATS - Need application transport security in 'Info.plist' or
   remote pages will not loaded.  */
void nsxwidget_webkit_goto_uri(struct xwidget *xw, const char *uri) {
  XwWebView *xwWebView = (XwWebView *)xw->xwWidget;
  NSString *urlString = [NSString stringWithUTF8String:uri];
  NSURL *url = [NSURL URLWithString:urlString];
  NSURLRequest *urlRequest = [NSURLRequest requestWithURL:url];
  [xwWebView loadRequest:urlRequest];
}

void nsxwidget_webkit_goto_history(struct xwidget *xw, int rel_pos) {
  XwWebView *xwWebView = (XwWebView *)xw->xwWidget;
  switch (rel_pos) {
  case -1:
    [xwWebView goBack];
    break;
  case 0:
    [xwWebView reload];
    break;
  case 1:
    [xwWebView goForward];
    break;
  }
}

double
nsxwidget_webkit_estimated_load_progress (struct xwidget *xw)
{
  XwWebView *xwWebView = (XwWebView *) xw->xwWidget;
  return xwWebView.estimatedProgress;
}

void
nsxwidget_webkit_stop_loading (struct xwidget *xw)
{
  XwWebView *xwWebView = (XwWebView *) xw->xwWidget;
  [xwWebView stopLoading];
}

void
nsxwidget_webkit_zoom (struct xwidget *xw, double zoom_change)
{
  XwWebView *xwWebView = (XwWebView *) xw->xwWidget;
  xwWebView.magnification += zoom_change;
  /* TODO: setMagnification:centeredAtPoint.  */
}

/* Recursively convert an objc native type JavaScript value to a Lisp
   value.  Mostly copied from GTK xwidget 'webkit_js_to_lisp'.  */
static Lisp_Object js_to_lisp(id value) {
  if (value == nil || [value isKindOfClass:NSNull.class])
    return Qnil;
  else if ([value isKindOfClass:NSString.class])
    return [(NSString *)value lispString];
  else if ([value isKindOfClass:NSNumber.class]) {
    NSNumber *nsnum = (NSNumber *)value;
    char type = nsnum.objCType[0];
    if (type == 'c') /* __NSCFBoolean has type character 'c'.  */
      return nsnum.boolValue ? Qt : Qnil;
    else {
      if (type == 'i' || type == 'l')
        return make_int(nsnum.longValue);
      else if (type == 'f' || type == 'd')
        return make_float(nsnum.doubleValue);
      /* else fall through.  */
    }
  } else if ([value isKindOfClass:NSArray.class]) {
    NSArray *nsarr = (NSArray *)value;
    EMACS_INT n = nsarr.count;
    Lisp_Object obj;
    struct Lisp_Vector *p = allocate_nil_vector(n);

    for (ptrdiff_t i = 0; i < n; ++i)
      p->contents[i] = js_to_lisp([nsarr objectAtIndex:i]);
    XSETVECTOR(obj, p);
    return obj;
  } else if ([value isKindOfClass:NSDictionary.class]) {
    NSDictionary *nsdict = (NSDictionary *)value;
    NSArray *keys = nsdict.allKeys;
    ptrdiff_t n = keys.count;
    Lisp_Object obj;
    struct Lisp_Vector *p = allocate_nil_vector(n);

    for (ptrdiff_t i = 0; i < n; ++i) {
      NSString *prop_key = (NSString *)[keys objectAtIndex:i];
      id prop_value = [nsdict valueForKey:prop_key];
      p->contents[i] = Fcons([prop_key lispString], js_to_lisp(prop_value));
    }
    XSETVECTOR(obj, p);
    return obj;
  }
  NSLog(@"Unhandled type in javascript result");
  return Qnil;
}

void nsxwidget_webkit_execute_script(struct xwidget *xw, const char *script,
                                     Lisp_Object fun) {
  XwWebView *xwWebView = (XwWebView *)xw->xwWidget;
  if ([xwWebView.urlScriptBlocked[xwWebView.URL] boolValue]) {
    message("Javascript is blocked by 'CSP: sandbox'.");
    return;
  }

  NSString *javascriptString = [NSString stringWithUTF8String:script];
  [xwWebView evaluateJavaScript:javascriptString
              completionHandler:^(id result, NSError *error) {
      if (error)
        {
          NSLog (@"evaluateJavaScript error : %@", error.localizedDescription);
          NSLog (@"error script=%@", javascriptString);
        }
      else if (result && FUNCTIONP (fun))
        {
          /* NSLog (@"result=%@, type=%@", result, [result class]); */
          Lisp_Object lisp_value = js_to_lisp (result);
          store_xwidget_js_callback_event (xw, fun, lisp_value);
        }
    }];
}

/* Window containing an xwidget.  */

@implementation XwWindow
- (BOOL) isFlipped { return YES; }
@end

/* Xwidget model, macOS Cocoa part.  */

void
nsxwidget_init (struct xwidget *xw)
{
  block_input ();
  NSRect rect = NSMakeRect (0, 0, xw->width, xw->height);
  if (EQ (xw->type, Qmetal))
    {
      /* Metal-backed xwidget: create an MTKView driven by AAPLRenderer
         (draws the triangle) instead of a WebKit view.  */
      id<MTLDevice> device = MTLCreateSystemDefaultDevice ();
      xw->xwWidget = [[XwMetalView alloc]
                       initWithFrame:rect
                              device:device
                             xwidget:xw];
    }
#ifdef HAVE_VULKAN
  else if (EQ (xw->type, Qvulkan))
    {
      /* Vulkan-backed xwidget: MTKView whose CAMetalLayer is rendered
         to via MoltenVK (VK_EXT_metal_surface).  */
      id<MTLDevice> device = MTLCreateSystemDefaultDevice ();
      xw->xwWidget = [[XwVulkanView alloc]
                       initWithFrame:rect
                              device:device
                             xwidget:xw];
    }
#endif
#ifdef HAVE_FILAMENT
  else if (EQ (xw->type, Qfilament))
    {
      /* Filament-backed xwidget: MTKView driven by FilamentDelegate
         (Metal backend, renders into the view's CAMetalLayer).  */
      id<MTLDevice> device = MTLCreateSystemDefaultDevice ();
      xw->xwWidget = [[XwFilamentView alloc]
                       initWithFrame:rect
                              device:device
                             xwidget:xw];
    }
#endif
#ifdef HAVE_BGFX
  else if (EQ (xw->type, Qbgfx))
    {
      /* bgfx-backed xwidget: MTKView driven by BgfxDelegate (Metal
         renderer, draws into a CAMetalLayer via bgfx).  */
      id<MTLDevice> device = MTLCreateSystemDefaultDevice ();
      xw->xwWidget = [[XwBgfxView alloc]
                       initWithFrame:rect
                              device:device
                             xwidget:xw];
    }
#endif
#ifdef HAVE_DAWN
  else if (EQ (xw->type, Qdawn))
    {
      /* Dawn (WebGPU) xwidget: MTKView driven by DawnDelegate, which
         renders into a CAMetalLayer via a WebGPU metal surface.  */
      id<MTLDevice> device = MTLCreateSystemDefaultDevice ();
      xw->xwWidget = [[XwDawnView alloc]
                       initWithFrame:rect
                              device:device
                             xwidget:xw];
    }
#endif
#ifdef HAVE_SLATE
  else if (EQ (xw->type, Qslate))
    {
      /* Unreal Slate xwidget: MTKView whose drawable is blitted from the
         embedded Unreal engine's offscreen render target (libSlateOffscreen).  */
      id<MTLDevice> device = MTLCreateSystemDefaultDevice ();
      xw->xwWidget = [[XwSlateView alloc]
                       initWithFrame:rect
                              device:device
                             xwidget:xw];
    }
#endif
#ifdef HAVE_GODOT
  else if (EQ (xw->type, Qgodot))
    {
      /* Godot xwidget: a layer-backed NSView hosting the embedded Godot
         editor's CAContext via a CALayerHost (GodotDelegate + libGodotOffscreen).
         Lisp passes :editor and :project in the xwidget argument plist. */
      BOOL editor = !NILP (Fplist_get (xw->private_data, QCeditor, Qnil));
      Lisp_Object project = Fplist_get (xw->private_data, QCproject, Qnil);
      const char *project_path = STRINGP (project) ? SSDATA (project) : NULL;
      xw->xwWidget = [[XwGodotView alloc]
                       initWithFrame:rect
                             xwidget:xw
                              editor:editor
                             project:project_path];
    }
#endif
  else
    {
      xw->xwWidget = [[XwWebView alloc]
                       initWithFrame:rect
                       configuration:[[[WKWebViewConfiguration alloc] init]
                                       autorelease]
                             xwidget:xw];
    }
  xw->xwWindow = [[XwWindow alloc]
                   initWithFrame:rect];
  /* MTKView is layer-backed (CAMetalLayer).  Nesting a layer-backed
     view inside a non-layer-backed container produces an inconsistent
     CALayer tree, which crashes AppKit during relayout (e.g. when the
     frame title changes on C-x b).  Make the container layer-backed so
     the layer hierarchy stays consistent.  */
  if (EQ (xw->type, Qmetal) || EQ (xw->type, Qvulkan)
      || EQ (xw->type, Qfilament) || EQ (xw->type, Qbgfx)
      || EQ (xw->type, Qdawn) || EQ (xw->type, Qslate)
      || EQ (xw->type, Qgodot))
    xw->xwWindow.wantsLayer = YES;
  [xw->xwWindow addSubview:xw->xwWidget];
  xw->xv = NULL; /* for 1 to 1 relationship of webkit2.  */
  unblock_input();
}

void nsxwidget_kill(struct xwidget *xw) {
  if (xw) {
    if (EQ(xw->type, Qwebkit)) {
      WKUserContentController *scriptor =
          ((XwWebView *)xw->xwWidget).configuration.userContentController;
      [scriptor removeAllUserScripts];
      [scriptor removeScriptMessageHandlerForName:@"keyDown"];

      if (xw->xv)
        xw->xv->model = Qnil; /* Make sure related view stale.  */

      /* This stops playing audio when a xwidget-webkit buffer is
         killed.  I could not find other solution.
         TODO: improve this */
      nsxwidget_webkit_goto_uri (xw, "about:blank");

      [((XwWebView *) xw->xwWidget).urlScriptBlocked release];
      [xw->xwWidget removeFromSuperviewWithoutNeedingDisplay];

      [xw->xwWidget release];
      [xw->xwWindow removeFromSuperviewWithoutNeedingDisplay];
      [xw->xwWindow release];
      xw->xwWidget = nil;
    }

    if (xw->xv)
      xw->xv->model = Qnil; /* Make sure related view stale.  */

    [xw->xwWidget removeFromSuperviewWithoutNeedingDisplay];
    [xw->xwWidget release];
    [xw->xwWindow removeFromSuperviewWithoutNeedingDisplay];
    [xw->xwWindow release];
    xw->xwWidget = nil;
  }
}

void nsxwidget_resize(struct xwidget *xw) {
  if (xw->xwWidget) {
    [xw->xwWindow setFrameSize:NSMakeSize(xw->width, xw->height)];
    [xw->xwWidget setFrameSize:NSMakeSize(xw->width, xw->height)];
  }
}

Lisp_Object nsxwidget_get_size(struct xwidget *xw) {
  return list2i(xw->xwWidget.frame.size.width, xw->xwWidget.frame.size.height);
}

/* Xwidget view, macOS Cocoa part.  */

@implementation XvWindow : NSView
- (BOOL) isFlipped { return YES; }
@end

void nsxwidget_init_view(struct xwidget_view *xv, struct xwidget *xw,
                         struct glyph_string *s, int x, int y) {
  /* 'x_draw_xwidget_glyph_string' will calculate correct position and
     size of clip to draw in emacs buffer window.  Thus, just begin at
     origin with no crop.  */
  xv->x = x;
  xv->y = y;
  xv->clip_left = 0;
  xv->clip_right = xw->width;
  xv->clip_top = 0;
  xv->clip_bottom = xw->height;

  xv->xvWindow =
      [[XvWindow alloc] initWithFrame:NSMakeRect(x, y, xw->width, xw->height)];
  xv->xvWindow.xw = xw;
  xv->xvWindow.xv = xv;
  /* Keep the layer hierarchy consistent for layer-backed (Metal/Vulkan/
     Filament/bgfx/Dawn) widgets; see nsxwidget_init.  */
  if (EQ (xw->type, Qmetal) || EQ (xw->type, Qvulkan)
      || EQ (xw->type, Qfilament) || EQ (xw->type, Qbgfx)
      || EQ (xw->type, Qdawn) || EQ (xw->type, Qslate)
      || EQ (xw->type, Qgodot))
    xv->xvWindow.wantsLayer = YES;

  xw->xv = xv; /* For 1 to 1 relationship of webkit2.  */
  [xv->xvWindow addSubview:xw->xwWindow];

  xv->emacswindow = FRAME_NS_VIEW(s->f);
  [xv->emacswindow addSubview:xv->xvWindow];

  // if(EQ(xw->type, Qmetal)){
  //  nsxwidget_set_needsdisplay(xv);
  //}
}

void nsxwidget_delete_view(struct xwidget_view *xv) {
  if (!EQ(xv->model, Qnil)) {
    struct xwidget *xw = XXWIDGET(xv->model);
    [xw->xwWindow removeFromSuperviewWithoutNeedingDisplay];
    xw->xv = NULL; /* Now model has no view.  */
  }
  [xv->xvWindow removeFromSuperviewWithoutNeedingDisplay];
  [xv->xvWindow release];
}

void nsxwidget_show_view(struct xwidget_view *xv) {
  xv->hidden = NO;
  [xv->xvWindow
      setFrameOrigin:NSMakePoint(xv->x + xv->clip_left, xv->y + xv->clip_top)];
}

void nsxwidget_hide_view(struct xwidget_view *xv) {
  xv->hidden = YES;
  [xv->xvWindow setFrameOrigin:NSMakePoint(10000, 10000)];
}

void nsxwidget_resize_view(struct xwidget_view *xv, int width, int height) {
  [xv->xvWindow setFrameSize:NSMakeSize(width, height)];
}

void nsxwidget_move_view(struct xwidget_view *xv, int x, int y) {
  [xv->xvWindow setFrameOrigin:NSMakePoint(x, y)];
}

/* Move model window in container (view window).  */
void nsxwidget_move_widget_in_view(struct xwidget_view *xv, int x, int y) {
  struct xwidget *xww = xv->xvWindow.xw;
  [xww->xwWindow setFrameOrigin:NSMakePoint(x, y)];
}

void nsxwidget_set_needsdisplay(struct xwidget_view *xv) {
  xv->xvWindow.needsDisplay = YES;
}
