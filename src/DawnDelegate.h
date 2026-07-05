#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>

#import <MetalKit/MetalKit.h>

@interface DawnDelegate : NSObject <MTKViewDelegate>

- (nonnull instancetype)initWithDawnView:(nonnull MTKView *)mtkView;

@end
