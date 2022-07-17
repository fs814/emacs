#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>

#import <MetalKit/MetalKit.h>

@interface XwVulkanView : MTKView
//@property(nonatomic, strong) id<MTLTexture> texture;
@property struct xwidget *xw;
- (id)initWithFrame:(CGRect)frameRect device:(nullable id<MTLDevice>)device xwidget:(struct xwidget*)xw;
@end
