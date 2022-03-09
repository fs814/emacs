//@import MetalKit;
#include <config.h>

#import "LcRender.h"

#import "LcShaderTypes.h"
#import <MetalKit/MetalKit.h>
#import <simd/simd.h>

@implementation AAPLRenderer {
  id<MTLDevice> _device;

  id<MTLRenderPipelineState> _pipelineState;

  // The command queue used to pass commands to the device.
  id<MTLCommandQueue> _commandQueue;

  vector_uint2 _viewportSize;
}

- (nonnull instancetype)initWithMetalKitView:(nonnull MTKView *)mtkView {
  self = [super init];
  if (self) {
    NSError *error = NULL;

    _device = mtkView.device;

    NSString *myFile = [NSString
        stringWithContentsOfFile:
            @"/Users/fs814/sourcecode/editor/emacs-fswork/src/LcShaders.metal"
                        encoding:NSUTF8StringEncoding
                           error:&error];
    if (error) {
      NSLog(@"ERROR while loading from file: %@", error);
    }

    // NSString *myPath = [[NSBundle mainBundle]pathForResource:@"LcShaders"
    // ofType:@"metal"]; NSString *myFile = [[NSString
    // alloc]initWithContentsOfFile:myPath encoding:NSUTF8StringEncoding
    // error:nil];
    // NSLog(@"Our file contains this: %@", myFile);

    id<MTLLibrary> defaultLibrary =
        [_device newLibraryWithSource:myFile options:nil error:&error];
    id<MTLFunction> vertexFunction =
        [defaultLibrary newFunctionWithName:@"vertexShader"];
    id<MTLFunction> fragmentFunction =
        [defaultLibrary newFunctionWithName:@"fragmentShader"];

    MTLRenderPipelineDescriptor *pipelineDescriptor =
        [[MTLRenderPipelineDescriptor alloc] init];
    pipelineDescriptor.label = @"Simple Pipeline";
    pipelineDescriptor.vertexFunction = vertexFunction;
    pipelineDescriptor.fragmentFunction = fragmentFunction;
    pipelineDescriptor.colorAttachments[0].pixelFormat =
        mtkView.colorPixelFormat;

    _pipelineState =
        [_device newRenderPipelineStateWithDescriptor:pipelineDescriptor
                                                error:&error];

    if (!_pipelineState) {
      NSLog(@"Failed to created pipeline state, error %@", error);
      return nil;
    }
    // Create the command queue
    _commandQueue = [_device newCommandQueue];
  }

  return self;
}

/// Called whenever the view needs to render a frame.
- (void)drawInMTKView:(nonnull MTKView *)view {
  static const LcVertex triangleVetices[] = {
      //顶点,    RGBA 颜色值
      {{0.5, -0.25, 0.0, 1.0}, {1, 0, 0, 1}},
      {{-0.5, -0.25, 0.0, 1.0}, {0, 1, 0, 1}},
      {{-0.0f, 0.25, 0.0, 1.0}, {0, 0, 1, 1}},
  };

  id<MTLCommandBuffer> commandBuffer = [_commandQueue commandBuffer];
  commandBuffer.label = @"MyCommand";

  // The render pass descriptor references the texture into which Metal should
  // draw
  MTLRenderPassDescriptor *renderPassDescriptor =
      view.currentRenderPassDescriptor;
  if (renderPassDescriptor == nil) {
    return;
  }

  // Create a render pass and immediately end encoding, causing the drawable to
  // be cleared
  id<MTLRenderCommandEncoder> renderEncoder =
      [commandBuffer renderCommandEncoderWithDescriptor:renderPassDescriptor];
  renderEncoder.label = @"MyRenderEncoder";

  //视口指定Metal渲染内容的drawable区域。
  //视口是具有x和y偏移，宽度和高度以及近和远平面的3D区域
  //为管道分配自定义视口需要通过调用setViewport：方法将MTLViewport结构编码为渲染命令编码器。
  //如果未指定视口，Metal会设置一个默认视口，其大小与用于创建渲染命令编码器的drawable相同
  MTLViewport viewport = {0.0,  0.0, _viewportSize.x, _viewportSize.y,
                          -1.0, 1.0};
  [renderEncoder setViewport:viewport];

  [renderEncoder setRenderPipelineState:_pipelineState];

  // 7.从应用程序OC 代码 中发送数据给Metal 顶点着色器 函数
  //顶点数据+颜色数据
  //   1) 指向要传递给着色器的内存的指针
  //   2) 我们想要传递的数据的内存大小
  //   3)一个整数索引，它对应于我们的“vertexShader”函数中的缓冲区属性限定符的索引
  [renderEncoder setVertexBytes:triangleVetices
                         length:sizeof(triangleVetices)
                        atIndex:LcVertexInputIndexVertices];

  // viewPortSize 数据
  // 1) 发送到顶点着色函数中,视图大小
  // 2) 视图大小内存空间大小
  // 3) 对应的索引
  [renderEncoder setVertexBytes:&_viewportSize
                         length:sizeof(_viewportSize)
                        atIndex:LcVertexInputIndexViewportSize];

  // 8.画出三角形的3个顶点
  // @method drawPrimitives:vertexStart:vertexCount:
  //@brief 在不使用索引列表的情况下,绘制图元
  //@param 绘制图形组装的基元类型
  //@param 从哪个位置数据开始绘制,一般为0
  //@param 每个图元的顶点个数,绘制的图型顶点数量
  /*
   MTLPrimitiveTypePoint = 0, 点
   MTLPrimitiveTypeLine = 1, 线段
   MTLPrimitiveTypeLineStrip = 2, 线环
   MTLPrimitiveTypeTriangle = 3,  三角形
   MTLPrimitiveTypeTriangleStrip = 4, 三角型扇
   */
  [renderEncoder drawPrimitives:MTLPrimitiveTypeTriangle
                    vertexStart:0
                    vertexCount:3];

  [renderEncoder endEncoding];

  // Get the drawable that will be presented at the end of the frame

  id<MTLDrawable> drawable = view.currentDrawable;

  // Request that the drawable texture be presented by the windowing system once
  // drawing is done
  [commandBuffer presentDrawable:drawable];

  [commandBuffer commit];
}

/// Called whenever view changes orientation or is resized
- (void)mtkView:(nonnull MTKView *)view drawableSizeWillChange:(CGSize)size {
  _viewportSize.x = size.width;
  _viewportSize.y = size.height;
}

@end
