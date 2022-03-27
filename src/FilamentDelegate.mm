#include <config.h>

#import <AppKit/AppKit.h>

#import "FilamentDelegate.h"

#include "FilamentRender.h"

#include <filament/Camera.h>
#include <filament/Engine.h>
#include <filament/IndexBuffer.h>
#include <filament/Material.h>
#include <filament/RenderableManager.h>
#include <filament/Renderer.h>
#include <filament/Scene.h>
#include <filament/Texture.h>
#include <filament/TransformManager.h>
#include <filament/VertexBuffer.h>
#include <filament/View.h>
#include <filament/Viewport.h>
#include <filament/textureSampler.h>

#include <Metal/Metal.h>
#include <MetalKit/MetalKit.h>

#include <components/LightManager.h>
#include <components/RenderableManager.h>
#include <math/vec3.h>
#include <stb_image.h>
#include <utils/EntityManager.h>

//#define FILAMENT_APP_USE_METAL 1
#define FILAMENT_APP_USE_VULKAN 1
//#define FILAMENT_APP_USE_OPENGL 1

// These defines are set in the "Preprocessor Macros" build setting for each
// scheme.
#if !FILAMENT_APP_USE_METAL && !FILAMENT_APP_USE_OPENGL &&                     \
    !FILAMENT_APP_USE_VULKAN
#error A valid FILAMENT_APP_USE_ backend define must be set.
#endif

using namespace filament;
using utils::Entity;
using utils::EntityManager;

struct App {
  VertexBuffer *vb;
  VertexBuffer *vb1;
  IndexBuffer *ib;
  Material *mat;
  Entity renderable;
  Entity renderable1;
};

struct Vertex {
  filament::math::float2 position;
  uint32_t color;
};

struct Vertex1 {
  filament::math::float2 position;
  uint32_t color;
  filament::math::float2 coord;
};

static const Vertex TRIANGLE_VERTICES[3] = {
    {{1, 0}, 0xffff0000u},
    {{cos(M_PI * 2 / 3), sin(M_PI * 2 / 3)}, 0xff00ff00u},
    {{cos(M_PI * 4 / 3), sin(M_PI * 4 / 3)}, 0xff0000ffu},
};

static const Vertex1 TRIANGLE_VERTICES1[3] = {
    {{1, 0}, 0xffff0000u, {0, 0}},
    {{cos(M_PI * 2 / 3), sin(M_PI * 2 / 3)}, 0xff00ff00u, {0, 1}},
    {{cos(M_PI * 4 / 3), sin(M_PI * 4 / 3)}, 0xff0000ffu, {1, 1}},
};

static constexpr uint16_t TRIANGLE_INDICES[3] = {0, 1, 2};

// This file is compiled via the matc tool. See the "Run Script" build phase.
static constexpr uint8_t BAKED_COLOR_PACKAGE[] = {
#include "bakedColor.inc"
};

const int MAT_NUM = 6;

#include <sys/time.h>
#include <time.h>

uint64_t VeGetTimeOfDay() //获取当前时间，从1970.1.1.0.0.0开始计算，单位为毫秒
{
  struct timeval tTime;
  gettimeofday(&tTime, NULL);
  uint64_t temp = uint64_t(tTime.tv_sec);
  return uint64_t(temp * 1000 + tTime.tv_usec / 1000);
}

NSString *FilamentDelegateDidSizeChange = @"FilamentDelegateDidSizeChange";

@implementation FilamentDelegate {
  id<MTLDevice> _device;

  Engine *engine;
  Renderer *renderer;
  Scene *scene;
  View *filaView;
  Camera *camera;
  SwapChain *swapChain;
  App app;

  // The amount of rotation to apply to the camera to offset the device's
  // rotation (in radians)
  float deviceRotation;
  float desiredRotation;
  MaterialInstance *filament_matInstance[MAT_NUM];
  int mat_id;
  GLuint texture_id;
  filament::Texture *newTexture[2];
  int64_t startTime;

  NSSize _viewportSize;

  MTKView *_view;
}

- (void)mtkView:(nonnull MTKView *)view drawableSizeWillChange:(CGSize)size {
  NSLog(@"UpdateViewSize");

  NSSize curSize = size;
  if (!NSEqualSizes(curSize, _viewportSize)) {
    _viewportSize = curSize;
    filaView->setViewport(Viewport(0, 0, curSize.width, curSize.height));
    /*
    #if FILAMENT_APP_USE_METAL
        CAMetalLayer *myLayer = (CAMetalLayer *)self.layer;
        myLayer.drawableSize = NSSizeToCGSize(curSize);
    #endif
    */
    //[NSNotificationCenter.defaultCenter
    //    postNotificationName:FilamentViewDidSizeChange
    //                  object:self];
  }

  constexpr float ZOOM = 1.5f;
  const uint32_t w = filaView->getViewport().width;
  const uint32_t h = filaView->getViewport().height;
  const float aspect = (float)w / h;
  camera->setProjection(Camera::Projection::ORTHO, -aspect * ZOOM,
                        aspect * ZOOM, -ZOOM, ZOOM, 0, 1);
  auto &tcm = engine->getTransformManager();

  [self updateRotation];

  tcm.setTransform(tcm.getInstance(app.renderable),
                   filament::math::mat4f::rotation(
                       CACurrentMediaTime(), filament::math::float3{0, 0, 1}) *
                       filament::math::mat4f::rotation(
                           deviceRotation, filament::math::float3{0, 0, 1}));
}

- (nonnull instancetype)initWithFilamentView:(nonnull MTKView *)mtkView {
  self = [super init];

  _device = mtkView.device;
  _view = mtkView;
  //#if FILAMENT_APP_USE_OPENGL
  //  _view.wantsLayer = YES;
  //#elif FILAMENT_APP_USE_METAL
  //  _view.wantsLayer = YES;
  //#elif FILAMENT_APP_USE_VULKAN
  //  _view.wantsLayer = YES;
  //#endif

  [self initializeFilament];
  //[_view setNeedsDisplay:YES];

  return self;
}

- (void)createLight {
  // Always add a direct light source since it is required for shadowing.
  Entity sun = EntityManager::get().create();
  LightManager::Builder(LightManager::Type::DIRECTIONAL)
      .color(Color::cct(6500.0f))
      .intensity(50000.0f)
      .direction(filament::math::float3(0.0f, -1.0f, 0.0f))
      .castShadows(true)
      .build(*engine, sun);
  scene->addEntity(sun);
}

- (void)switchMaterial {
  mat_id = (mat_id + 1) % MAT_NUM;
  bool visible = true;
  Entity *curEntity = &app.renderable;

  if (mat_id >= 2) {
    visible = false;
    curEntity = &app.renderable1;
  }
  bool visible1 = !visible;

  [self setVisible:&app.renderable visible:visible];
  [self setVisible:&app.renderable1 visible:visible1];

  auto &rm = engine->getRenderableManager();
  auto renderable_instance = rm.getInstance(*curEntity);
  size_t primitive_count = rm.getPrimitiveCount(renderable_instance);
  if (primitive_count > 0) {
    for (int primitive_index = 0; primitive_index < primitive_count;
         primitive_index++) {
      //            auto material_instance = app.mat->createInstance();
      rm.setMaterialInstanceAt(renderable_instance, primitive_index,
                               filament_matInstance[mat_id]);
    }
  }
}

- (void)readMaterial:(NSString *)matName mat_id:(int)mat_id {
  // NSString *bundlePath = [[NSBundle mainBundle] resourcePath];
  // NSString *secondParentPath = [[bundlePath
  // stringByDeletingLastPathComponent]
  //    stringByDeletingLastPathComponent];
  // NSLog(@"%@", bundlePath);
  NSString *material_path =
      [[NSBundle mainBundle] pathForResource:matName
                                      ofType:@"filamat"
                                 inDirectory:@"custom_materials"];
  NSData *materialBuffer = [NSData dataWithContentsOfFile:material_path];

  Material *tempMat = filament::Material::Builder()
                          .package(materialBuffer.bytes, materialBuffer.length)
                          .build(*engine);
  filament_matInstance[mat_id] = tempMat->getDefaultInstance();
}

- (void)setTexParameterOfMat:(int)mat_id
                   paramName:(const char *)paramName
                     texture:(filament::Texture *)newTexture {
  filament::TextureSampler dstSampler;
  dstSampler.setWrapModeS(filament::TextureSampler::WrapMode::REPEAT);
  dstSampler.setWrapModeT(filament::TextureSampler::WrapMode::REPEAT);
  dstSampler.setMagFilter(filament::TextureSampler::MagFilter::LINEAR);
  dstSampler.setMinFilter(filament::TextureSampler::MinFilter::LINEAR);

  filament_matInstance[mat_id]->setParameter(paramName, newTexture, dstSampler);
}

- (filament::Texture *)readTextureFile:(NSString *)file_name
                                   ext:(NSString *)ext {
  NSString *img_path =
      [[NSBundle mainBundle] pathForResource:file_name
                                      ofType:ext
                                 inDirectory:@"custom_materials"];
  const char *cfilepath = [img_path UTF8String];
  int w, h, c;
  unsigned char *tempBuffer = stbi_load(cfilepath, &w, &h, &c, STBI_rgb_alpha);

  //方法1  直接生成filament texture（这个的纹理加载会延迟到command 执行）,
  //并设置进material instance的parameter
  filament::Texture::PixelBufferDescriptor buffer(
      tempBuffer, w * h * c * 4, filament::Texture::Format::RGBA,
      Texture::Type::UBYTE);

  filament::Texture *newTexture = filament::Texture::Builder()
                                      .width(w)
                                      .height(h)
                                      .format(backend::TextureFormat::SRGB8_A8)
                                      .build(*engine);

  newTexture->setImage(*engine, 0, std::move(buffer));
  //    mDependencyGraph.addEdge(newTexture, filament_matInstance[3], "albedo");

  //    [self performSelector:@selector(setParameterOfMat) withObject:nil
  //    afterDelay:2];

  //方法2 用opengl加载纹理（这个的纹理加载马上执行），利用该纹理id生成filament
  // texture然后设置进material instance的parameter
  //    [self generateTempOpenGLTexture:tempBuffer width:w height:h];
  //
  //    filament::Texture* newTexture =
  //        filament::Texture::Builder()
  //                   .width(w)
  //                   .height(h)
  //                   .levels(0xff)
  //// .format(filament::Texture::InternalFormat::RGBA8)
  //                   .format(filament::Texture::InternalFormat::SRGB8_A8)
  //                   .import(self->texture_id)
  //                   .build(*engine);
  //    filament_matInstance[3]->setParameter("albedo", newTexture, dstSampler);

  return newTexture;
}

- (void)setParametersForMat {
  filament_matInstance[2]->setParameter("baseColor",
                                        filament::math::float3(1.0, 1.0, 0.0));

  [self setTexParameterOfMat:3 paramName:"albedo" texture:self->newTexture[0]];

  [self setTexParameterOfMat:4 paramName:"albedo" texture:self->newTexture[0]];
  [self setTexParameterOfMat:4 paramName:"albedo1" texture:self->newTexture[1]];

  [self setTexParameterOfMat:5 paramName:"albedo" texture:self->newTexture[0]];
  [self setTexParameterOfMat:5 paramName:"albedo1" texture:self->newTexture[1]];
}

- (void)readMaterials {
  [self readMaterial:@"colorMat" mat_id:1];
  [self readMaterial:@"custom_mat" mat_id:2];
  [self readMaterial:@"custom_texture" mat_id:3];
  [self readMaterial:@"unlit_texture" mat_id:4];
  [self readMaterial:@"vertex_unlit_texture" mat_id:5];

  self->newTexture[0] = [self readTextureFile:@"trump" ext:@"jpeg"];
  self->newTexture[1] = [self readTextureFile:@"obama" ext:@"jpeg"];

  [self setParametersForMat];
}

- (void)setVisible:(Entity *)entity visible:(bool)visible {
  filament::RenderableManager &rcm = engine->getRenderableManager();
  filament::FRenderableManager *frcm =
      static_cast<filament::FRenderableManager *>(&rcm);
  if (visible)
    frcm->setLayerMask(rcm.getInstance(*entity), 0x01);
  else
    frcm->setLayerMask(rcm.getInstance(*entity), 0x02);
}

- (void)dealloc {
  engine->destroy(renderer);
  engine->destroy(scene);
  engine->destroy(filaView);
  Entity c = camera->getEntity();
  engine->destroyCameraComponent(c);
  EntityManager::get().destroy(c);
  engine->destroy(swapChain);
  engine->destroy(&engine);
}

- (void)updateVertexPos {
  //这是毫秒
  float curTime = VeGetTimeOfDay() - startTime;
  curTime = curTime * 0.01;
  if (curTime > 6.28)
    curTime = curTime - floor(curTime / 6.28) * 6.28;
  filament_matInstance[5]->setParameter("time",
                                        filament::math::float2(curTime, 0));
}

- (void)drawInMTKView:(nonnull MTKView *)view {
  //[self updateViewSize:rect];
  [self updateVertexPos];

  // NSLog(@"refreshOnMainThread");
  if (!UTILS_HAS_THREADING) {
    // while (glGetError() != GL_NO_ERROR);
    engine->execute();
  }

  if (self->renderer->beginFrame(self->swapChain)) {
    self->renderer->render(self->filaView);
    self->renderer->endFrame();
  }
}

- (void)updateRotation {
  static const float ROTATION_SPEED = 0.1;
  float diff = abs(desiredRotation - deviceRotation);
  if (diff > FLT_EPSILON) {
    if (desiredRotation > deviceRotation) {
      deviceRotation += fmin(ROTATION_SPEED, diff);
    }
    if (desiredRotation < deviceRotation) {
      deviceRotation -= fmin(ROTATION_SPEED, diff);
    }
  }
}

/*
+ (Class)layerClass {
#if FILAMENT_APP_USE_OPENGL
  return [CAOpenGLLayer class];
#elif FILAMENT_APP_USE_METAL
  return [CAMetalLayer class];
#endif
}*/

- (void)initializeFilament {
  NSLog(@"initializeFilament");
#if FILAMENT_APP_USE_OPENGL
  engine = Engine::create(filament::Engine::Backend::OPENGL);
#elif FILAMENT_APP_USE_METAL
  engine = Engine::create(filament::Engine::Backend::METAL);
#elif FILAMENT_APP_USE_VULKAN
  engine = Engine::create(filament::Engine::Backend::VULKAN);
#endif
  swapChain = engine->createSwapChain((__bridge void *)_view.layer);
  renderer = engine->createRenderer();
  scene = engine->createScene();
  Entity c = EntityManager::get().create();
  camera = engine->createCamera(c);
  renderer->setClearOptions(
      {.clearColor = {0.1, 0.125, 0.25, 1.0}, .clear = true});

  mat_id = 0;
  startTime = VeGetTimeOfDay();
  [self createLight];
  [self readMaterials];

  filaView = engine->createView();
  //    filaView->setPostProcessingEnabled(false);

  filament::BloomOptions bloomOptions;
  bloomOptions.levels = 10;
  bloomOptions.enabled = true;
  bloomOptions.highlight = 100;
  bloomOptions.strength = 1;
  //    bloomOptions.thresholdValue = 0.1;

  //    bloomOptions.blendMode = filament::BloomOptions::BlendMode::INTERPOLATE;
  filaView->setBlendMode(filament::View::BlendMode::TRANSLUCENT);
  filaView->setBloomOptions(bloomOptions);

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

  app.vb1 = VertexBuffer::Builder()
                .vertexCount(3)
                .bufferCount(1)
                .attribute(VertexAttribute::POSITION, 0,
                           VertexBuffer::AttributeType::FLOAT2, 0, 20)
                .attribute(VertexAttribute::COLOR, 0,
                           VertexBuffer::AttributeType::UBYTE4, 8, 20)
                .normalized(VertexAttribute::COLOR)
                .attribute(VertexAttribute::UV0, 0,
                           VertexBuffer::AttributeType::FLOAT2, 12, 20)
                .build(*engine);
  app.vb1->setBufferAt(
      *engine, 0,
      VertexBuffer::BufferDescriptor(TRIANGLE_VERTICES1, 60, nullptr));

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
  filament_matInstance[0] = app.mat->getDefaultInstance();

  app.renderable = EntityManager::get().create();
  RenderableManager::Builder(1)
      .boundingBox({{-1, -1, -1}, {1, 1, 1}})
      .material(0, filament_matInstance[0])
      .geometry(0, RenderableManager::PrimitiveType::TRIANGLES, app.vb, app.ib,
                0, 3)
      .culling(false)
      .receiveShadows(false)
      .castShadows(false)
      .build(*engine, app.renderable);
  scene->addEntity(app.renderable);

  app.renderable1 = EntityManager::get().create();
  RenderableManager::Builder(1)
      .boundingBox({{-1, -1, -1}, {1, 1, 1}})
      .material(0, filament_matInstance[2])
      .geometry(0, RenderableManager::PrimitiveType::TRIANGLES, app.vb1, app.ib,
                0, 3)
      .culling(false)
      .receiveShadows(false)
      .castShadows(false)
      .build(*engine, app.renderable1);
  scene->addEntity(app.renderable1);

  [self setVisible:&app.renderable visible:true];
  [self setVisible:&app.renderable1 visible:false];

  filaView->setScene(scene);
  filaView->setCamera(camera);
  // CGRect nativeBounds = [UIScreen mainScreen].nativeBounds;
  // filaView->setViewport(
  //    Viewport(0, 0, nativeBounds.size.width, nativeBounds.size.height));
}
@end
