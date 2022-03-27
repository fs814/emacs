#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>

#import <MetalKit/MetalKit.h>

@interface FilamentDelegate : NSObject <MTKViewDelegate>

- (nonnull instancetype)initWithFilamentView:(nonnull MTKView *)mtkView;

@end
