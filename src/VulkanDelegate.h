#include <config.h>

#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>

#import <MetalKit/MetalKit.h>


@interface VulkanDelegate : NSObject <MTKViewDelegate> {
@public
void* _vulkanExampleBase;
}

- (nonnull instancetype)initWithVulkanView:(nonnull MTKView *)mtkView;

@end
