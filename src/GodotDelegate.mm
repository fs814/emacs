#include <config.h>

#ifdef HAVE_GODOT

#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>

#import "GodotDelegate.h"

#include <dlfcn.h>
#include <stdlib.h>
#include <unistd.h>
#include <stdio.h>

/* The "godot" xwidget embeds the Godot editor (or a game) via libGodotOffscreen
   (macbuild/gameengine/godot/godot-offscreen).  That shim dlopens the patched,
   editor (tools-enabled) libgodot, boots it with the embedded macOS
   DisplayServer (`--embedded --display-driver embedded --rendering-driver
   metal [-e]`), and publishes the CAContext id of the rendered CAMetalLayer.
   We display that context in-process via a CALayerHost sublayer -- no blit. */

/* Private CoreAnimation remote-layer SPI (as used by Chromium and Godot's own
   editor host, platform/macos/macos_quartz_core_spi.h).  A CALayerHost with a
   contextId displays the CALayer set on the CAContext with that id. */
typedef uint32_t CAContextID;
@interface CALayerHost : CALayer
@property CAContextID contextId;
@end

/* Shim C ABI (GodotOffscreenHost.h). */
typedef int      (*pfn_Init)(int, int, const char *, bool);
typedef void     (*pfn_Resize)(int, int);
typedef void     (*pfn_SetScale)(float);
typedef uint32_t (*pfn_GetContextId)(void);
typedef void    *(*pfn_GetWindowView)(void);
typedef void     (*pfn_Shutdown)(void);
typedef void     (*pfn_MouseButton)(int, bool, float, float, int, bool);
typedef void     (*pfn_MouseMove)(float, float, float, float, int);
typedef void     (*pfn_MouseWheel)(float, float, float, int);
typedef void     (*pfn_Key)(int, bool, int, uint32_t);

/* File-scope shutdown fn for +shutdownEngineAndExit (kill-emacs-hook). */
static pfn_Shutdown GGodotShutdownFn = nullptr;

@implementation GodotDelegate {
  NSView *_view;
  CALayerHost *_layerHost;
  CALayer *_directLayerHost;

  void *_dl;
  pfn_Init _init;
  pfn_Resize _resize;
  pfn_SetScale _setScale;
  pfn_GetContextId _getContextId;
  pfn_GetWindowView _getWindowView;
  pfn_Shutdown _shutdown;
  pfn_MouseButton _mouseButton;
  pfn_MouseMove _mouseMove;
  pfn_MouseWheel _mouseWheel;
  pfn_Key _key;

  uint32_t _contextId;
  CALayer *_directLayer;
  CGSize _directLayerNativeSize;
  NSTimer *_pollTimer;
  bool _ready;
}

/* Resolve libGodotOffscreen.dylib: $GODOT_OFFSCREEN_SHIM wins, else the build
   location under $HOME. */
- (nonnull NSString *)libraryPath {
  const char *env = getenv("GODOT_OFFSCREEN_SHIM");
  if (env && *env)
    return [NSString stringWithUTF8String:env];
  const char *home = getenv("HOME");
  return [NSString stringWithFormat:
                     @"%s/sourcecode/Settings/macbuild/gameengine/godot/"
                      "godot-offscreen/libGodotOffscreen.dylib",
                   home ? home : ""];
}

- (BOOL)loadLibrary {
  NSString *path = [self libraryPath];
  _dl = dlopen(path.UTF8String, RTLD_NOW | RTLD_LOCAL);
  if (!_dl) {
    NSLog(@"GodotDelegate: dlopen(%@) failed: %s", path, dlerror());
    return NO;
  }
  _init          = (pfn_Init)         dlsym(_dl, "GodotOffscreen_Init");
  _resize        = (pfn_Resize)       dlsym(_dl, "GodotOffscreen_Resize");
  _setScale      = (pfn_SetScale)     dlsym(_dl, "GodotOffscreen_SetScale");
  _getContextId  = (pfn_GetContextId) dlsym(_dl, "GodotOffscreen_GetContextId");
  _getWindowView = (pfn_GetWindowView)dlsym(_dl, "GodotOffscreen_GetWindowView");
  _shutdown      = (pfn_Shutdown)     dlsym(_dl, "GodotOffscreen_Shutdown");
  _mouseButton   = (pfn_MouseButton)  dlsym(_dl, "GodotOffscreen_MouseButton");
  _mouseMove     = (pfn_MouseMove)    dlsym(_dl, "GodotOffscreen_MouseMove");
  _mouseWheel    = (pfn_MouseWheel)   dlsym(_dl, "GodotOffscreen_MouseWheel");
  _key           = (pfn_Key)          dlsym(_dl, "GodotOffscreen_Key");
  GGodotShutdownFn = _shutdown;
  if (!_init || !_getContextId) {
    NSLog(@"GodotDelegate: missing GodotOffscreen_* symbols");
    return NO;
  }
  return YES;
}

- (CGFloat)backingScale {
  if (_view.window)
    return _view.window.backingScaleFactor;
  NSScreen *screen = _view.window.screen ?: NSScreen.mainScreen;
  return screen ? screen.backingScaleFactor : 1.0;
}

- (nonnull instancetype)initWithGodotView:(nonnull NSView *)view
                                   editor:(BOOL)editor
                                  project:(nullable const char *)projectPath {
  self = [super init];
  if (self) {
    _view = view;
    _view.wantsLayer = YES;
    _ready = false;
    _contextId = 0;
    _directLayer = nil;
    _directLayerHost = nil;
    _directLayerNativeSize = CGSizeZero;

    if ([self loadLibrary]) {
      const CGFloat scale = [self backingScale];
      const int w = MAX(1, (int)(_view.bounds.size.width * scale));
      const int h = MAX(1, (int)(_view.bounds.size.height * scale));
      if (_setScale) _setScale((float)scale);
      /* editor=YES boots the full Godot editor; NO runs the project's scene. */
      if (_init(w, h, projectPath, editor ? true : false) == 0)
        _ready = true;
      else
        NSLog(@"GodotDelegate: GodotOffscreen_Init failed");

      /* Poll for the CAContext id (published once the embedded DisplayServer is
         up on the game thread), then attach a CALayerHost to display it. */
      _pollTimer = [NSTimer scheduledTimerWithTimeInterval:0.1
                                                    repeats:YES
                                                      block:^(NSTimer *t) {
        [self tryAttachContext];
      }];
    }
  }
  return self;
}

- (void)tryAttachContext {
  if (_contextId != 0 || _directLayer != nil)
    return;

  /* Mount Godot's own CAMetalLayer directly (in-process CALayerHost/CAContext
     remoting composited blank here -- valid contextId, correct geometry, no
     pixels).  CRASH-SAFETY CONTRACT: the game thread OWNS this layer's geometry
     -- it renders into it.  The host (this, the Emacs main thread) must NEVER
     ask Godot to resize that embedded window after startup: Godot's embedded
     macOS window rejects resize, and the notification path trips Godot's node
     thread-guard.  We put Godot's layer inside an Emacs-owned container and
     scale the container's sublayer transform on host view resize. */
  CALayer *godotLayer = _getWindowView ? (CALayer *)_getWindowView() : nil;
  uint32_t ctx = _getContextId ? _getContextId() : 0;
  if (godotLayer == nil && ctx == 0)
    return;
  _contextId = ctx;
  [_pollTimer invalidate];
  _pollTimer = nil;

  _view.wantsLayer = YES;
  _view.layer.masksToBounds = YES;

  [CATransaction begin];
  [CATransaction setDisableActions:YES];

  if (godotLayer) {
    _directLayer = [godotLayer retain];
    _directLayerNativeSize = _directLayer.bounds.size;
    [_directLayer removeFromSuperlayer];
    _directLayer.contentsScale = [self backingScale];
    _directLayer.anchorPoint = CGPointMake(0, 0);
    _directLayer.position = CGPointMake(0, 0);
    /* Deliberately NOT setting .frame/.bounds or .autoresizingMask: the game
       thread owns the layer's size.  masksToBounds on the host view clips any
       transient overflow during a resize. */
    _directLayer.zPosition = 1;
    _directLayerHost = [[CALayer layer] retain];
    _directLayerHost.anchorPoint = CGPointMake(0, 0);
    _directLayerHost.position = CGPointMake(0, 0);
    _directLayerHost.masksToBounds = YES;
    _directLayerHost.frame = _view.layer.bounds;
    [_directLayerHost addSublayer:_directLayer];
    [_view.layer addSublayer:_directLayerHost];
  } else {
    /* Fallback: host Godot's CAContext remote layer (blank in-process, kept for
       completeness). */
    _layerHost = [CALayerHost layer];
    _layerHost.contextId = ctx;
    _layerHost.contentsScale = [self backingScale];
    _layerHost.anchorPoint = CGPointMake(0, 0);
    _layerHost.position = CGPointMake(0, 0);
    _layerHost.frame = _view.layer.bounds;
    _layerHost.autoresizingMask = kCALayerWidthSizable | kCALayerHeightSizable;
    _layerHost.zPosition = 1;
    [_view.layer addSublayer:_layerHost];
  }

  [_view.layer setNeedsLayout];
  [_view.layer setNeedsDisplay];
  [self resizeToPixels:NSMakeSize(_view.bounds.size.width * [self backingScale],
                                  _view.bounds.size.height * [self backingScale])];

  [CATransaction commit];

  NSLog(@"GodotDelegate: attach ctx=%u directLayer=%p viewBounds=%@ layerBounds=%@",
        ctx, _directLayer, NSStringFromRect(_view.bounds),
        NSStringFromRect(NSRectFromCGRect((_directLayer ?: _layerHost).bounds)));
}

- (void)resizeToPixels:(NSSize)pixelSize {
  if (_ready && _setScale) _setScale((float)[self backingScale]);
  /* Do NOT call _resize for the direct-layer path.  Godot's embedded macOS
     window cannot be resized safely after startup.  Keep Godot's own layer at
     its native size and scale it through an Emacs-owned container layer. */
  if (_directLayerHost) {
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _directLayerHost.contentsScale = [self backingScale];
    _directLayerHost.frame = _view.layer.bounds;
    CGFloat nativeW = _directLayerNativeSize.width > 0 ? _directLayerNativeSize.width : _directLayer.bounds.size.width;
    CGFloat nativeH = _directLayerNativeSize.height > 0 ? _directLayerNativeSize.height : _directLayer.bounds.size.height;
    CGFloat sx = nativeW > 0 ? _view.layer.bounds.size.width / nativeW : 1.0;
    CGFloat sy = nativeH > 0 ? _view.layer.bounds.size.height / nativeH : 1.0;
    _directLayerHost.sublayerTransform = CATransform3DMakeScale(sx, sy, 1.0);
    [_view.layer setNeedsLayout];
    [_view.layer setNeedsDisplay];
    [CATransaction commit];
    return;
  }
  if (_ready && _resize)
    _resize((int)pixelSize.width, (int)pixelSize.height);
  if (_layerHost) {
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _layerHost.contentsScale = [self backingScale];
    _layerHost.frame = _view.layer.bounds;
    [_view.layer setNeedsLayout];
    [_view.layer setNeedsDisplay];
    [CATransaction commit];
  }
}

- (NSPoint)mapPointToGodotNative:(NSPoint)pt {
  if (!_directLayerHost)
    return pt;
  CGFloat nativeW = _directLayerNativeSize.width > 0 ? _directLayerNativeSize.width : _directLayer.bounds.size.width;
  CGFloat nativeH = _directLayerNativeSize.height > 0 ? _directLayerNativeSize.height : _directLayer.bounds.size.height;
  CGFloat sx = nativeW > 0 ? _directLayerHost.bounds.size.width / nativeW : 1.0;
  CGFloat sy = nativeH > 0 ? _directLayerHost.bounds.size.height / nativeH : 1.0;
  if (sx <= 0.0) sx = 1.0;
  if (sy <= 0.0) sy = 1.0;
  return NSMakePoint(pt.x / sx, pt.y / sy);
}

- (NSPoint)mapRelativeToGodotNative:(NSPoint)rel {
  if (!_directLayerHost)
    return rel;
  CGFloat nativeW = _directLayerNativeSize.width > 0 ? _directLayerNativeSize.width : _directLayer.bounds.size.width;
  CGFloat nativeH = _directLayerNativeSize.height > 0 ? _directLayerNativeSize.height : _directLayer.bounds.size.height;
  CGFloat sx = nativeW > 0 ? _directLayerHost.bounds.size.width / nativeW : 1.0;
  CGFloat sy = nativeH > 0 ? _directLayerHost.bounds.size.height / nativeH : 1.0;
  if (sx <= 0.0) sx = 1.0;
  if (sy <= 0.0) sy = 1.0;
  return NSMakePoint(rel.x / sx, rel.y / sy);
}

/* ---- Input forwarding ----------------------------------------------------
   The shim/libgodot expect view POINTS (they scale to render pixels) with a
   modifier bitmask (1=shift 2=ctrl 4=alt 8=cmd).  Godot's render origin is
   top-left and XwGodotView isFlipped==YES, so view points map directly. */
- (void)forwardMouseButton:(int)button down:(BOOL)down at:(NSPoint)pt mods:(int)mods doubleClick:(BOOL)doubleClick {
  pt = [self mapPointToGodotNative:pt];
  if (_ready && _mouseButton)
    _mouseButton(button, down ? true : false, (float)pt.x, (float)pt.y, mods,
                 doubleClick ? true : false);
}

- (void)forwardMouseMoveTo:(NSPoint)pt relative:(NSPoint)rel mods:(int)mods {
  pt = [self mapPointToGodotNative:pt];
  rel = [self mapRelativeToGodotNative:rel];
  if (_ready && _mouseMove)
    _mouseMove((float)pt.x, (float)pt.y, (float)rel.x, (float)rel.y, mods);
}

- (void)forwardScroll:(CGFloat)deltaY at:(NSPoint)pt mods:(int)mods {
  pt = [self mapPointToGodotNative:pt];
  if (_ready && _mouseWheel)
    _mouseWheel((float)pt.x, (float)pt.y, (float)deltaY, mods);
}

- (void)forwardKey:(int)keyCode down:(BOOL)down mods:(int)mods unicode:(uint32_t)unicode {
  if (_ready && _key)
    _key(keyCode, down ? true : false, mods, unicode);
}

/* kill-emacs-hook: stop the engine and hard-exit before C exit() runs Godot's
   static destructors on the host thread. */
+ (void)shutdownEngineAndExit {
  if (!GGodotShutdownFn)
    return; /* no godot xwidget was created */
  /* Do NOT join/tear down the embedded engine (per-process singleton, not
     re-initializable).  Just hard-exit, bypassing static-destructor teardown. */
  fflush(nullptr);
  _exit(0);
}

- (void)dealloc {
  /* Per-process singleton engine: keep it running, keep the dylib mapped (a
     re-opened godot xwidget reuses it).  See SlateDelegate -dealloc. */
  [_pollTimer invalidate];
  [_directLayerHost release];
  [_directLayer release];
  [super dealloc];
}

@end

#endif /* HAVE_GODOT */
