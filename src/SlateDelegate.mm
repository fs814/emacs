#include <config.h>

#ifdef HAVE_SLATE

#import <AppKit/AppKit.h>
#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>
#import <IOSurface/IOSurface.h>

#import "SlateDelegate.h"

#include <dlfcn.h>
#include <stdlib.h>
#include <unistd.h>   /* _exit */
#include <stdio.h>    /* fflush */

/* The "slate" xwidget composites the offscreen output of an embedded Unreal
   engine (libSlateOffscreen.dylib, built from macbuild/gameengine/unreal6/
   slate-offscreen).  Unlike the filament/bgfx/dawn delegates, that library does
   NOT render into our CAMetalLayer: it renders Slate to its own render target on
   the engine game thread, and we pull the frame back and blit it into the view's
   drawable.

   The library is dlopen'd (not linked): it is a ~318 MB monolithic engine with
   its own main() and allocator, and it has @rpath dependencies on engine
   ThirdParty dylibs, so it must be loaded in place from the engine Binaries
   directory.  Its C ABI mirrors SlateOffscreenHost.h in the UE source tree.  */

typedef int         (*pfn_Init)(int, int, const char *);
typedef void        (*pfn_Resize)(int, int);
typedef void        (*pfn_SetScale)(float);
typedef void        (*pfn_Tick)(float);
typedef const void *(*pfn_LockPixels)(int *, int *, int *);
typedef void        (*pfn_UnlockPixels)(void);
typedef void        (*pfn_Shutdown)(void);
typedef void       *(*pfn_GetIOSurface)(int *, int *);
typedef void        (*pfn_MouseMove)(float, float);
typedef void        (*pfn_MouseButton)(int, bool);
typedef void        (*pfn_MouseWheel)(float);
typedef void        (*pfn_Key)(int, bool, bool, bool, bool, bool);
typedef void        (*pfn_Char)(uint32_t);

/* File-scope copy of the engine shutdown entry point, so the class method
   +shutdownEngineAndExit (invoked from kill-emacs-hook) can reach it without
   a live delegate instance. */
static pfn_Shutdown GSlateShutdownFn = nullptr;

@implementation SlateDelegate {
  MTKView *_view;

  void *_dl;
  pfn_Init _init;
  pfn_Resize _resize;
  pfn_SetScale _setScale;
  pfn_Tick _tick;
  pfn_LockPixels _lock;
  pfn_UnlockPixels _unlock;
  pfn_Shutdown _shutdown;
  pfn_GetIOSurface _getIOSurface;
  pfn_MouseMove _mouseMove;
  pfn_MouseButton _mouseButton;
  pfn_MouseWheel _mouseWheel;
  pfn_Key _key;
  pfn_Char _char;

  id<MTLCommandQueue> _queue;
  id<MTLTexture> _tex; /* BGRA8, holds the last frame uploaded from the engine */
  int _texW, _texH;
  /* Zero-copy path: an MTLTexture wrapping the engine's shared IOSurface.  We
     cache it keyed on the IOSurfaceRef identity (only a couple ever exist, one
     per resize), so we rewrap only when the engine swaps surfaces. */
  id<MTLTexture> _ioTex;
  IOSurfaceRef _ioSurface;
  bool _ready;
}

/* Resolve libSlateOffscreen.dylib: $SLATE_OFFSCREEN_DYLIB wins, else the engine
   Binaries location under $HOME (dlopen'd in place so @rpath deps resolve).  */
- (nonnull NSString *)libraryPath {
  const char *env = getenv("SLATE_OFFSCREEN_DYLIB");
  if (env && *env)
    return [NSString stringWithUTF8String:env];
  const char *home = getenv("HOME");
  return [NSString stringWithFormat:
                     @"%s/sourcecode/gameengine/UnrealEngine6/"
                      "Engine/Binaries/Mac/libSlateOffscreen.dylib",
                   home ? home : ""];
}

- (BOOL)loadLibrary {
  NSString *path = [self libraryPath];
  _dl = dlopen(path.UTF8String, RTLD_NOW | RTLD_LOCAL);
  if (!_dl) {
    NSLog(@"SlateDelegate: dlopen(%@) failed: %s", path, dlerror());
    return NO;
  }
  _init     = (pfn_Init)         dlsym(_dl, "SlateOffscreen_Init");
  _resize   = (pfn_Resize)       dlsym(_dl, "SlateOffscreen_Resize");
  _setScale = (pfn_SetScale)     dlsym(_dl, "SlateOffscreen_SetScale");
  _tick     = (pfn_Tick)         dlsym(_dl, "SlateOffscreen_Tick");
  _lock     = (pfn_LockPixels)   dlsym(_dl, "SlateOffscreen_LockPixels");
  _unlock   = (pfn_UnlockPixels) dlsym(_dl, "SlateOffscreen_UnlockPixels");
  _shutdown = (pfn_Shutdown)     dlsym(_dl, "SlateOffscreen_Shutdown");
  _getIOSurface = (pfn_GetIOSurface) dlsym(_dl, "SlateOffscreen_GetIOSurface");
  _mouseMove   = (pfn_MouseMove)   dlsym(_dl, "SlateOffscreen_MouseMove");
  _mouseButton = (pfn_MouseButton) dlsym(_dl, "SlateOffscreen_MouseButton");
  _mouseWheel  = (pfn_MouseWheel)  dlsym(_dl, "SlateOffscreen_MouseWheel");
  _key         = (pfn_Key)         dlsym(_dl, "SlateOffscreen_Key");
  _char        = (pfn_Char)        dlsym(_dl, "SlateOffscreen_Char");
  GSlateShutdownFn = _shutdown; /* for +shutdownEngineAndExit */
  if (!_init || !_tick || !_lock || !_unlock) {
    NSLog(@"SlateDelegate: missing SlateOffscreen_* symbols");
    return NO;
  }
  return YES;
}

/* Called from a kill-emacs-hook (during Fkill_emacs, before the C exit()).
   Stop the embedded engine's game thread, then hard-exit so neither UE's nor
   libc++'s static destructors run on the host thread (they crash for an
   embedded engine: IsInGameThread ensure, cross-allocator frees, etc.). */
+ (void)shutdownEngineAndExit {
  if (!GSlateShutdownFn) {
    /* No slate xwidget was ever created -> nothing embedded, let Emacs exit
       normally. */
    return;
  }
  /* Do NOT call SlateOffscreen_Shutdown here: joining the game thread runs
     GEngineLoop.Exit(), which needs UE's Cocoa GameRunLoopSource (our game
     thread is a std::thread, not FCocoaGameThread, so it asserts).  The
     process is terminating anyway, so just hard-exit immediately, bypassing
     ALL of UE's + libc++'s static-destructor teardown (the actual crash
     source at host exit).  The OS reclaims the game thread + GPU resources. */
  fflush(nullptr);
  _exit(0);
}

- (nonnull instancetype)initWithSlateView:(nonnull MTKView *)mtkView {
  self = [super init];
  if (self) {
    _view = mtkView;
    _view.framebufferOnly = NO; /* we blit into the drawable ourselves */
    _view.colorPixelFormat = MTLPixelFormatBGRA8Unorm;
    _queue = [mtkView.device newCommandQueue];
    _ready = false;

    if ([self loadLibrary]) {
      const int w = MAX(1, (int)mtkView.drawableSize.width);
      const int h = MAX(1, (int)mtkView.drawableSize.height);
      /* Tell the engine our backing scale (drawable pixels / logical points) so
         the widget tree lays out in logical units and fills the window rather
         than a 1/scale corner.  Set before _init so the first frame is correct. */
      if (_setScale)
        _setScale((float)[self currentBackingScale]);
      /* Boots the embedded engine on its own game thread; blocks until ready. */
      if (_init(w, h, NULL) == 0)
        _ready = true;
      else
        NSLog(@"SlateDelegate: SlateOffscreen_Init failed");

      /* Clean host exit is handled by Emacs's `kill-emacs-hook' ->
         `xwidget-slate-shutdown' -> +shutdownEngineAndExit, which hard-exits
         with _exit(0) BEFORE any UE/libc++ static-destructor teardown runs.
         We deliberately do NOT install an NSApplicationWillTerminate observer
         that joins the game thread: joining runs GEngineLoop.Exit(), which
         needs UE's Cocoa GameRunLoopSource that our std::thread game thread
         never registered, and asserts. */
    }
  }
  return self;
}

- (void)ensureTexture:(int)w height:(int)h {
  if (_tex && _texW == w && _texH == h)
    return;
  MTLTextureDescriptor *d = [MTLTextureDescriptor
      texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                   width:w
                                  height:h
                               mipmapped:NO];
  d.usage = MTLTextureUsageShaderRead;
  _tex = [_view.device newTextureWithDescriptor:d];
  _texW = w;
  _texH = h;
}

/* Backing scale: drawable pixels per logical point (2.0 on Retina).  Use the
   window's/screen's backingScaleFactor -- it is stable and authoritative.  Do
   NOT derive it from drawableSize/bounds: during a fullscreen or zoom
   transition those two update at different moments, so the ratio can be wildly
   wrong (e.g. 0.59) for a frame, which inverts the layout scale. */
- (CGFloat)currentBackingScale {
  if (_view.window)
    return _view.window.backingScaleFactor;
  NSScreen *screen = _view.window.screen ?: NSScreen.mainScreen;
  if (screen)
    return screen.backingScaleFactor;
  return 1.0;
}

- (void)mtkView:(nonnull MTKView *)view drawableSizeWillChange:(CGSize)size {
  if (_ready && _setScale)
    _setScale((float)[self currentBackingScale]);
  if (_ready && _resize)
    _resize((int)size.width, (int)size.height);
}

/* Zero-copy source: wrap the engine's shared IOSurface as an MTLTexture on OUR
   device (same physical GPU, so the IOSurface memory is shared).  Returns nil
   if no surface is ready yet.  Caches the wrapper keyed on IOSurfaceRef
   identity so we only rewrap when the engine swaps surfaces (e.g. on resize).
   Sets outW/outH to the surface dimensions. */
- (id<MTLTexture>)ioSurfaceTexture:(int *)outW height:(int *)outH {
  if (!_getIOSurface)
    return nil;
  int w = 0, h = 0;
  IOSurfaceRef surf = (IOSurfaceRef)_getIOSurface(&w, &h);
  if (!surf || w <= 0 || h <= 0)
    return nil;

  if (_ioTex && _ioSurface == surf && (int)_ioTex.width == w && (int)_ioTex.height == h) {
    *outW = w; *outH = h;
    return _ioTex; /* cache hit */
  }

  MTLTextureDescriptor *d = [MTLTextureDescriptor
      texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                   width:w
                                  height:h
                               mipmapped:NO];
  d.usage = MTLTextureUsageShaderRead;
  d.storageMode = MTLStorageModeShared; /* required to match IOSurface backing */
  id<MTLTexture> t = [_view.device newTextureWithDescriptor:d iosurface:surf plane:0];
  if (!t)
    return nil;
  _ioTex = t;
  _ioSurface = surf;
  *outW = w; *outH = h;
  return _ioTex;
}

/* Fallback source: CPU-readback frame from LockPixels, uploaded into _tex.
   Used until the IOSurface is ready / on non-Metal RHIs.  Returns nil if no
   frame is available.  Sets outW/outH. */
- (id<MTLTexture>)lockPixelsTexture:(int *)outW height:(int *)outH {
  int w = 0, h = 0, stride = 0;
  const void *px = _lock(&w, &h, &stride);
  if (!px)
    return nil;
  [self ensureTexture:w height:h];
  [_tex replaceRegion:MTLRegionMake2D(0, 0, w, h)
          mipmapLevel:0
            withBytes:px
          bytesPerRow:stride];
  _unlock();
  *outW = w; *outH = h;
  return _tex;
}

- (void)drawInMTKView:(nonnull MTKView *)view {
  if (!_ready)
    return;

  _tick(1.0f / 60.0f);

  /* Prefer the zero-copy IOSurface path (engine GPU-copies the Slate render
     target into a surface we wrap directly); fall back to the CPU-readback
     LockPixels path until that surface is live. */
  int w = 0, h = 0;
  id<MTLTexture> src = [self ioSurfaceTexture:&w height:&h];
  if (!src)
    src = [self lockPixelsTexture:&w height:&h];
  if (!src)
    return;

  id<CAMetalDrawable> drawable = view.currentDrawable;
  if (!drawable)
    return;

  const int dw = (int)drawable.texture.width;
  const int dh = (int)drawable.texture.height;

  id<MTLCommandBuffer> cb = [_queue commandBuffer];
  /* Blit the engine frame into the drawable.  The engine render target tracks
     the drawable size (we forward drawableSizeWillChange: -> SlateOffscreen_Resize),
     but during a resize they can disagree for a frame or two.  Rather than skip
     the whole blit on any mismatch (which freezes the view at the old contents),
     copy the overlapping region so the view always reflects the latest frame. */
  const int cw = MIN(w, dw);
  const int ch = MIN(h, dh);
  if (cw > 0 && ch > 0) {
    id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
    [blit copyFromTexture:src
              sourceSlice:0
              sourceLevel:0
             sourceOrigin:MTLOriginMake(0, 0, 0)
               sourceSize:MTLSizeMake(cw, ch, 1)
                toTexture:drawable.texture
         destinationSlice:0
         destinationLevel:0
        destinationOrigin:MTLOriginMake(0, 0, 0)];
    [blit endEncoding];
  }
  [cb presentDrawable:drawable];
  [cb commit];
}

/* Convert a point in the MTKView's coordinate space (points, bottom-left
   origin) to the offscreen render target's pixel space (top-left origin, which
   is what Slate hit-tests in).  The render target matches drawableSize. */
- (NSPoint)renderPixelFromViewPoint:(NSPoint)p {
  const CGSize ds = _view.drawableSize;
  const NSRect b = _view.bounds;
  const CGFloat sx = (b.size.width  > 0) ? (ds.width  / b.size.width)  : 1.0;
  const CGFloat sy = (b.size.height > 0) ? (ds.height / b.size.height) : 1.0;
  NSPoint out;
  out.x = p.x * sx;
  out.y = (b.size.height - p.y) * sy; /* flip Y to top-left origin */
  return out;
}

- (void)forwardMouseMoveTo:(NSPoint)viewPoint {
  if (!_ready || !_mouseMove)
    return;
  NSPoint px = [self renderPixelFromViewPoint:viewPoint];
  _mouseMove((float)px.x, (float)px.y);
}

- (void)forwardMouseButton:(int)button down:(BOOL)down at:(NSPoint)viewPoint {
  if (!_ready)
    return;
  /* Move the virtual cursor to the click point first so the hit-test path is
     correct, then deliver the button. */
  if (_mouseMove) {
    NSPoint px = [self renderPixelFromViewPoint:viewPoint];
    _mouseMove((float)px.x, (float)px.y);
  }
  if (_mouseButton)
    _mouseButton(button, down ? true : false);
}

- (void)forwardScroll:(CGFloat)deltaY {
  if (!_ready || !_mouseWheel)
    return;
  _mouseWheel((float)deltaY);
}

- (void)forwardKey:(int)keyCode down:(BOOL)down
             shift:(BOOL)shift ctrl:(BOOL)ctrl alt:(BOOL)alt cmd:(BOOL)cmd {
  if (!_ready || !_key)
    return;
  _key(keyCode, down ? true : false,
       shift ? true : false, ctrl ? true : false,
       alt ? true : false, cmd ? true : false);
}

- (void)forwardChar:(unichar)codepoint {
  if (!_ready || !_char)
    return;
  _char((uint32_t)codepoint);
}

- (void)dealloc {
  /* The embedded Unreal engine is a per-process singleton that keeps running on
     its own game thread after a slate buffer is killed (SlateOffscreen_Shutdown
     is intentionally a no-op -- the engine can't be torn down mid-session).  So
     do NOT dlclose the library here: it stays mapped for the life of the
     process (a re-opened slate xwidget reuses the live engine), and unloading it
     out from under the running game thread would crash.  Process teardown is
     handled by the kill-emacs-hook -> +shutdownEngineAndExit -> _exit(0). */
  [super dealloc];
}

@end

#endif /* HAVE_SLATE */
