#include <config.h>

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

#include <components/LightManager.h>
#include <components/RenderableManager.h>
#include <math/vec3.h>
#include <stb_image.h>
#include <utils/EntityManager.h>

#define FILAMENT_APP_USE_VULKAN 1

using namespace filament;
using utils::Entity;
using utils::EntityManager;

struct App
{
  VertexBuffer *vb;
  VertexBuffer *vb1;
  IndexBuffer *ib;
  Material *mat;
  Entity renderable;
  Entity renderable1;
};

struct Vertex
{
  filament::math::float2 position;
  uint32_t color;
};

struct Vertex1
{
  filament::math::float2 position;
  uint32_t color;
  filament::math::float2 coord;
};

static const Vertex TRIANGLE_VERTICES[3] = {
  { { 1, 0 }, 0xffff0000u },
  { { cos (M_PI * 2 / 3), sin (M_PI * 2 / 3) }, 0xff00ff00u },
  { { cos (M_PI * 4 / 3), sin (M_PI * 4 / 3) }, 0xff0000ffu },
};

static const Vertex1 TRIANGLE_VERTICES1[3] = {
  { { 1, 0 }, 0xffff0000u, { 0, 0 } },
  { { cos (M_PI * 2 / 3), sin (M_PI * 2 / 3) },
    0xff00ff00u,
    { 0, 1 } },
  { { cos (M_PI * 4 / 3), sin (M_PI * 4 / 3) },
    0xff0000ffu,
    { 1, 1 } },
};

static constexpr uint16_t TRIANGLE_INDICES[3] = { 0, 1, 2 };

// This file is compiled via the matc tool. See the "Run Script" build
// phase.
static constexpr uint8_t BAKED_COLOR_PACKAGE[] = {
#include "bakedColor.inc"
};

const int MAT_NUM = 6;

#include <sys/time.h>
#include <time.h>

uint64_t
VeGetTimeOfDay () //获取当前时间，从1970.1.1.0.0.0开始计算，单位为毫秒
{
  struct timeval tTime;
  gettimeofday (&tTime, NULL);
  uint64_t temp = uint64_t (tTime.tv_sec);
  return uint64_t (temp * 1000 + tTime.tv_usec / 1000);
}

void
FilamentRender::InitWithRect ()
{
}
