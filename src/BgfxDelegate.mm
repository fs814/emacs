#include <config.h>

#ifdef HAVE_BGFX

#import <AppKit/AppKit.h>
#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>
#import <QuartzCore/CAMetalLayer.h>

#import "BgfxDelegate.h"

#include <bgfx/bgfx.h>

#include "vs_triangle.bin.h"
#include "fs_triangle.bin.h"

struct PosColorVertex {
  float x, y, z;
  uint32_t abgr;

  static void init() {
    ms_layout.begin()
        .add(bgfx::Attrib::Position, 3, bgfx::AttribType::Float)
        .add(bgfx::Attrib::Color0, 4, bgfx::AttribType::Uint8, true)
        .end();
  }
  static bgfx::VertexLayout ms_layout;
};
bgfx::VertexLayout PosColorVertex::ms_layout;

/* A single RGB triangle in clip space (z = 0).  */
static const PosColorVertex kTriangle[] = {
    {0.0f, 0.5f, 0.0f, 0xff0000ff},   /* top    - red   (abgr) */
    {0.5f, -0.5f, 0.0f, 0xff00ff00},  /* right  - green */
    {-0.5f, -0.5f, 0.0f, 0xffff0000}, /* left   - blue  */
};
static const uint16_t kTriIndices[] = {0, 1, 2};

@implementation BgfxDelegate {
  MTKView *_view;
  CAMetalLayer *_metalLayer;
  bgfx::VertexBufferHandle _vbh;
  bgfx::IndexBufferHandle _ibh;
  bgfx::ProgramHandle _program;
  uint32_t _width;
  uint32_t _height;
  bool _initialized;
}

- (nonnull instancetype)initWithBgfxView:(nonnull MTKView *)mtkView {
  self = [super init];
  if (self) {
    _view = mtkView;
    _initialized = false;
    _width = mtkView.bounds.size.width > 0 ? mtkView.bounds.size.width : 800;
    _height = mtkView.bounds.size.height > 0 ? mtkView.bounds.size.height : 600;

    /* bgfx's Metal renderer draws into a CAMetalLayer passed as the
       native window handle.  */
    _view.wantsLayer = YES;
    _metalLayer = [CAMetalLayer layer];
    _metalLayer.device = mtkView.device ?: MTLCreateSystemDefaultDevice();
    _metalLayer.pixelFormat = MTLPixelFormatBGRA8Unorm;
    _metalLayer.framebufferOnly = YES;
    _metalLayer.frame = _view.bounds;
    [_view.layer addSublayer:_metalLayer];

    [self initBgfx];
  }
  return self;
}

- (void)initBgfx {
  bgfx::Init init;
  init.type = bgfx::RendererType::Metal;
  init.resolution.width = _width;
  init.resolution.height = _height;
  init.resolution.reset = BGFX_RESET_VSYNC;
  init.platformData.nwh = (__bridge void *)_metalLayer;

  if (!bgfx::init(init)) {
    NSLog(@"bgfx: init failed");
    return;
  }

  bgfx::setViewClear(0, BGFX_CLEAR_COLOR | BGFX_CLEAR_DEPTH, 0x1a2033ff, 1.0f,
                     0);
  bgfx::setViewRect(0, 0, 0, uint16_t(_width), uint16_t(_height));

  PosColorVertex::init();
  _vbh = bgfx::createVertexBuffer(
      bgfx::makeRef(kTriangle, sizeof(kTriangle)), PosColorVertex::ms_layout);
  _ibh = bgfx::createIndexBuffer(bgfx::makeRef(kTriIndices, sizeof(kTriIndices)));

  bgfx::RendererType::Enum rtype = bgfx::getRendererType();
  (void)rtype;
  /* The shaders are compiled for the Metal backend (see the shaderc
     invocation that produced vs_triangle.bin.h / fs_triangle.bin.h).  */
  bgfx::ShaderHandle vsh =
      bgfx::createShader(bgfx::makeRef(vs_triangle, sizeof(vs_triangle)));
  bgfx::ShaderHandle fsh =
      bgfx::createShader(bgfx::makeRef(fs_triangle, sizeof(fs_triangle)));
  _program = bgfx::createProgram(vsh, fsh, true);

  _initialized = true;
}

- (void)mtkView:(nonnull MTKView *)view drawableSizeWillChange:(CGSize)size {
  if (!_initialized)
    return;
  _width = size.width;
  _height = size.height;
  _metalLayer.frame = _view.bounds;
  _metalLayer.drawableSize = size;
  bgfx::reset(_width, _height, BGFX_RESET_VSYNC);
  bgfx::setViewRect(0, 0, 0, uint16_t(_width), uint16_t(_height));
}

- (void)drawInMTKView:(nonnull MTKView *)view {
  if (!_initialized)
    return;

  bgfx::setViewRect(0, 0, 0, uint16_t(_width), uint16_t(_height));
  bgfx::touch(0);

  bgfx::setVertexBuffer(0, _vbh);
  bgfx::setIndexBuffer(_ibh);
  bgfx::setState(BGFX_STATE_WRITE_RGB | BGFX_STATE_WRITE_A);
  bgfx::submit(0, _program);

  bgfx::frame();
}

- (void)dealloc {
  if (_initialized) {
    bgfx::destroy(_vbh);
    bgfx::destroy(_ibh);
    bgfx::destroy(_program);
    bgfx::shutdown();
  }
  [super dealloc];
}

@end

#endif /* HAVE_BGFX */
