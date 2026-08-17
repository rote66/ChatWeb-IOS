#import "GeminiGeckoMetalView.h"

#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>

static NSString * const GeminiGeckoMetalErrorDomain = @"GeminiGeckoMetalView";

@interface GeminiGeckoMetalView ()
@property(nonatomic, strong, nullable) id<MTLDevice> metalDevice;
@property(nonatomic, strong, nullable) id<MTLCommandQueue> commandQueue;
@end

@implementation GeminiGeckoMetalView

+ (Class)layerClass {
    return CAMetalLayer.class;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        [self configureMetal];
    }
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder {
    self = [super initWithCoder:coder];
    if (self) {
        [self configureMetal];
    }
    return self;
}

- (CAMetalLayer *)metalLayer {
    return (CAMetalLayer *)self.layer;
}

- (void)configureMetal {
    self.opaque = YES;
    self.metalDevice = MTLCreateSystemDefaultDevice();
    self.commandQueue = [self.metalDevice newCommandQueue];

    CAMetalLayer *layer = self.metalLayer;
    layer.device = self.metalDevice;
    layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
    layer.framebufferOnly = YES;
    layer.contentsScale = UIScreen.mainScreen.scale;
}

- (BOOL)metalAvailable {
    return self.metalDevice != nil && self.commandQueue != nil;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat scale = self.window.screen.scale ?: UIScreen.mainScreen.scale;
    self.metalLayer.contentsScale = scale;
    self.metalLayer.drawableSize = CGSizeMake(
        MAX(1.0, CGRectGetWidth(self.bounds) * scale),
        MAX(1.0, CGRectGetHeight(self.bounds) * scale)
    );
}

- (BOOL)renderProbeFrame:(NSError **)error {
    if (!self.metalAvailable) {
        if (error) {
            *error = [NSError errorWithDomain:GeminiGeckoMetalErrorDomain
                                         code:1
                                     userInfo:@{NSLocalizedDescriptionKey: @"Metal device or queue unavailable"}];
        }
        return NO;
    }

    id<CAMetalDrawable> drawable = [self.metalLayer nextDrawable];
    if (!drawable) {
        if (error) {
            *error = [NSError errorWithDomain:GeminiGeckoMetalErrorDomain
                                         code:2
                                     userInfo:@{NSLocalizedDescriptionKey: @"CAMetalLayer returned no drawable"}];
        }
        return NO;
    }

    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = drawable.texture;
    pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    pass.colorAttachments[0].clearColor = MTLClearColorMake(0.08, 0.08, 0.09, 1.0);

    id<MTLCommandBuffer> commandBuffer = [self.commandQueue commandBuffer];
    id<MTLRenderCommandEncoder> encoder = [commandBuffer renderCommandEncoderWithDescriptor:pass];
    [encoder endEncoding];
    [commandBuffer presentDrawable:drawable];
    [commandBuffer commit];
    return YES;
}

@end
