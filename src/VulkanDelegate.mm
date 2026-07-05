#include <config.h>

#ifdef HAVE_VULKAN
#import <AppKit/AppKit.h>

#import "VulkanDelegate.h"

#include "triangle.h"

@implementation VulkanDelegate {
    MTKView* _view;
    CAMetalLayer* _caMetalLayer;

    VulkanExample* _vulkanExample;

    NSSize _viewportSize;
}

- (nonnull instancetype)initWithVulkanView:(nonnull MTKView*)mtkView {
    self = [super init];

    _view = mtkView;

    _view.wantsLayer=YES;
    _caMetalLayer = [CAMetalLayer new];
    _caMetalLayer.frame = _view.bounds;
    _caMetalLayer.device = mtkView.device;
    _caMetalLayer.pixelFormat = MTLPixelFormatBGRA8Unorm;
    _caMetalLayer.framebufferOnly = YES;
    [_view.layer addSublayer:_caMetalLayer];

    [self initializeVulkan];

    return self;
}

- (void)dealloc {
    delete _vulkanExample;
    [super dealloc];
}

- (void)drawInMTKView:(nonnull MTKView*)view{
    if (_vulkanExample)
        _vulkanExample->render();
}

- (void)mtkView:(nonnull MTKView*)view drawableSizeWillChange:(CGSize)size{
    NSSize curSize = size;
    _viewportSize = curSize;

    _caMetalLayer.frame = _view.bounds;
    _caMetalLayer.drawableSize = size;
    if (_vulkanExample) {
        _vulkanExample->windowWillResize(curSize.width,curSize.height);
        _vulkanExample->viewChanged();
    }
}

- (void)initializeVulkan {
    _vulkanExample = new VulkanExample();
    _vulkanExample->initVulkan();

    _vulkanExample->setupWindow(_caMetalLayer);
    _vulkanExample->prepare();

    _vulkanExampleBase = _vulkanExample;
    //vulkanExample->renderLoop();
}
@end

#endif /* HAVE_VULKAN */
