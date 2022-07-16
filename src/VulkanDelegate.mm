#include <config.h>

#import <AppKit/AppKit.h>

#import "VulkanDelegate.h"

#include "triangle.h"

@implementation VulkanDelegate {
    MTKView* _view;
    //VulkanExample* _vulkanExample;

    VulkanExample* _vulkanExample;

    NSSize _viewportSize;
}

- (nonnull instancetype)initWithVulkanView:(nonnull MTKView*)mtkView {
    self = [super init];

    _view = mtkView;

    _view.wantsLayer=YES;
    CAMetalLayer* caMetalLayer = [CAMetalLayer new];
    caMetalLayer.frame = _view.frame;
    caMetalLayer.device = mtkView.device;
    [_view.layer addSublayer:caMetalLayer];

    [self initializeVulkan];

    return self;
}

- (void)dealloc {
    delete _vulkanExample;
}

- (void)drawInMTKView:(nonnull MTKView*)view{
    //self->_vulkanExample->render();
    //self->_vulkanExample->updateOverlay();
}

- (void)mtkView:(nonnull MTKView*)view drawableSizeWillChange:(CGSize)size{
    NSSize curSize = size;
    _viewportSize = curSize;

    //CAMetalLayer* myLayer = (CAMetalLayer*)_view.layer;
    //myLayer.drawableSize = NSSizeToCGSize(curSize);
    _vulkanExample->windowWillResize(curSize.width,curSize.height);
    _vulkanExample->viewChanged();
}

- (void)initializeVulkan {
    _vulkanExample = new VulkanExample();
    _vulkanExample->initVulkan();

    _vulkanExample->setupWindow(_view);
    _vulkanExample->prepare();

    _vulkanExampleBase = _vulkanExample;
    //vulkanExample->renderLoop();
}
@end
