#import "PXCSettings.h"
#import "PXCDustShader.h"
#import "PXCDirectionMath.h"
#import <stdlib.h>
#import <UIKit/UIKit.h>
#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>
#import <QuartzCore/QuartzCore.h>
#import <simd/simd.h>
#import <math.h>
#import <stdint.h>
#import <limits.h>

/* These are intentionally C-linkage entry points. PXCSettings.m is ObjC and
 * the public declarations are also wrapped in extern "C" by PXCSettings.h. */
extern "C" void PXCDustPrewarm(void);
extern "C" void PXCDustRemoveAll(void);

static const NSUInteger kPXCDustMaximumOverlays = 3;
static const size_t kPXCDustMaximumTextureBytes = 8u * 1024u * 1024u;
static const size_t kPXCDustMaximumTextureSide = 1600u;
static const CGFloat kPXCDustMinimumSide = 2.0;

typedef struct {
    simd_float2 center;
    simd_float2 size;
    simd_float2 uvOrigin;
    simd_float2 uvSize;
    float releaseAt;
    float drift;
    float swirl;
    float seed;
} PXParticleGPU;

typedef struct {
    simd_float2 overlaySize;
    simd_float2 localSize;
    simd_float2 sourceOrigin;
    simd_float2 basisX;
    simd_float2 basisY;
    float elapsed;
    float duration;
    simd_float2 texelSize;
    simd_float2 flowDirection;
} PXUniformsGPU;
static_assert(sizeof(PXParticleGPU)==48,"Metal particle ABI");
static_assert(sizeof(PXUniformsGPU)==64,"Metal uniform ABI");

/* GPU objects are prepared once. A failed preparation is terminal for this
 * process, which is deliberate: unsupported devices must not enter a retry or
 * busy loop on every notification/widget removal. */
static NSObject *gPXCDustGPULock;
static dispatch_once_t gPXCDustGPUOnce;
static dispatch_queue_t gPXCDustPrepareQueue;
static NSInteger gPXCDustGPUState = 0; // 0 idle, 1 preparing, 2 ready, 3 failed
static id<MTLDevice> gPXCDustDevice;
static id<MTLCommandQueue> gPXCDustQueue;
static id<MTLRenderPipelineState> gPXCDustPipeline;

/* All overlay accounting and all UIView/MTKView work is main-thread only. */
@class PXCDustOverlay;
static NSMutableSet<PXCDustOverlay *> *gPXCDustOverlays;
static NSUInteger gPXCDustOverlayCount = 0;
static size_t gPXCDustPixelBytes = 0;

static void PXCDustPrepareState(void) {
    dispatch_once(&gPXCDustGPUOnce, ^{
        gPXCDustGPULock = [NSObject new];
        gPXCDustPrepareQueue = dispatch_queue_create("com.niubiprass.particlex.dust-metal", DISPATCH_QUEUE_SERIAL);
    });
}

static void PXCDustInstallLifecycleObservers(void);

static void PXCDustPrepareGPUIfNeeded(void) {
    PXCDustPrepareState();
    BOOL shouldPrepare = NO;
    @synchronized (gPXCDustGPULock) {
        if (gPXCDustGPUState == 0) {
            gPXCDustGPUState = 1;
            shouldPrepare = YES;
        }
    }
    if (!shouldPrepare) return;

    dispatch_async(gPXCDustPrepareQueue, ^{
        @autoreleasepool {
            id<MTLDevice> device = MTLCreateSystemDefaultDevice();
            id<MTLCommandQueue> queue = device ? [device newCommandQueue] : nil;
            NSError *libraryError = nil;
            id<MTLLibrary> library = device ? [device newLibraryWithSource:PXCDustShaderSource()
                                                                       options:nil error:&libraryError] : nil;
            id<MTLFunction> vertex = [library newFunctionWithName:@"px_dust_vertex"];
            id<MTLFunction> fragment = [library newFunctionWithName:@"px_dust_fragment"];
            MTLRenderPipelineDescriptor *descriptor = nil;
            id<MTLRenderPipelineState> pipeline = nil;
            if (vertex && fragment && queue) {
                descriptor = [MTLRenderPipelineDescriptor new];
                descriptor.vertexFunction = vertex;
                descriptor.fragmentFunction = fragment;
                descriptor.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
                /* The shader returns premultiplied RGB from the screenshot. */
                MTLRenderPipelineColorAttachmentDescriptor *colour = descriptor.colorAttachments[0];
                colour.blendingEnabled = YES;
                colour.rgbBlendOperation = MTLBlendOperationAdd;
                colour.alphaBlendOperation = MTLBlendOperationAdd;
                colour.sourceRGBBlendFactor = MTLBlendFactorOne;
                colour.destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
                colour.sourceAlphaBlendFactor = MTLBlendFactorOne;
                colour.destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
                NSError *pipelineError = nil;
                pipeline = [device newRenderPipelineStateWithDescriptor:descriptor error:&pipelineError];
            }

            @synchronized (gPXCDustGPULock) {
                if (device && queue && pipeline) {
                    gPXCDustDevice = device;
                    gPXCDustQueue = queue;
                    gPXCDustPipeline = pipeline;
                    gPXCDustGPUState = 2;
                } else {
                    gPXCDustGPUState = 3;
                }
            }
            if (pipeline) PXCLog(@"Metal dust pipeline ready");
            else PXCLog([NSString stringWithFormat:@"Metal dust pipeline unavailable %@",libraryError.localizedDescription ?: @"device/queue/pipeline failure"]);
        }
    });
}

static BOOL PXCDustCopyGPUObjects(__strong id<MTLDevice> *deviceOut,
                                  __strong id<MTLCommandQueue> *queueOut,
                                  __strong id<MTLRenderPipelineState> *pipelineOut) {
    PXCDustPrepareState();
    @synchronized (gPXCDustGPULock) {
        if (gPXCDustGPUState != 2 || !gPXCDustDevice || !gPXCDustQueue || !gPXCDustPipeline) return NO;
        if (deviceOut) *deviceOut = gPXCDustDevice;
        if (queueOut) *queueOut = gPXCDustQueue;
        if (pipelineOut) *pipelineOut = gPXCDustPipeline;
        return YES;
    }
}

static BOOL PXCDustFinite(CGFloat value) {
    return isfinite((double)value);
}

static BOOL PXCDustFiniteRect(CGRect rect) {
    return PXCDustFinite(rect.origin.x) && PXCDustFinite(rect.origin.y) &&
           PXCDustFinite(rect.size.width) && PXCDustFinite(rect.size.height) &&
           !CGRectIsNull(rect) && !CGRectIsInfinite(rect);
}

static double PXCDustDuration(double duration) {
    if (!isfinite(duration)) return 1.15;
    return fmax(0.65, fmin(1.8, duration));
}

static BOOL PXCDustIsVisibleMountedView(UIView *view,
                                        UIWindow **windowOut,
                                        CGRect *boundsOut,
                                        CGRect *sourceFrameOut,
                                        CGFloat *scaleOut,
                                        CGPoint *originOut,
                                        CGPoint *xPointOut,
                                        CGPoint *yPointOut) {
    if (!NSThread.isMainThread || ![view isKindOfClass:UIView.class]) return NO;
    UIWindow *window = view.window;
    if (!window || view == window || window.hidden || window.alpha <= 0.01) return NO;
    if (view.hidden || view.alpha <= 0.01) return NO;

    for (UIView *ancestor = view; ancestor; ancestor = ancestor.superview) {
        if (ancestor.hidden || ancestor.alpha <= 0.01) return NO;
        if (ancestor == window) break;
    }

    CGRect bounds = view.bounds;
    if (!PXCDustFiniteRect(bounds) || bounds.size.width < kPXCDustMinimumSide ||
        bounds.size.height < kPXCDustMinimumSide) return NO;

    CGRect sourceFrame = [view convertRect:bounds toView:window];
    if (!PXCDustFiniteRect(sourceFrame) || sourceFrame.size.width < kPXCDustMinimumSide ||
        sourceFrame.size.height < kPXCDustMinimumSide) return NO;
    CGRect visible = CGRectIntersection(sourceFrame, window.bounds);
    if (!PXCDustFiniteRect(visible) || CGRectIsEmpty(visible)) return NO;

    UIScreen *screen = window.screen ?: UIScreen.mainScreen;
    CGFloat scale = screen.scale;
    if (!PXCDustFinite(scale) || scale < 1.0 || scale > 4.0) scale = 1.0;

    CGPoint p0 = [view convertPoint:CGPointMake(CGRectGetMinX(bounds), CGRectGetMinY(bounds)) toView:window];
    CGPoint px = [view convertPoint:CGPointMake(CGRectGetMaxX(bounds), CGRectGetMinY(bounds)) toView:window];
    CGPoint py = [view convertPoint:CGPointMake(CGRectGetMinX(bounds), CGRectGetMaxY(bounds)) toView:window];
    if (!PXCDustFinite(p0.x) || !PXCDustFinite(p0.y) || !PXCDustFinite(px.x) ||
        !PXCDustFinite(px.y) || !PXCDustFinite(py.x) || !PXCDustFinite(py.y)) return NO;

    if (windowOut) *windowOut = window;
    if (boundsOut) *boundsOut = bounds;
    if (sourceFrameOut) *sourceFrameOut = sourceFrame;
    if (scaleOut) *scaleOut = scale;
    if (originOut) *originOut = p0;
    if (xPointOut) *xPointOut = px;
    if (yPointOut) *yPointOut = py;
    return YES;
}

static BOOL PXCDustReserveBudget(size_t bytes) {
    if (gPXCDustOverlayCount >= kPXCDustMaximumOverlays) return NO;
    if (bytes == 0 || bytes > kPXCDustMaximumTextureBytes) return NO;
    if (gPXCDustPixelBytes > kPXCDustMaximumTextureBytes - bytes) return NO;
    gPXCDustOverlayCount += 1;
    gPXCDustPixelBytes += bytes;
    return YES;
}

static void PXCDustReleaseBudget(size_t bytes) {
    if (gPXCDustOverlayCount > 0) gPXCDustOverlayCount -= 1;
    if (gPXCDustPixelBytes >= bytes) gPXCDustPixelBytes -= bytes;
    else gPXCDustPixelBytes = 0;
}

static UIImage *PXCDustSnapshot(UIView *view, CGRect bounds, CGFloat scale) {
    UIGraphicsBeginImageContextWithOptions(bounds.size, NO, scale);
    CGContextRef context = UIGraphicsGetCurrentContext();
    if (!context) {
        UIGraphicsEndImageContext();
        return nil;
    }

    BOOL drawn = NO;
    @try {
        /* This is synchronous and does not alter hidden/alpha/superview state. */
        drawn = [view drawViewHierarchyInRect:CGRectMake(0,0,bounds.size.width,bounds.size.height) afterScreenUpdates:NO];
    } @catch (__unused NSException *exception) {
        drawn = NO;
    }
    if (!drawn) {
        @try {
            [view.layer renderInContext:context];
            drawn = YES;
        } @catch (__unused NSException *exception) {
            drawn = NO;
        }
    }
    UIImage *image = drawn ? UIGraphicsGetImageFromCurrentImageContext() : nil;
    UIGraphicsEndImageContext();
    return image;
}

static uint32_t PXCDustHash(uint32_t value) {
    value ^= value >> 16;
    value *= 0x7feb352dU;
    value ^= value >> 15;
    value *= 0x846ca68bU;
    value ^= value >> 16;
    return value;
}

static float PXCDustUnit(uint32_t value) {
    return (float)((double)value / 4294967295.0);
}

static NSUInteger PXCDustTargetCount(NSUInteger density) {
    switch (MIN((NSUInteger)2, density)) {
        case 0: return 3000;
        case 1: return 6000;
        default: return 10000;
    }
}

static NSMutableData *PXCDustMakeParticles(CGSize localSize, NSUInteger density, double duration, unsigned direction,
                                            NSUInteger *countOut) {
    if (!isfinite(localSize.width) || !isfinite(localSize.height) || localSize.width <= 0.0 ||
        localSize.height <= 0.0) return nil;

    NSUInteger target = PXCDustTargetCount(density);
    double aspect = localSize.width / localSize.height;
    if (!isfinite(aspect) || aspect <= 0.0) return nil;
    double root = sqrt((double)target * aspect);
    NSUInteger columns = (NSUInteger)floor(root);
    if (columns < 1) columns = 1;
    NSUInteger rows = target / columns;
    if (rows < 1) rows = 1;
    while (columns * rows < target && columns * (rows + 1) <= target) rows += 1;

    NSUInteger count = columns * rows;
    if (count == 0 || count > 10000) return nil;
    if (count > SIZE_MAX / sizeof(PXParticleGPU)) return nil;
    NSMutableData *data = [NSMutableData dataWithLength:count * sizeof(PXParticleGPU)];
    if (!data) return nil;
    PXParticleGPU *particles = (PXParticleGPU *)data.mutableBytes;
    float durationFloat = (float)duration;
    for (NSUInteger row = 0; row < rows; row++) {
        for (NSUInteger column = 0; column < columns; column++) {
            NSUInteger index = row * columns + column;
            uint32_t seed = PXCDustHash((uint32_t)(index + 1u) ^
                                         (uint32_t)(columns * 2654435761u) ^
                                         (uint32_t)(rows * 2246822519u));
            float randomA = PXCDustUnit(seed);
            float randomB = PXCDustUnit(PXCDustHash(seed ^ 0x9e3779b9U));
            float randomC = PXCDustUnit(PXCDustHash(seed ^ 0x68bc21ebU));
            float wave = (float)PXCReleaseProgress(direction,((double)column+0.5)/(double)columns,((double)row+0.5)/(double)rows);
            float releaseJitter = (randomA - 0.5f) * 0.16f;
            float release = fmaxf(0.0f, fminf(0.84f, wave * 0.72f + releaseJitter));

            PXParticleGPU *particle = &particles[index];
            particle->center = simd_make_float2(((float)column + 0.5f) / (float)columns,
                                                ((float)row + 0.5f) / (float)rows);
            particle->size = simd_make_float2(1.0f / (float)columns, 1.0f / (float)rows);
            particle->uvOrigin = simd_make_float2((float)column / (float)columns,
                                                  (float)row / (float)rows);
            particle->uvSize = particle->size;
            particle->releaseAt = release * durationFloat;
            particle->drift = 0.55f + randomB * 0.45f;
            particle->swirl = randomC * 2.0f - 1.0f;
            particle->seed = PXCDustUnit(PXCDustHash(seed ^ 0x51ed270bU));
        }
    }
    if (countOut) *countOut = count;
    return data;
}

static id<MTLTexture> PXCDustTextureFromImage(id<MTLDevice> device, UIImage *image) {
    CGImageRef imageRef = image.CGImage;
    if (!device || !imageRef) return nil;
    MTKTextureLoader *loader = [[MTKTextureLoader alloc] initWithDevice:device];
    NSDictionary *options = @{
        MTKTextureLoaderOptionOrigin : MTKTextureLoaderOriginTopLeft,
        MTKTextureLoaderOptionSRGB : @NO
    };
    NSError *error = nil;
    id<MTLTexture> texture = [loader newTextureWithCGImage:imageRef options:options error:&error];
    if (!texture || texture.width == 0 || texture.height == 0) return nil;
    (void)error;
    return texture;
}

@interface PXCDustOverlay : MTKView <MTKViewDelegate>
@property(nonatomic,strong) id<MTLCommandQueue> pxcQueue;
@property(nonatomic,strong) id<MTLRenderPipelineState> pxcPipeline;
@property(nonatomic,strong) id<MTLTexture> pxcTexture;
@property(nonatomic,strong) id<MTLBuffer> pxcParticles;
@property(nonatomic) NSUInteger pxcParticleCount;
@property(nonatomic) PXUniformsGPU pxcUniforms;
@property(nonatomic) CFTimeInterval pxcStart;
@property(nonatomic) size_t pxcReservedBytes;
@property(nonatomic) BOOL pxcFinished;
@property(nonatomic,strong) dispatch_semaphore_t pxcFrames;
- (void)pxcFinish;
@end
@implementation PXCDustOverlay
- (void)pxcFinish {
    if (self.pxcFinished) return;
    self.pxcFinished=YES;
    self.paused=YES;
    self.delegate=nil;
    PXCDustReleaseBudget(self.pxcReservedBytes);
    self.pxcReservedBytes=0;
    [gPXCDustOverlays removeObject:self];
    self.pxcTexture=nil;
    self.pxcParticles=nil;
    [self removeFromSuperview];
}
- (void)didMoveToWindow {
    [super didMoveToWindow];
    if (!self.window && self.pxcReservedBytes) [self pxcFinish];
}
- (void)mtkView:(MTKView *)view drawableSizeWillChange:(CGSize)size {
    if (self.pxcStart && CACurrentMediaTime()-self.pxcStart>0.05) [self pxcFinish];
}
- (void)drawInMTKView:(MTKView *)view {
    if (self.pxcFinished) return;
    float age=(float)(CACurrentMediaTime()-self.pxcStart);
    if (!self.window || self.window.hidden || age>=self.pxcUniforms.duration) { [self pxcFinish];return; }
    if (dispatch_semaphore_wait(self.pxcFrames,DISPATCH_TIME_NOW)!=0) return;
    id<CAMetalDrawable> drawable=self.currentDrawable;
    MTLRenderPassDescriptor *pass=self.currentRenderPassDescriptor;
    if (!drawable || !pass) { dispatch_semaphore_signal(self.pxcFrames);return; }
    id<MTLCommandBuffer> command=[self.pxcQueue commandBuffer];
    id<MTLRenderCommandEncoder> encoder=[command renderCommandEncoderWithDescriptor:pass];
    if (!command || !encoder) { dispatch_semaphore_signal(self.pxcFrames);return; }
    PXUniformsGPU u=self.pxcUniforms;u.elapsed=MAX(0.0f,age);
    [encoder setRenderPipelineState:self.pxcPipeline];
    [encoder setVertexBuffer:self.pxcParticles offset:0 atIndex:0];
    [encoder setVertexBytes:&u length:sizeof(u) atIndex:1];
    [encoder setFragmentTexture:self.pxcTexture atIndex:0];
    [encoder setFragmentBytes:&u length:sizeof(u) atIndex:1];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4 instanceCount:self.pxcParticleCount];
    [encoder endEncoding];
    dispatch_semaphore_t frames=self.pxcFrames;
    [command addCompletedHandler:^(id<MTLCommandBuffer> b) { dispatch_semaphore_signal(frames); }];
    [command presentDrawable:drawable];
    [command commit];
}
@end

static void PXCDustInstallLifecycleObservers(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidReceiveMemoryWarningNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) { PXCDustRemoveAll(); }];
        [[NSNotificationCenter defaultCenter] addObserverForName:UIDeviceOrientationDidChangeNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) { PXCDustRemoveAll(); }];
    });
}
void PXCDustPrewarm(void) {
    if (!NSThread.isMainThread) { dispatch_async(dispatch_get_main_queue(), ^{ PXCDustPrewarm(); });return; }
    PXCDustInstallLifecycleObservers();
    if (!UIAccessibilityIsReduceMotionEnabled()) PXCDustPrepareGPUIfNeeded();
}
void PXCDustRemoveAll(void) {
    if (!NSThread.isMainThread) { dispatch_async(dispatch_get_main_queue(), ^{ PXCDustRemoveAll(); });return; }
    for (PXCDustOverlay *view in gPXCDustOverlays.allObjects) [view pxcFinish];
}

static BOOL PXCDustRenderImage(UIImage *image,UIWindow *window,CGSize localSize,CGRect sourceFrame,CGPoint p0,CGPoint px,CGPoint py,NSUInteger requested,NSString *label) {
    id<MTLDevice> device=nil;id<MTLCommandQueue> queue=nil;id<MTLRenderPipelineState> pipeline=nil;
    if (!PXCDustCopyGPUObjects(&device,&queue,&pipeline)) { PXCDustPrepareGPUIfNeeded();PXCLog(@"dust skip gpu-not-ready");return NO; }
    double w=localSize.width,h=localSize.height;
    CGImageRef cg=image.CGImage;
    size_t tw=cg ? CGImageGetWidth(cg) : 0,th=cg ? CGImageGetHeight(cg) : 0;
    if (!tw || !th || tw>kPXCDustMaximumTextureSide || th>kPXCDustMaximumTextureSide || tw>SIZE_MAX/(4*th)) { PXCLog(@"dust skip invalid-bitmap-size");return NO; }
    size_t bytes=tw*th*4;
    if (!PXCDustReserveBudget(bytes)) { PXCLog(@"dust skip overlay/texture-budget");return NO; }
    unsigned direction=PXCResolvedDirection((unsigned)requested,arc4random());
    PXCDustOverlay *overlay=nil;
    BOOL transferred=NO;
    @try {
        id<MTLTexture> texture=PXCDustTextureFromImage(device,image);
        if (!texture) { PXCDustReleaseBudget(bytes);PXCLog(@"dust skip texture-upload");return NO; }
        // Validate loader dimensions as well as predicted bitmap dimensions.
        if (texture.width>1600 || texture.height>1600 || texture.width*texture.height*4>bytes) { PXCDustReleaseBudget(bytes);return NO; }
        PXCSettings settings=PXCSettingsGet();double duration=PXCDustDuration(settings.duration);
        NSUInteger count=0;
        NSMutableData *data=PXCDustMakeParticles(localSize,settings.density,duration,direction,&count);
        if (!data || !count) { PXCDustReleaseBudget(bytes);return NO; }
        id<MTLBuffer> particles=[device newBufferWithBytes:data.bytes length:data.length options:MTLResourceStorageModeShared];
        if (!particles) { PXCDustReleaseBudget(bytes);return NO; }
        CGFloat margin=MIN(180.0,MAX(sourceFrame.size.width,sourceFrame.size.height)*0.42);
        CGRect frame=CGRectIntersection(CGRectInset(sourceFrame,-margin,-margin),window.bounds);
        if (!PXCDustFiniteRect(frame) || CGRectIsEmpty(frame)) { PXCDustReleaseBudget(bytes);return NO; }
        overlay=[[PXCDustOverlay alloc] initWithFrame:frame device:device];
        if (!overlay) { PXCDustReleaseBudget(bytes);return NO; }
        overlay.opaque=NO;
        overlay.backgroundColor=UIColor.clearColor;
        overlay.userInteractionEnabled=NO;
        overlay.accessibilityElementsHidden=YES;
        overlay.colorPixelFormat=MTLPixelFormatBGRA8Unorm;
        overlay.clearColor=MTLClearColorMake(0,0,0,0);
        overlay.framebufferOnly=YES;
        overlay.preferredFramesPerSecond=60;
        overlay.contentScaleFactor=MIN(2.0,window.screen.scale);
        overlay.autoResizeDrawable=YES;
        overlay.enableSetNeedsDisplay=NO;
        overlay.paused=YES;
        overlay.pxcQueue=queue;overlay.pxcPipeline=pipeline;
        overlay.pxcTexture=texture;overlay.pxcParticles=particles;overlay.pxcParticleCount=count;
        overlay.pxcFrames=dispatch_semaphore_create(2);
        PXUniformsGPU u={};
        u.overlaySize=simd_make_float2(frame.size.width,frame.size.height);
        u.localSize=simd_make_float2(w,h);
        u.sourceOrigin=simd_make_float2(p0.x-frame.origin.x,p0.y-frame.origin.y);
        u.basisX=simd_make_float2((px.x-p0.x)/w,(px.y-p0.y)/w);
        u.basisY=simd_make_float2((py.x-p0.x)/h,(py.y-p0.y)/h);
        u.duration=(float)duration;u.elapsed=0;
        u.texelSize=simd_make_float2(1.0f/texture.width,1.0f/texture.height);
        double dx,dy;PXCDirectionVector(direction,&dx,&dy);
        u.flowDirection=simd_make_float2(dx,dy);
        overlay.pxcUniforms=u;
        overlay.delegate=overlay;
        if (!gPXCDustOverlays) gPXCDustOverlays=[NSMutableSet set];
        [gPXCDustOverlays addObject:overlay];
        overlay.pxcReservedBytes=bytes;transferred=YES;
        [window addSubview:overlay];
        overlay.pxcStart=CACurrentMediaTime();
        overlay.paused=NO;
        [overlay draw];
        __weak PXCDustOverlay *weak=overlay;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)((duration+0.15)*NSEC_PER_SEC)),dispatch_get_main_queue(), ^{ [weak pxcFinish]; });
        PXCLog([NSString stringWithFormat:@"dust start class=%@ count=%lu pixels=%zux%zu direction=%u",label,(unsigned long)count,tw,th,direction]);
        return YES;
    } @catch (NSException *exception) {
        if (transferred) [overlay pxcFinish];else PXCDustReleaseBudget(bytes);
        PXCLog([@"dust failed safely " stringByAppendingString:exception.name]);
        return NO;
    }
}

static CGFloat PXCDustScaleForSize(CGSize size,CGFloat nativeScale) {
    double w=size.width,h=size.height;
    if (!isfinite(w) || !isfinite(h) || w<2 || h<2 || w>4096 || h>4096) return 0;
    double scale=fmin(nativeScale,(double)(kPXCDustMaximumTextureSide-2)/fmax(w,h));
    scale=fmin(scale,sqrt((double)(kPXCDustMaximumTextureBytes-16384)/(4.0*w*h)));
    return isfinite(scale) && scale>=0.25 ? (CGFloat)scale : 0;
}
BOOL PXCDisintegrateView(UIView *view) { return PXCDisintegrateViewDirection(view,0); }
BOOL PXCDisintegrateViewDirection(UIView *view,NSUInteger direction) {
    if (!NSThread.isMainThread || UIAccessibilityIsReduceMotionEnabled() || !PXCSettingsGet().enabled) return NO;
    UIWindow *window=nil;CGRect bounds,frame;CGFloat scale;CGPoint p0,px,py;
    if (!PXCDustIsVisibleMountedView(view,&window,&bounds,&frame,&scale,&p0,&px,&py)) { PXCLog(@"dust skip unmounted/invisible-source");return NO; }
    scale=PXCDustScaleForSize(bounds.size,scale);
    if (!scale) { PXCLog(@"dust skip source-size");return NO; }
    UIImage *image=PXCDustSnapshot(view,bounds,scale);
    if (!image) { PXCLog(@"dust skip snapshot-empty");return NO; }
    return PXCDustRenderImage(image,window,bounds.size,frame,p0,px,py,direction,NSStringFromClass(view.class));
}
BOOL PXCDisintegrateViews(NSArray<UIView *> *views,NSUInteger direction) {
    if (!NSThread.isMainThread || UIAccessibilityIsReduceMotionEnabled() || !PXCSettingsGet().enabled || !views.count) return NO;
    // Notification cells can exceed the screen's content height. Composite only
    // mounted visible platters into one screen-local transparent texture; gaps,
    // clock, wallpaper and our clear button must NOT become dust.
    UIWindow *window=nil;CGRect unionRect=CGRectNull;
    NSMutableArray<UIView *> *sources=[NSMutableArray array];
    NSMutableArray<NSValue *> *rects=[NSMutableArray array];
    for (UIView *v in views) {
        UIWindow *w=nil;CGRect b,frame;CGFloat scale;CGPoint p0,px,py;
        if (!PXCDustIsVisibleMountedView(v,&w,&b,&frame,&scale,&p0,&px,&py)) continue;
        if (!window) window=w;
        if (w!=window) continue;
        CGRect clipped=CGRectIntersection(frame,w.bounds);
        for (UIView *a=v.superview;a && !CGRectIsEmpty(clipped);a=a.superview)
            if (a.clipsToBounds) clipped=CGRectIntersection(clipped,[a convertRect:a.bounds toView:w]);
        if (CGRectIsEmpty(clipped)) continue;
        unionRect=CGRectIsNull(unionRect) ? clipped : CGRectUnion(unionRect,clipped);
        [sources addObject:v];[rects addObject:[NSValue valueWithCGRect:clipped]];
        if (sources.count>=80) break;
    }
    if (!window || !sources.count || CGRectIsNull(unionRect)) { PXCLog(@"dust skip no-visible-notification-platters");return NO; }
    CGFloat scale=PXCDustScaleForSize(unionRect.size,window.screen.scale);
    if (!scale) { PXCLog(@"dust skip notification-composite-size");return NO; }
    UIGraphicsBeginImageContextWithOptions(unionRect.size,NO,scale);
    CGContextRef context=UIGraphicsGetCurrentContext();
    if (!context) { UIGraphicsEndImageContext();PXCLog(@"dust skip composite-context");return NO; }
    NSUInteger drawn=0;
    @try {
        for (NSUInteger i=0;i<sources.count;i++) {
            UIView *v=sources[i];CGRect b=v.bounds;
            CGPoint o=[v convertPoint:b.origin toView:window];
            CGPoint px=[v convertPoint:CGPointMake(CGRectGetMaxX(b),CGRectGetMinY(b)) toView:window];
            CGPoint py=[v convertPoint:CGPointMake(CGRectGetMinX(b),CGRectGetMaxY(b)) toView:window];
            CGRect clip=CGRectOffset(rects[i].CGRectValue,-unionRect.origin.x,-unionRect.origin.y);
            CGContextSaveGState(context);CGContextClipToRect(context,clip);
            CGAffineTransform t=CGAffineTransformMake((px.x-o.x)/b.size.width,(px.y-o.y)/b.size.width,(py.x-o.x)/b.size.height,(py.y-o.y)/b.size.height,o.x-unionRect.origin.x,o.y-unionRect.origin.y);
            CGContextConcatCTM(context,t);
            BOOL okay=[v drawViewHierarchyInRect:CGRectMake(0,0,b.size.width,b.size.height) afterScreenUpdates:NO];
            if (!okay) {
                CGContextTranslateCTM(context,-b.origin.x,-b.origin.y);
                [v.layer renderInContext:context];
            }
            CGContextRestoreGState(context);drawn++;
        }
    } @catch (NSException *e) { PXCLog([@"dust composite exception " stringByAppendingString:e.name]); }
    UIImage *image=drawn ? UIGraphicsGetImageFromCurrentImageContext() : nil;
    UIGraphicsEndImageContext();
    if (!image) { PXCLog(@"dust skip composite-empty");return NO; }
    CGPoint p0=unionRect.origin,px=CGPointMake(CGRectGetMaxX(unionRect),CGRectGetMinY(unionRect)),py=CGPointMake(CGRectGetMinX(unionRect),CGRectGetMaxY(unionRect));
    return PXCDustRenderImage(image,window,unionRect.size,unionRect,p0,px,py,direction,[NSString stringWithFormat:@"notification-batch(%lu)",(unsigned long)drawn]);
}
