#import "PXCSettings.h"
#import "PXCDustShader.h"
#import "PXCDirectionMath.h"
#import "PXCDensity.h"
#import "PXCDustMotion.h"
#import "PXCPerformance.h"
#import "PXCPoseMath.h"
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
extern "C" void PXCDustRemoveAll(void);


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
    uint32_t effectStyle;
    float flowPhase;
} PXUniformsGPU;
static_assert(sizeof(PXParticleGPU)==48,"Metal particle ABI");
static_assert(sizeof(PXUniformsGPU)==72,"Metal uniform ABI");

/* Created only for an actual effect, released after the last effect.
 * The small lock/serial queue are metadata, not a resident render loop. */
static NSObject *gPXCDustGPULock;
static dispatch_once_t gPXCDustGPUOnce;
static dispatch_queue_t gPXCDustPrepareQueue;
static NSInteger gPXCDustGPUState = 0; // 0 idle, 1 preparing, 2 ready, 3 failed
static NSUInteger gPXCDustGPUEpoch;
static void PXCDustResolvePending(void);
static void PXCDustDropGPUIfIdle(void);
static id<MTLDevice> gPXCDustDevice;
static id<MTLCommandQueue> gPXCDustQueue;
static id<MTLRenderPipelineState> gPXCDustPipeline;

/* All overlay accounting and all UIView/MTKView work is main-thread only. */
@class PXCDustOverlay;
static NSMutableSet<PXCDustOverlay *> *gPXCDustOverlays;
static NSUInteger gPXCDustOverlayCount = 0;
static size_t gPXCDustPixelBytes = 0;
static NSUInteger gPXCDustParticleCount = 0;
static CFTimeInterval gPXCDustLastStart = 0;
/* Small pipeline-only reservation while Notification Centre is visible. */
static NSUInteger gPXCDustSessions = 0;

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
    NSUInteger epoch=0;
    @synchronized (gPXCDustGPULock) {
        if (gPXCDustGPUState == 0) {
            gPXCDustGPUState = 1;
            epoch=++gPXCDustGPUEpoch;
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

            dispatch_async(dispatch_get_main_queue(), ^{
                @synchronized (gPXCDustGPULock) {
                    if (epoch!=gPXCDustGPUEpoch) return;
                    if (device && queue && pipeline) {
                        gPXCDustDevice=device;gPXCDustQueue=queue;gPXCDustPipeline=pipeline;
                        gPXCDustGPUState=2;
                    } else gPXCDustGPUState=3;
                }
                if (pipeline) PXCLog(@"Metal dust pipeline ready on demand");
                else PXCLog(@"Metal dust pipeline unavailable; native operation unaffected");
                PXCDustResolvePending();PXCDustDropGPUIfIdle();
            });
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

typedef struct {
    CGRect bounds,frame,clip;
    CGPoint origin,xPoint,yPoint;
    BOOL presentation;
} PXCDustPose;

static BOOL PXCDustReadPose(UIView *view,UIWindow **windowOut,PXCDustPose *pose,CGFloat *scaleOut) {
    if (!NSThread.isMainThread || ![view isKindOfClass:UIView.class] || !pose) return NO;
    UIWindow *window=view.window;
    if (!window || view==window || window.hidden || window.alpha<=0.01) return NO;
    CALayer *source=view.layer,*target=window.layer;
    BOOL live=source.presentationLayer && target.presentationLayer;
    if (live) { source=(CALayer *)source.presentationLayer;target=(CALayer *)target.presentationLayer; }
    for (UIView *v=view;v;v=v.superview) {
        CALayer *layer=live ? (CALayer *)v.layer.presentationLayer : v.layer;
        if (!layer || v.hidden || layer.opacity<=0.01) return NO;
        if (v==window) break;
    }
    @try {
        CGRect bounds=source.bounds;
        if (!PXCDustFiniteRect(bounds) || bounds.size.width<2 || bounds.size.height<2) return NO;
        pose->bounds=bounds;pose->presentation=live;
        pose->frame=[source convertRect:bounds toLayer:target];
        pose->origin=[source convertPoint:bounds.origin toLayer:target];
        pose->xPoint=[source convertPoint:CGPointMake(CGRectGetMaxX(bounds),CGRectGetMinY(bounds)) toLayer:target];
        pose->yPoint=[source convertPoint:CGPointMake(CGRectGetMinX(bounds),CGRectGetMaxY(bounds)) toLayer:target];
        pose->clip=CGRectIntersection(pose->frame,target.bounds);
        for (UIView *v=view.superview;v && !CGRectIsEmpty(pose->clip);v=v.superview) {
            if (!v.clipsToBounds) continue;
            CALayer *layer=live ? (CALayer *)v.layer.presentationLayer : v.layer;
            if (!layer) return NO;
            pose->clip=CGRectIntersection(pose->clip,[layer convertRect:layer.bounds toLayer:target]);
        }
        PXCPoseTransform t;
        if (!PXCDustFiniteRect(pose->frame) || !PXCDustFiniteRect(pose->clip) || CGRectIsEmpty(pose->clip) ||
            !PXCPoseTransformMake(bounds.size.width,bounds.size.height,pose->origin.x,pose->origin.y,
                pose->xPoint.x,pose->xPoint.y,pose->yPoint.x,pose->yPoint.y,0,0,&t)) return NO;
    } @catch (NSException *e) { PXCLog(@"dust skip disconnected/invalid presentation pose");return NO; }
    if (windowOut) *windowOut=window;
    if (scaleOut) *scaleOut=window.screen.scale;
    return YES;
}

static BOOL PXCDustMayStart(void) {
    PXCPerformanceBudget b=PXCPerformanceGet();
    if (!b.allowed || gPXCDustGPUState==3 || gPXCDustOverlayCount>=b.overlays || gPXCDustParticleCount>=b.totalParticles ||
        CACurrentMediaTime()-gPXCDustLastStart<0.12) return NO;
    return YES;
}
static BOOL PXCDustReserveBudget(size_t bytes) {
    PXCPerformanceBudget b=PXCPerformanceGet();
    if (!b.allowed || gPXCDustOverlayCount>=b.overlays || bytes==0 || bytes>b.textureBytes ||
        bytes>b.totalTextureBytes || gPXCDustPixelBytes>b.totalTextureBytes-bytes) return NO;
    gPXCDustOverlayCount += 1;
    gPXCDustPixelBytes += bytes;
    return YES;
}

static void PXCDustReleaseBudget(size_t bytes) {
    if (gPXCDustOverlayCount > 0) gPXCDustOverlayCount -= 1;
    if (gPXCDustPixelBytes >= bytes) gPXCDustPixelBytes -= bytes;
    else gPXCDustPixelBytes = 0;
}

static void PXCDustDropGPUIfIdle(void) {
    if (gPXCDustOverlayCount || gPXCDustSessions) return;
    @synchronized (gPXCDustGPULock) {
        gPXCDustDevice=nil;gPXCDustQueue=nil;gPXCDustPipeline=nil;
        gPXCDustGPUEpoch++;
        if (gPXCDustGPUState!=3) gPXCDustGPUState=0;
    }
    gPXCDustOverlays=nil;
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
    return PXCDensityGet((unsigned)MIN((NSUInteger)3,density)).dustParticles;
}

static NSMutableData *PXCDustMakeParticles(CGSize localSize, NSUInteger density, double duration, double flowAngle,
                                            unsigned effectStyle,float flowPhase,BOOL urgent,NSUInteger particleBudget,NSUInteger *countOut) {
    if (!isfinite(localSize.width) || !isfinite(localSize.height) || localSize.width <= 0.0 ||
        localSize.height <= 0.0) return nil;

    NSUInteger target = MIN(PXCDustTargetCount(density),particleBudget);
    if (!target) return nil;
    double aspect = localSize.width / localSize.height;
    if (!isfinite(aspect) || aspect <= 0.0) return nil;
    double root = sqrt((double)target * aspect);
    NSUInteger columns = (NSUInteger)floor(root);
    if (columns < 1) columns = 1;
    NSUInteger rows = target / columns;
    if (rows < 1) rows = 1;
    while (columns * rows < target && columns * (rows + 1) <= target) rows += 1;

    NSUInteger count = columns * rows;
    if (count == 0 || count > 16000 || count > particleBudget) return nil;
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
            float wave = (float)PXCReleaseProgressAngle(flowAngle,((double)column+0.5)/(double)columns,((double)row+0.5)/(double)rows);
            float releaseJitter = (randomA - 0.5f) * 0.16f;
            float release = effectStyle==0 ? PXCWindReleaseAt(((float)column+0.5f)/(float)columns,((float)row+0.5f)/(float)rows,randomA,flowPhase,urgent?1.0f:0.0f) :
                fmaxf(0.0f, fminf(urgent?0.20f:0.84f, wave * (urgent?0.16f:0.72f) + releaseJitter*(urgent?0.5f:1.0f)));

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

@interface PXCDustOverlay : UIView <MTKViewDelegate>
@property(nonatomic,strong) MTKView *pxcMetal;
@property(nonatomic,strong) UIImageView *pxcPreview;
@property(nonatomic,strong) id<MTLCommandQueue> pxcQueue;
@property(nonatomic,strong) id<MTLRenderPipelineState> pxcPipeline;
@property(nonatomic,strong) id<MTLTexture> pxcTexture;
@property(nonatomic,strong) id<MTLBuffer> pxcParticles;
@property(nonatomic) NSUInteger pxcParticleCount;
@property(nonatomic) NSUInteger pxcDensity;
@property(nonatomic) double pxcAngle;
@property(nonatomic) PXUniformsGPU pxcUniforms;
@property(nonatomic) CGRect pxcSourceFrame;
@property(nonatomic) CFTimeInterval pxcStart;
@property(nonatomic) size_t pxcReservedBytes;
@property(nonatomic) BOOL pxcFinished;
@property(nonatomic) BOOL pxcLoggedFirstFrame;
@property(nonatomic,strong) dispatch_semaphore_t pxcFrames;
- (void)pxcFinish;
- (void)pxcStartGPU;
@end
@implementation PXCDustOverlay
- (void)pxcFinish {
    if (self.pxcFinished) return;
    self.pxcFinished=YES;
    self.pxcMetal.paused=YES;self.pxcMetal.delegate=nil;
    [self.pxcMetal releaseDrawables];[self.pxcMetal removeFromSuperview];
    self.pxcMetal.device=nil;self.pxcMetal=nil;
    self.pxcPreview.image=nil;[self.pxcPreview removeFromSuperview];self.pxcPreview=nil;
    self.pxcTexture=nil;self.pxcParticles=nil;self.pxcQueue=nil;self.pxcPipeline=nil;
    self.pxcFrames=nil;
    PXCDustReleaseBudget(self.pxcReservedBytes);
    gPXCDustParticleCount-=MIN(gPXCDustParticleCount,self.pxcParticleCount);
    self.pxcParticleCount=0;self.pxcReservedBytes=0;
    [gPXCDustOverlays removeObject:self];[self removeFromSuperview];
    PXCDustDropGPUIfIdle();
}
- (void)didMoveToWindow {
    [super didMoveToWindow];
    if (!self.window && self.pxcReservedBytes) [self pxcFinish];
}
- (void)pxcStartGPU {
    if (self.pxcFinished || self.pxcMetal) return;
    if (!self.window || !PXCPerformanceGet().allowed) { [self pxcFinish];return; }
    id<MTLDevice> device=nil;id<MTLCommandQueue> queue=nil;id<MTLRenderPipelineState> pipeline=nil;
    if (!PXCDustCopyGPUObjects(&device,&queue,&pipeline)) {
        if (gPXCDustGPUState==3) [self pxcFinish];
        return;
    }
    @try {
        id<MTLTexture> texture=PXCDustTextureFromImage(device,self.pxcPreview.image);
        NSUInteger count=0;
        double duration=self.pxcUniforms.duration;
        NSMutableData *data=PXCDustMakeParticles(self.pxcSourceFrame.size,self.pxcDensity,duration,self.pxcAngle,self.pxcUniforms.effectStyle & 1u,self.pxcUniforms.flowPhase,(self.pxcUniforms.effectStyle&2u)!=0,self.pxcParticleCount,&count);
        id<MTLBuffer> particles=data ? [device newBufferWithBytes:data.bytes length:data.length options:MTLResourceStorageModeShared] : nil;
        if (!texture || !particles || !count || texture.width*texture.height*4>self.pxcReservedBytes) { PXCLog(@"dust skip texture/buffer preparation");[self pxcFinish];return; }
        gPXCDustParticleCount-=self.pxcParticleCount-count;self.pxcParticleCount=count;
        self.pxcTexture=texture;self.pxcParticles=particles;self.pxcQueue=queue;self.pxcPipeline=pipeline;
        self.pxcFrames=dispatch_semaphore_create(2);
        PXUniformsGPU u=self.pxcUniforms;
        u.texelSize=simd_make_float2(1.0f/texture.width,1.0f/texture.height);self.pxcUniforms=u;
        MTKView *metal=[[MTKView alloc] initWithFrame:self.bounds device:device];
        metal.opaque=NO;metal.backgroundColor=UIColor.clearColor;metal.userInteractionEnabled=NO;
        metal.clearColor=MTLClearColorMake(0,0,0,0);metal.colorPixelFormat=MTLPixelFormatBGRA8Unorm;
        metal.framebufferOnly=YES;metal.contentScaleFactor=MIN(1.5,self.window.screen.scale);
        metal.preferredFramesPerSecond=PXCPerformanceGet().fps;
        metal.autoResizeDrawable=YES;metal.enableSetNeedsDisplay=NO;metal.paused=YES;
        self.pxcMetal=metal;[self insertSubview:metal atIndex:0];metal.delegate=self;
        self.pxcStart=CACurrentMediaTime();metal.paused=NO;
        __weak PXCDustOverlay *weak=self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)((duration+0.2)*NSEC_PER_SEC)),dispatch_get_main_queue(), ^{ [weak pxcFinish]; });
        PXCLog([NSString stringWithFormat:@"dust start particles=%lu angle=%u style=%u fps=%u",(unsigned long)count,(unsigned)(self.pxcAngle*57.2957795),u.effectStyle,PXCPerformanceGet().fps]);
    } @catch (NSException *e) { PXCLog([@"dust prepare exception " stringByAppendingString:e.name]);[self pxcFinish]; }
}
- (void)mtkView:(MTKView *)view drawableSizeWillChange:(CGSize)size {
    if (self.pxcStart && CACurrentMediaTime()-self.pxcStart>0.05) [self pxcFinish];
}
- (void)drawInMTKView:(MTKView *)view {
    if (self.pxcFinished) return;
    float age=(float)(CACurrentMediaTime()-self.pxcStart);
    if (!self.window || self.window.hidden || !PXCPerformanceGet().allowed || age>=self.pxcUniforms.duration) { [self pxcFinish];return; }
    if (dispatch_semaphore_wait(self.pxcFrames,DISPATCH_TIME_NOW)!=0) return;
    id<CAMetalDrawable> drawable=view.currentDrawable;
    MTLRenderPassDescriptor *pass=view.currentRenderPassDescriptor;
    if (!drawable || !pass) { dispatch_semaphore_signal(self.pxcFrames);return; }
    id<MTLCommandBuffer> command=[self.pxcQueue commandBuffer];
    id<MTLRenderCommandEncoder> encoder=[command renderCommandEncoderWithDescriptor:pass];
    if (!command || !encoder) { dispatch_semaphore_signal(self.pxcFrames);return; }
    if (!self.pxcLoggedFirstFrame) {
        self.pxcLoggedFirstFrame=YES;
        PXCLog([NSString stringWithFormat:@"dust first frame +%.0fms urgent=%d",(age)*1000.0,(self.pxcUniforms.effectStyle&2u)!=0]);
    }
    PXUniformsGPU u=self.pxcUniforms;u.elapsed=MAX(0.0f,age);
    [encoder setRenderPipelineState:self.pxcPipeline];
    [encoder setVertexBuffer:self.pxcParticles offset:0 atIndex:0];
    [encoder setVertexBytes:&u length:sizeof(u) atIndex:1];
    [encoder setFragmentTexture:self.pxcTexture atIndex:0];
    [encoder setFragmentBytes:&u length:sizeof(u) atIndex:1];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4 instanceCount:self.pxcParticleCount];
    [encoder endEncoding];
    dispatch_semaphore_t frames=self.pxcFrames;
    __weak PXCDustOverlay *weak=self;
    BOOL replacePreview=self.pxcPreview!=nil;
    [command addCompletedHandler:^(id<MTLCommandBuffer> b) {
        dispatch_semaphore_signal(frames);
        if (replacePreview) dispatch_async(dispatch_get_main_queue(), ^{
            PXCDustOverlay *s=weak;s.pxcPreview.image=nil;[s.pxcPreview removeFromSuperview];s.pxcPreview=nil;
        });
    }];
    [command presentDrawable:drawable];[command commit];
}
@end

static void PXCDustResolvePending(void) {
    for (PXCDustOverlay *view in gPXCDustOverlays.allObjects) [view pxcStartGPU];
}

static void PXCDustInstallLifecycleObservers(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        [[NSNotificationCenter defaultCenter] addObserverForName:UIDeviceOrientationDidChangeNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) { PXCDustRemoveAll(); }];
    });
}
void PXCDustBeginSession(void) {
    if (!NSThread.isMainThread) { dispatch_async(dispatch_get_main_queue(), ^{ PXCDustBeginSession(); });return; }
    gPXCDustSessions++;
    /* Compile/cache the tiny pipeline before the first tap. Textures and
     * buffers still exist only for real effects. */
    if (PXCSettingsGet().enabled) PXCDustPrepareGPUIfNeeded();
}
void PXCDustEndSession(void) {
    if (!NSThread.isMainThread) { dispatch_async(dispatch_get_main_queue(), ^{ PXCDustEndSession(); });return; }
    if (gPXCDustSessions) gPXCDustSessions--;
    PXCDustDropGPUIfIdle();
}
void PXCDustRemoveAll(void) {
    if (!NSThread.isMainThread) { dispatch_async(dispatch_get_main_queue(), ^{ PXCDustRemoveAll(); });return; }
    for (PXCDustOverlay *view in gPXCDustOverlays.allObjects) [view pxcFinish];
    PXCDustDropGPUIfIdle();
}

static BOOL PXCDustRenderImage(UIImage *image,UIWindow *window,CGRect sourceFrame,BOOL urgent,NSString *label) {
    if (!PXCDustMayStart()) { PXCLog(@"dust skip pressure/concurrency/cooldown");return NO; }
    PXCPerformanceBudget budget=PXCPerformanceGet();
    CGImageRef cg=image.CGImage;
    size_t tw=cg?CGImageGetWidth(cg):0,th=cg?CGImageGetHeight(cg):0;
    if (!tw || !th || tw>budget.textureSide || th>budget.textureSide || tw>SIZE_MAX/(4*th)) return NO;
    PXCSettings settings=PXCSettingsGet();
    NSUInteger density=MIN(settings.density,(NSUInteger)budget.maxDensity);
    NSUInteger limit=MIN((NSUInteger)budget.perEffectParticles,(NSUInteger)budget.totalParticles-gPXCDustParticleCount);
    NSUInteger count=MIN(PXCDustTargetCount(density),limit);
    if (!count || !PXCDustReserveBudget(tw*th*4)) return NO;
    PXCDustOverlay *overlay=nil;
    BOOL transferred=NO;
    @try {
        CGFloat margin=settings.effectStyle==0 ? 180 : MIN(180.0,MAX(sourceFrame.size.width,sourceFrame.size.height)*0.42);
        CGRect frame=CGRectIntersection(CGRectInset(sourceFrame,-margin,-margin),window.bounds);
        if (!PXCDustFiniteRect(frame) || CGRectIsEmpty(frame)) { PXCDustReleaseBudget(tw*th*4);return NO; }
        overlay=[[PXCDustOverlay alloc] initWithFrame:frame];
        if (!overlay) { PXCDustReleaseBudget(tw*th*4);return NO; }
        overlay.opaque=NO;overlay.backgroundColor=UIColor.clearColor;overlay.userInteractionEnabled=NO;
        overlay.accessibilityElementsHidden=YES;overlay.pxcSourceFrame=sourceFrame;overlay.pxcDensity=density;
        overlay.pxcAngle=PXCDustUnit(arc4random())*6.28318530718;
        overlay.pxcPreview=[[UIImageView alloc] initWithImage:image];
        overlay.pxcPreview.frame=CGRectOffset(sourceFrame,-frame.origin.x,-frame.origin.y);
        overlay.pxcPreview.userInteractionEnabled=NO;[overlay addSubview:overlay.pxcPreview];
        PXUniformsGPU u={};u.overlaySize=simd_make_float2(frame.size.width,frame.size.height);
        u.localSize=simd_make_float2(sourceFrame.size.width,sourceFrame.size.height);
        u.sourceOrigin=simd_make_float2(sourceFrame.origin.x-frame.origin.x,sourceFrame.origin.y-frame.origin.y);
        u.basisX=simd_make_float2(1,0);u.basisY=simd_make_float2(0,1);
        u.duration=(float)PXCDustDuration(settings.duration);u.effectStyle=(uint32_t)MIN(settings.effectStyle,(NSUInteger)1)|(urgent?2u:0u);u.flowPhase=PXCDustUnit(arc4random());
        u.flowDirection=simd_make_float2((float)cos(overlay.pxcAngle),(float)sin(overlay.pxcAngle));
        overlay.pxcUniforms=u;overlay.pxcReservedBytes=tw*th*4;overlay.pxcParticleCount=count;
        gPXCDustParticleCount+=count;transferred=YES;
        if (!gPXCDustOverlays) gPXCDustOverlays=[NSMutableSet set];[gPXCDustOverlays addObject:overlay];
        [window addSubview:overlay];gPXCDustLastStart=CACurrentMediaTime();
        PXCDustInstallLifecycleObservers();PXCDustPrepareGPUIfNeeded();[overlay pxcStartGPU];
        __weak PXCDustOverlay *weak=overlay;
        // One-shot preparation timeout; it does not delay or replay deletion.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(1.5*NSEC_PER_SEC)),dispatch_get_main_queue(), ^{
            PXCDustOverlay *s=weak;if (s && !s.pxcMetal) [s pxcFinish];
        });
        PXCLog([NSString stringWithFormat:@"dust accepted class=%@ style=%u",label,u.effectStyle]);
        return !overlay.pxcFinished;
    } @catch (NSException *e) {
        if (transferred) [overlay pxcFinish];else PXCDustReleaseBudget(tw*th*4);
        PXCDustDropGPUIfIdle();PXCLog([@"dust failed safely " stringByAppendingString:e.name]);return NO;
    }
}

static CGFloat PXCDustScaleForSize(CGSize size,CGFloat nativeScale) {
    double w=size.width,h=size.height;
    if (!isfinite(w) || !isfinite(h) || w<2 || h<2 || w>4096 || h>4096) return 0;
    PXCPerformanceBudget budget=PXCPerformanceGet();
    if (!budget.allowed || budget.textureBytes<=16384 || budget.textureSide<=2) return 0;
    double scale=fmin(fmin(nativeScale,1.5),(double)(budget.textureSide-2)/fmax(w,h));
    scale=fmin(scale,sqrt((double)(budget.textureBytes-16384)/(4.0*w*h)));
    return isfinite(scale) && scale>=0.25 ? (CGFloat)scale : 0;
}
BOOL PXCDisintegrateViews(NSArray<UIView *> *views) { return PXCDisintegrateViewsUrgent(views,NO); }
BOOL PXCDisintegrateView(UIView *view) { return PXCDisintegrateViews(view ? @[view] : @[]); }
BOOL PXCDisintegrateViewsUrgent(NSArray<UIView *> *views,BOOL urgent) {
    if (!NSThread.isMainThread || UIAccessibilityIsReduceMotionEnabled() || !PXCSettingsGet().enabled || !views.count || !PXCDustMayStart()) return NO;
    // Notification cells can exceed the screen's content height. Composite only
    // mounted visible platters into one screen-local transparent texture; gaps,
    // clock, wallpaper and our clear button must NOT become dust.
    UIWindow *window=nil;CGRect unionRect=CGRectNull;
    NSMutableArray<UIView *> *sources=[NSMutableArray array];
    NSMutableData *poses=[NSMutableData data];
    for (UIView *v in views) {
        UIWindow *w=nil;PXCDustPose pose;
        if (!PXCDustReadPose(v,&w,&pose,NULL)) continue;
        if (!window) window=w;
        if (w!=window) continue;
        unionRect=CGRectIsNull(unionRect) ? pose.clip : CGRectUnion(unionRect,pose.clip);
        [sources addObject:v];[poses appendBytes:&pose length:sizeof(pose)];
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
            UIView *v=sources[i];
            PXCDustPose pose=((const PXCDustPose *)poses.bytes)[i];CGRect b=pose.bounds;
            PXCPoseTransform mapping;
            if (!PXCPoseTransformMake(b.size.width,b.size.height,pose.origin.x,pose.origin.y,pose.xPoint.x,pose.xPoint.y,pose.yPoint.x,pose.yPoint.y,unionRect.origin.x,unionRect.origin.y,&mapping)) continue;
            CGRect clip=CGRectOffset(pose.clip,-unionRect.origin.x,-unionRect.origin.y);
            CGContextSaveGState(context);CGContextClipToRect(context,clip);
            CGContextConcatCTM(context,CGAffineTransformMake(mapping.a,mapping.b,mapping.c,mapping.d,mapping.tx,mapping.ty));
            BOOL okay=[v drawViewHierarchyInRect:CGRectMake(0,0,b.size.width,b.size.height) afterScreenUpdates:NO];
            if (!okay) {
                CGContextTranslateCTM(context,-b.origin.x,-b.origin.y);
                CALayer *layer=pose.presentation ? (CALayer *)v.layer.presentationLayer : v.layer;
                [layer renderInContext:context];
            }
            CGContextRestoreGState(context);drawn++;
        }
    } @catch (NSException *e) { PXCLog([@"dust composite exception " stringByAppendingString:e.name]); }
    UIImage *image=drawn ? UIGraphicsGetImageFromCurrentImageContext() : nil;
    UIGraphicsEndImageContext();
    if (!image) { PXCLog(@"dust skip composite-empty");return NO; }
    NSString *label=views.count==1 ? NSStringFromClass(views.firstObject.class) : [NSString stringWithFormat:@"notification-batch(%lu)",(unsigned long)drawn];
    return PXCDustRenderImage(image,window,unionRect,urgent,label);
}
