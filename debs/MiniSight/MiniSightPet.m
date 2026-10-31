//
//  MiniSightPet.m
//  MiniSight
//
//  Sprite playback + light roaming. The sheet is 9 rows; each row is one
//  state (idle / run-right / run-left / waving / jumping / ...). Frames are
//  cropped out of the sheet with CGImageCreateWithImageInRect and swapped on
//  a CADisplayLink, so no per-frame image assets are needed.
//

#import "MiniSightPet.h"
#import <stdlib.h>
#import <math.h>

extern BOOL gMiniSightBurst;
extern void MiniSightFollowBubble(void);

typedef NS_ENUM(NSInteger, MiniSightPetState) {
    MiniSightPetStateIdle = 0,
    MiniSightPetStateRunRight = 1,
    MiniSightPetStateRunLeft = 2,
    MiniSightPetStateWaving = 3,
    MiniSightPetStateJumping = 4,
    MiniSightPetStateFailed = 5,
    MiniSightPetStateWaiting = 6,
    MiniSightPetStateRunning = 7,
    MiniSightPetStateReview = 8,
};

static const NSInteger kMiniSightPetRows = 9;
static const NSInteger kMiniSightPetMaxCols = 8;

@interface MiniSightPetView ()
@property (nonatomic, strong) UIImage *sheet;
@property (nonatomic, assign) NSInteger row;
@property (nonatomic, assign) NSInteger col;
@property (nonatomic, assign) NSTimeInterval frameElapsed;
@property (nonatomic, assign) NSTimeInterval frameDuration;
@property (nonatomic, strong) NSTimer *frameTimer;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, UIImage *> *frameCache;
@property (nonatomic, assign) BOOL suspended;
@property (nonatomic, assign) NSTimeInterval extraRest;
@property (nonatomic, assign) NSTimeInterval tickInterval;
@property (nonatomic, strong) NSTimer *roamTimer;
@property (nonatomic, assign) CGSize displaySize;
@property (nonatomic, assign) BOOL roaming;
@end

@implementation MiniSightPetView

- (instancetype)initWithSprite:(UIImage *)sprite displaySize:(CGSize)displaySize {
    self = [super initWithFrame:CGRectMake(0, 0, displaySize.width, displaySize.height)];
    if (self) {
        _sheet = sprite;
        _displaySize = displaySize;
        self.contentMode = UIViewContentModeScaleAspectFit;
        self.userInteractionEnabled = YES;
        _row = MiniSightPetStateIdle;
        _col = 0;
        _frameDuration = 0.16;
        _frameCache = [NSMutableDictionary dictionary];
        _tickInterval = 0.1;
        [self applyFrame];

        UILongPressGestureRecognizer *press =
            [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(handleLongPress:)];
        press.minimumPressDuration = 0.9;
        [self addGestureRecognizer:press];
    }
    return self;
}

#pragma mark - Playback

- (void)startPlaying {
    if (self.frameTimer) { _suspended = NO; return; }
    _suspended = NO;   // 直接写 ivar：走 setter 会再调回本方法，无限递归
    // 10 Hz 定时器代替 60 Hz 的 CADisplayLink：动画只要 6~8 帧/秒，
    // 多出来的 50 次回调纯耗电。
    self.frameTimer = [NSTimer scheduledTimerWithTimeInterval:self.tickInterval
                                                       target:self
                                                     selector:@selector(tick:)
                                                     userInfo:nil
                                                      repeats:YES];
    self.frameTimer.tolerance = 0.03;
    [self setState:MiniSightPetStateIdle];
    [self scheduleRoam];
}

- (void)stopPlaying {
    [self.frameTimer invalidate];
    self.frameTimer = nil;
    [self.roamTimer invalidate];
    self.roamTimer = nil;
    self.suspended = YES;
}

/// 屏幕熄灭/被盖住时暂停，回来再续。
- (void)setSuspended:(BOOL)suspended {
    _suspended = suspended;
    if (suspended) {
        [self.frameTimer invalidate];
        self.frameTimer = nil;
        [self.roamTimer invalidate];
        self.roamTimer = nil;
    } else if (!self.frameTimer && self.sheet) {
        [self startPlaying];
    }
}

/// 只在真正走动时提到 20 帧，站着还是 10 帧。
- (void)syncTimerRate {
    NSTimeInterval want = (self.row == MiniSightPetStateRunRight ||
                           self.row == MiniSightPetStateRunLeft ||
                           self.row == MiniSightPetStateJumping) ? 0.05 : 0.1;
    if (fabs(want - self.tickInterval) < 0.001) return;
    self.tickInterval = want;
    if (!self.frameTimer) return;
    [self.frameTimer invalidate];
    self.frameTimer = [NSTimer scheduledTimerWithTimeInterval:want
                                                       target:self
                                                     selector:@selector(tick:)
                                                     userInfo:nil
                                                      repeats:YES];
    self.frameTimer.tolerance = 0.02;
}

- (void)tick:(NSTimer *)timer {
    if (!self.sheet || self.suspended || !self.window) return;
    [self keepInside];
    MiniSightFollowBubble();
    self.frameElapsed += timer.timeInterval;
    if (self.frameElapsed < self.frameDuration) return;
    self.frameElapsed = 0;

    NSInteger count = [self frameCountForRow:self.row];
    self.col = (self.col + 1) % MAX(count, 1);
    [self applyFrame];
}

- (NSInteger)frameCountForRow:(NSInteger)row {
    static NSInteger counts[9] = {6, 8, 8, 4, 5, 8, 6, 6, 6};
    if (row < 0 || row >= 9) return 1;
    return counts[row];
}

- (void)setState:(MiniSightPetState)state {
    self.row = state;
    self.col = 0;
    self.frameElapsed = 0;
    // Idle breathes slowly; a run/jump is quicker.
    self.frameDuration = (state == MiniSightPetStateIdle) ? 0.16 : 0.12;
    [self syncTimerRate];
    [self applyFrame];
}

- (void)applyFrame {
    UIImage *cached = self.frameCache[@(self.row * 16 + self.col)];
    if (cached) { self.image = cached; return; }
    CGImageRef sheetRef = self.sheet.CGImage;
    if (!sheetRef) return;

    CGFloat w = CGImageGetWidth(sheetRef);
    CGFloat h = CGImageGetHeight(sheetRef);
    CGFloat frameW = w / (CGFloat)kMiniSightPetMaxCols;
    CGFloat frameH = h / (CGFloat)kMiniSightPetRows;

    CGRect rect = CGRectMake(frameW * self.col, frameH * self.row, frameW, frameH);
    CGImageRef frame = CGImageCreateWithImageInRect(sheetRef, rect);
    if (!frame) return;

    UIImage *image = [UIImage imageWithCGImage:frame scale:self.sheet.scale orientation:UIImageOrientationUp];
    CGImageRelease(frame);
    if (self.frameCache.count < 32) self.frameCache[@(self.row * 16 + self.col)] = image;
    self.image = image;
}

#pragma mark - Roaming

- (void)scheduleRoam {
    [self.roamTimer invalidate];
    __weak typeof(self) weakSelf = self;
    // 调用期间活泼一点；常驻且空闲时 9~15 秒动一次就够。
    // 调用期间活泼一点；常驻且空闲时 9~15 秒动一次就够。
    NSTimeInterval delay = gMiniSightBurst ? (2.0 + arc4random_uniform(300) / 100.0)
                                           : (9.0 + arc4random_uniform(600) / 100.0);
    delay += self.extraRest;
    self.extraRest = 0;
    self.roamTimer = [NSTimer scheduledTimerWithTimeInterval:delay repeats:NO block:^(NSTimer *timer) {
        [weakSelf roamOnce];
    }];
}

/// 目标点必须整个身子留在屏内
- (CGPoint)clampPoint:(CGPoint)p {
    UIView *parent = self.superview;
    if (!parent) return p;
    CGFloat halfW = self.bounds.size.width / 2, halfH = self.bounds.size.height / 2;
    CGFloat minX = 8 + halfW, maxX = parent.bounds.size.width - 8 - halfW;
    CGFloat minY = 30 + halfH, maxY = parent.bounds.size.height - 20 - halfH;
    if (maxX < minX) return CGPointMake(parent.bounds.size.width / 2, p.y);
    if (maxY < minY) return CGPointMake(p.x, parent.bounds.size.height / 2);
    return CGPointMake(MIN(MAX(p.x, minX), maxX), MIN(MAX(p.y, minY), maxY));
}

/// 万一被动画/旋转带出界，直接夹回来
- (void)keepInside {
    CGPoint c = self.center, k = [self clampPoint:c];
    if (fabs(c.x - k.x) > 0.5 || fabs(c.y - k.y) > 0.5) self.center = k;
}

- (CGRect)roamArea {
    UIView *parent = self.superview;
    if (!parent) return CGRectZero;
    CGFloat halfW = self.bounds.size.width / 2, halfH = self.bounds.size.height / 2;
    CGFloat top = 34 + halfH, bottom = parent.bounds.size.height - 24 - halfH;
    CGFloat left = 12 + halfW, right = parent.bounds.size.width - 12 - halfW;
    if (right <= left || bottom <= top) return CGRectZero;
    return CGRectMake(left, top, right - left, bottom - top);
}

/// 走到任意一点（不只是左右），距离越远走得越久。
- (void)walkTo:(CGPoint)target {
    target = [self clampPoint:target];
    BOOL right = target.x > self.center.x;
    [self setState:right ? MiniSightPetStateRunRight : MiniSightPetStateRunLeft];
    CGFloat dist = hypot(target.x - self.center.x, target.y - self.center.y);
    NSTimeInterval duration = MIN(2.2, MAX(0.7, dist / 160.0));
    __weak typeof(self) weakSelf = self;
    [UIView animateWithDuration:duration
                          delay:0
                        options:UIViewAnimationOptionCurveEaseInOut | UIViewAnimationOptionBeginFromCurrentState
                     animations:^{ weakSelf.center = target; }
                     completion:^(BOOL finished) {
        [weakSelf keepInside];
        [weakSelf setState:MiniSightPetStateIdle];
        [weakSelf scheduleRoam];
    }];
}

- (void)walkToRandomPoint {
    CGRect area = [self roamArea];
    if (CGRectIsEmpty(area)) { [self scheduleRoam]; return; }
    CGPoint p = CGPointMake(area.origin.x + arc4random_uniform((uint32_t)area.size.width),
                            area.origin.y + arc4random_uniform((uint32_t)area.size.height));
    [self walkTo:p];
}

/// 偶尔跑到某个角落待一会儿，像真的在找地方窝着。
- (void)goCorner {
    CGRect area = [self roamArea];
    if (CGRectIsEmpty(area)) { [self scheduleRoam]; return; }
    CGFloat x = (arc4random_uniform(2) ? CGRectGetMinX(area) : CGRectGetMaxX(area));
    CGFloat y = (arc4random_uniform(2) ? CGRectGetMinY(area) : CGRectGetMaxY(area));
    self.extraRest = 2.5 + arc4random_uniform(250) / 100.0;   // 到角落多待一会儿
    [self walkTo:CGPointMake(x, y)];
}

- (void)roamOnce {
    if (!self.window || self.suspended) return;

    uint32_t roll = arc4random_uniform(100);
    if (roll < 38) {
        [self walkRandomly];
    } else if (roll < 60) {
        [self walkToRandomPoint];
    } else if (roll < 72) {
        [self goCorner];
    } else if (roll < 88) {
        [self jump];
    } else {
        [self setState:MiniSightPetStateWaving];
        __weak typeof(self) weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [weakSelf setState:MiniSightPetStateIdle];
            [weakSelf scheduleRoam];
        });
        return;
    }
}

- (void)walkRandomly {
    UIView *parent = self.superview;
    if (!parent) return;

    CGFloat minX = 12 + self.bounds.size.width / 2;
    CGFloat maxX = parent.bounds.size.width - 12 - self.bounds.size.width / 2;
    if (maxX <= minX) { [self scheduleRoam]; return; }

    CGFloat targetX = minX + (CGFloat)arc4random_uniform((uint32_t)MAX(maxX - minX, 1.0));
    BOOL right = targetX > self.center.x;
    [self setState:right ? MiniSightPetStateRunRight : MiniSightPetStateRunLeft];

    NSTimeInterval duration = 0.8 + (arc4random_uniform(80) / 100.0);
    __weak typeof(self) weakSelf = self;
    [UIView animateWithDuration:duration
                          delay:0
                        options:UIViewAnimationOptionCurveEaseInOut | UIViewAnimationOptionBeginFromCurrentState
                     animations:^{
        CGPoint c = weakSelf.center;
        c.x = targetX;
        weakSelf.center = c;
    } completion:^(BOOL finished) {
        [weakSelf setState:MiniSightPetStateIdle];
        [weakSelf scheduleRoam];
    }];
}

- (void)jump {
    [self setState:MiniSightPetStateJumping];
    CGPoint origin = self.center;
    __weak typeof(self) weakSelf = self;
    [UIView animateWithDuration:0.22
                          delay:0
                        options:UIViewAnimationOptionCurveEaseOut
                     animations:^{
        CGPoint c = weakSelf.center;
        c.y -= 26;
        weakSelf.center = c;
    } completion:^(BOOL finished) {
        [UIView animateWithDuration:0.24
                              delay:0
                            options:UIViewAnimationOptionCurveEaseIn
                         animations:^{
            weakSelf.center = origin;
        } completion:^(BOOL finished2) {
            [weakSelf setState:MiniSightPetStateIdle];
            [weakSelf scheduleRoam];
        }];
    }];
}

#pragma mark - Gesture

- (void)handleLongPress:(UILongPressGestureRecognizer *)press {
    if (press.state != UIGestureRecognizerStateBegan) return;
    UIImpactFeedbackGenerator *feedback =
        [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
    [feedback impactOccurred];
    if (self.onLongPress) self.onLongPress();
}

@end
