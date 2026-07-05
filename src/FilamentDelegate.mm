#include <config.h>

#ifdef HAVE_FILAMENT

#import <AppKit/AppKit.h>

#import "FilamentDelegate.h"

#include <filament/Camera.h>
#include <filament/Engine.h>
#include <filament/IndexBuffer.h>
#include <filament/Material.h>
#include <filament/RenderableManager.h>
#include <filament/Renderer.h>
#include <filament/Scene.h>
#include <filament/TransformManager.h>
#include <filament/VertexBuffer.h>
#include <filament/View.h>
#include <filament/Viewport.h>

#include <Metal/Metal.h>
#include <MetalKit/MetalKit.h>

#include <math/vec2.h>
#include <math/mat4.h>
#include <utils/EntityManager.h>

#define FILAMENT_APP_USE_METAL 1

using namespace filament;
using utils::Entity;
using utils::EntityManager;

struct App {
  VertexBuffer *vb;
  IndexBuffer *ib;
  Material *mat;
  Entity renderable;
};

struct Vertex {
  filament::math::float2 position;
  uint32_t color;
};

static const Vertex TRIANGLE_VERTICES[3] = {
    {{1, 0}, 0xffff0000u},
    {{cos(M_PI * 2 / 3), sin(M_PI * 2 / 3)}, 0xff00ff00u},
    {{cos(M_PI * 4 / 3), sin(M_PI * 4 / 3)}, 0xff0000ffu},
};

static constexpr uint16_t TRIANGLE_INDICES[3] = {0, 1, 2};

/* Baked-color unlit material, compiled from bakedColor.mat via matc.  */
static constexpr uint8_t BAKED_COLOR_PACKAGE[] = {
#include "bakedColor.inc"
};

@implementation FilamentDelegate {
  id<MTLDevice> _device;

  Engine *engine;
  Renderer *renderer;
  Scene *scene;
  View *filaView;
  Camera *camera;
  SwapChain *swapChain;
  App app;

  NSSize _viewportSize;
  MTKView *_view;
}

- (nonnull instancetype)initWithFilamentView:(nonnull MTKView *)mtkView {
  self = [super init];

  _device = mtkView.device;
  _view = mtkView;
#if FILAMENT_APP_USE_METAL
  /* Filament's Metal backend renders into the view's CAMetalLayer, so
     the MTKView must be layer-backed.  */
  _view.wantsLayer = YES;
#endif

  [self initializeFilament];

  return self;
}

- (void)dealloc {
  engine->destroy(app.renderable);
  engine->destroy(app.mat);
  engine->destroy(app.vb);
  engine->destroy(app.ib);
  engine->destroy(renderer);
  engine->destroy(scene);
  engine->destroy(filaView);
  Entity c = camera->getEntity();
  engine->destroyCameraComponent(c);
  EntityManager::get().destroy(c);
  engine->destroy(swapChain);
  Engine::destroy(&engine);
  [super dealloc];
}

- (void)mtkView:(nonnull MTKView *)view drawableSizeWillChange:(CGSize)size {
  NSSize curSize = size;
  if (!NSEqualSizes(curSize, _viewportSize)) {
    _viewportSize = curSize;
    filaView->setViewport(Viewport(0, 0, curSize.width, curSize.height));
  }

  constexpr float ZOOM = 1.5f;
  const uint32_t w = filaView->getViewport().width;
  const uint32_t h = filaView->getViewport().height;
  const float aspect = h ? (float)w / h : 1.0f;
  camera->setProjection(Camera::Projection::ORTHO, -aspect * ZOOM,
                        aspect * ZOOM, -ZOOM, ZOOM, 0, 1);
}

- (void)drawInMTKView:(nonnull MTKView *)view {
  if (!UTILS_HAS_THREADING)
    engine->execute();

  /* Spin the triangle so it is visibly alive.  */
  auto &tcm = engine->getTransformManager();
  tcm.setTransform(tcm.getInstance(app.renderable),
                   filament::math::mat4f::rotation(
                       CACurrentMediaTime(),
                       filament::math::float3{0, 0, 1}));

  if (renderer->beginFrame(swapChain)) {
    renderer->render(filaView);
    renderer->endFrame();
  }
}

- (void)initializeFilament {
  NSLog(@"initializeFilament (Metal backend)");
  engine = Engine::create(filament::Engine::Backend::METAL);
  swapChain = engine->createSwapChain((__bridge void *)_view.layer);
  renderer = engine->createRenderer();
  scene = engine->createScene();
  Entity c = EntityManager::get().create();
  camera = engine->createCamera(c);
  renderer->setClearOptions(
      {.clearColor = {0.1, 0.125, 0.25, 1.0}, .clear = true});

  filaView = engine->createView();

  app.vb = VertexBuffer::Builder()
               .vertexCount(3)
               .bufferCount(1)
               .attribute(VertexAttribute::POSITION, 0,
                          VertexBuffer::AttributeType::FLOAT2, 0, 12)
               .attribute(VertexAttribute::COLOR, 0,
                          VertexBuffer::AttributeType::UBYTE4, 8, 12)
               .normalized(VertexAttribute::COLOR)
               .build(*engine);
  app.vb->setBufferAt(
      *engine, 0,
      VertexBuffer::BufferDescriptor(TRIANGLE_VERTICES, 36, nullptr));

  app.ib = IndexBuffer::Builder()
               .indexCount(3)
               .bufferType(IndexBuffer::IndexType::USHORT)
               .build(*engine);
  app.ib->setBuffer(
      *engine, IndexBuffer::BufferDescriptor(TRIANGLE_INDICES, 6, nullptr));

  app.mat =
      Material::Builder()
          .package((void *)BAKED_COLOR_PACKAGE, sizeof(BAKED_COLOR_PACKAGE))
          .build(*engine);

  app.renderable = EntityManager::get().create();
  RenderableManager::Builder(1)
      .boundingBox({{-1, -1, -1}, {1, 1, 1}})
      .material(0, app.mat->getDefaultInstance())
      .geometry(0, RenderableManager::PrimitiveType::TRIANGLES, app.vb, app.ib,
                0, 3)
      .culling(false)
      .receiveShadows(false)
      .castShadows(false)
      .build(*engine, app.renderable);
  scene->addEntity(app.renderable);

  filaView->setScene(scene);
  filaView->setCamera(camera);
}
@end

#endif /* HAVE_FILAMENT */
