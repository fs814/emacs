#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>

#import <MetalKit/MetalKit.h>

@interface BgfxDelegate : NSObject <MTKViewDelegate>

- (nonnull instancetype)initWithBgfxView:(nonnull MTKView *)mtkView;

@end
