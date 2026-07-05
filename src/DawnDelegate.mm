#include <config.h>

#ifdef HAVE_DAWN

#import <AppKit/AppKit.h>
#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>
#import <QuartzCore/CAMetalLayer.h>

#import "DawnDelegate.h"

#include <webgpu/webgpu.h>

#include <cstdio>
#include <cstring>

/* Inline WGSL: a hardcoded RGB triangle (vertex positions + colors in
   the shader, no vertex buffers).  */
static const char *kShaderWGSL = R"WGSL(
struct VSOut {
    @builtin(position) pos : vec4f,
    @location(0) color : vec3f,
};

@vertex
fn vs_main(@builtin(vertex_index) i : u32) -> VSOut {
    var p = array<vec2f, 3>(
        vec2f( 0.0,  0.5),
        vec2f( 0.5, -0.5),
        vec2f(-0.5, -0.5));
    var c = array<vec3f, 3>(
        vec3f(1.0, 0.0, 0.0),
        vec3f(0.0, 1.0, 0.0),
        vec3f(0.0, 0.0, 1.0));
    var o : VSOut;
    o.pos = vec4f(p[i], 0.0, 1.0);
    o.color = c[i];
    return o;
}

@fragment
fn fs_main(in : VSOut) -> @location(0) vec4f {
    return vec4f(in.color, 1.0);
}
)WGSL";

static WGPUStringView sv(const char *s) {
  WGPUStringView v;
  v.data = s;
  v.length = s ? strlen(s) : 0;
  return v;
}

@implementation DawnDelegate {
  MTKView *_view;
  CAMetalLayer *_metalLayer;

  WGPUInstance _instance;
  WGPUAdapter _adapter;
  WGPUDevice _device;
  WGPUQueue _queue;
  WGPUSurface _surface;
  WGPURenderPipeline _pipeline;
  WGPUTextureFormat _format;
  uint32_t _width;
  uint32_t _height;
  bool _ready;
}

- (nonnull instancetype)initWithDawnView:(nonnull MTKView *)mtkView {
  self = [super init];
  if (self) {
    _view = mtkView;
    _ready = false;
    _width = mtkView.bounds.size.width > 0 ? mtkView.bounds.size.width : 800;
    _height = mtkView.bounds.size.height > 0 ? mtkView.bounds.size.height : 600;

    _view.wantsLayer = YES;
    _metalLayer = [CAMetalLayer layer];
    _metalLayer.device = mtkView.device ?: MTLCreateSystemDefaultDevice();
    _metalLayer.pixelFormat = MTLPixelFormatBGRA8Unorm;
    _metalLayer.framebufferOnly = YES;
    _metalLayer.frame = _view.bounds;
    [_view.layer addSublayer:_metalLayer];

    [self initDawn];
  }
  return self;
}

- (void)initDawn {
  _instance = wgpuCreateInstance(nullptr);
  if (!_instance) {
    fprintf(stderr, "dawn: wgpuCreateInstance failed\n");
    return;
  }

  /* Create the surface from the CAMetalLayer.  */
  WGPUSurfaceSourceMetalLayer metalDesc = {};
  metalDesc.chain.sType = WGPUSType_SurfaceSourceMetalLayer;
  metalDesc.layer = (__bridge void *)_metalLayer;
  WGPUSurfaceDescriptor surfDesc = {};
  surfDesc.nextInChain = &metalDesc.chain;
  _surface = wgpuInstanceCreateSurface(_instance, &surfDesc);

  /* Request adapter (synchronously, by processing events until the
     spontaneous callback fires).  */
  WGPURequestAdapterOptions adapterOpts = {};
  adapterOpts.compatibleSurface = _surface;

  struct AdapterResult {
    WGPUAdapter adapter = nullptr;
    bool done = false;
  } adapterRes;

  WGPURequestAdapterCallbackInfo aci = {};
  aci.mode = WGPUCallbackMode_AllowSpontaneous;
  aci.callback = [](WGPURequestAdapterStatus status, WGPUAdapter adapter,
                    WGPUStringView message, void *ud1, void *) {
    auto *r = static_cast<AdapterResult *>(ud1);
    if (status == WGPURequestAdapterStatus_Success)
      r->adapter = adapter;
    else
      fprintf(stderr, "dawn: RequestAdapter failed: %.*s\n",
              (int)message.length, message.data ? message.data : "");
    r->done = true;
  };
  aci.userdata1 = &adapterRes;
  wgpuInstanceRequestAdapter(_instance, &adapterOpts, aci);
  while (!adapterRes.done)
    wgpuInstanceProcessEvents(_instance);
  _adapter = adapterRes.adapter;
  if (!_adapter) {
    fprintf(stderr, "dawn: no adapter\n");
    return;
  }

  /* Request device.  */
  struct DeviceResult {
    WGPUDevice device = nullptr;
    bool done = false;
  } deviceRes;

  WGPUDeviceDescriptor devDesc = {};
  WGPURequestDeviceCallbackInfo dci = {};
  dci.mode = WGPUCallbackMode_AllowSpontaneous;
  dci.callback = [](WGPURequestDeviceStatus status, WGPUDevice device,
                    WGPUStringView message, void *ud1, void *) {
    auto *r = static_cast<DeviceResult *>(ud1);
    if (status == WGPURequestDeviceStatus_Success)
      r->device = device;
    else
      fprintf(stderr, "dawn: RequestDevice failed: %.*s\n",
              (int)message.length, message.data ? message.data : "");
    r->done = true;
  };
  dci.userdata1 = &deviceRes;
  wgpuAdapterRequestDevice(_adapter, &devDesc, dci);
  while (!deviceRes.done)
    wgpuInstanceProcessEvents(_instance);
  _device = deviceRes.device;
  if (!_device) {
    fprintf(stderr, "dawn: no device\n");
    return;
  }
  _queue = wgpuDeviceGetQueue(_device);

  /* Pick a surface format.  */
  WGPUSurfaceCapabilities caps = {};
  wgpuSurfaceGetCapabilities(_surface, _adapter, &caps);
  _format = (caps.formatCount > 0) ? caps.formats[0]
                                   : WGPUTextureFormat_BGRA8Unorm;
  wgpuSurfaceCapabilitiesFreeMembers(caps);

  [self configureSurface];
  [self createPipeline];

  _ready = true;
}

- (void)configureSurface {
  WGPUSurfaceConfiguration config = {};
  config.device = _device;
  config.format = _format;
  config.usage = WGPUTextureUsage_RenderAttachment;
  config.width = _width;
  config.height = _height;
  config.presentMode = WGPUPresentMode_Fifo;
  config.alphaMode = WGPUCompositeAlphaMode_Auto;
  wgpuSurfaceConfigure(_surface, &config);
}

- (void)createPipeline {
  WGPUShaderSourceWGSL wgsl = {};
  wgsl.chain.sType = WGPUSType_ShaderSourceWGSL;
  wgsl.code = sv(kShaderWGSL);
  WGPUShaderModuleDescriptor smDesc = {};
  smDesc.nextInChain = &wgsl.chain;
  WGPUShaderModule module = wgpuDeviceCreateShaderModule(_device, &smDesc);

  WGPUColorTargetState colorTarget = {};
  colorTarget.format = _format;
  colorTarget.writeMask = WGPUColorWriteMask_All;

  WGPUFragmentState frag = {};
  frag.module = module;
  frag.entryPoint = sv("fs_main");
  frag.targetCount = 1;
  frag.targets = &colorTarget;

  WGPURenderPipelineDescriptor pipeDesc = {};
  pipeDesc.vertex.module = module;
  pipeDesc.vertex.entryPoint = sv("vs_main");
  pipeDesc.primitive.topology = WGPUPrimitiveTopology_TriangleList;
  pipeDesc.multisample.count = 1;
  pipeDesc.multisample.mask = 0xFFFFFFFF;
  pipeDesc.fragment = &frag;
  _pipeline = wgpuDeviceCreateRenderPipeline(_device, &pipeDesc);

  wgpuShaderModuleRelease(module);
}

- (void)mtkView:(nonnull MTKView *)view drawableSizeWillChange:(CGSize)size {
  if (!_ready)
    return;
  _width = size.width;
  _height = size.height;
  _metalLayer.frame = _view.bounds;
  _metalLayer.drawableSize = size;
  [self configureSurface];
}

- (void)drawInMTKView:(nonnull MTKView *)view {
  if (!_ready)
    return;

  WGPUSurfaceTexture surfaceTex = {};
  wgpuSurfaceGetCurrentTexture(_surface, &surfaceTex);
  if (!surfaceTex.texture)
    return;

  WGPUTextureView backbuffer = wgpuTextureCreateView(surfaceTex.texture, nullptr);

  WGPUCommandEncoder encoder =
      wgpuDeviceCreateCommandEncoder(_device, nullptr);

  WGPURenderPassColorAttachment colorAtt = {};
  colorAtt.view = backbuffer;
  colorAtt.loadOp = WGPULoadOp_Clear;
  colorAtt.storeOp = WGPUStoreOp_Store;
  colorAtt.clearValue = {0.1, 0.125, 0.2, 1.0};
  colorAtt.depthSlice = WGPU_DEPTH_SLICE_UNDEFINED;

  WGPURenderPassDescriptor passDesc = {};
  passDesc.colorAttachmentCount = 1;
  passDesc.colorAttachments = &colorAtt;

  WGPURenderPassEncoder pass =
      wgpuCommandEncoderBeginRenderPass(encoder, &passDesc);
  wgpuRenderPassEncoderSetPipeline(pass, _pipeline);
  wgpuRenderPassEncoderDraw(pass, 3, 1, 0, 0);
  wgpuRenderPassEncoderEnd(pass);
  wgpuRenderPassEncoderRelease(pass);

  WGPUCommandBuffer cmd = wgpuCommandEncoderFinish(encoder, nullptr);
  wgpuQueueSubmit(_queue, 1, &cmd);

  wgpuSurfacePresent(_surface);

  wgpuCommandBufferRelease(cmd);
  wgpuCommandEncoderRelease(encoder);
  wgpuTextureViewRelease(backbuffer);
  wgpuTextureRelease(surfaceTex.texture);

  wgpuInstanceProcessEvents(_instance);
}

- (void)dealloc {
  if (_pipeline) wgpuRenderPipelineRelease(_pipeline);
  if (_surface) wgpuSurfaceRelease(_surface);
  if (_queue) wgpuQueueRelease(_queue);
  if (_device) wgpuDeviceRelease(_device);
  if (_adapter) wgpuAdapterRelease(_adapter);
  if (_instance) wgpuInstanceRelease(_instance);
  [super dealloc];
}

@end

#endif /* HAVE_DAWN */
