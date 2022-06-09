#import <Foundation/Foundation.h>

//#import MetalKit;

#import <MetalKit/MetalKit.h>

@interface AAPLRenderer : NSObject <MTKViewDelegate>

- (nonnull instancetype)initWithMetalKitView:(nonnull MTKView *)mtkView;

@end
