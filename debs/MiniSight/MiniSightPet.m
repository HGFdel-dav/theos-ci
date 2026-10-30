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
@property (nonatomic, strong) CADisplayLink *displayLink;
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
    if (self.displayLink) return;
    self.displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(tick:)];
    [self.displayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    [self setState:MiniSightPetStateIdle];
    [self scheduleRoam];
}

- (void)stopPlaying {
    [self.displayLink invalidate];
    self.displayLink = nil;
    [self.roamTimer invalidate];
    self.roamTimer = nil;
}

- (void)tick:(CADisplayLink *)link {
    if (!self.sheet) return;
    NSTimeInterval dt = link.duration;
    self.frameElapsed += dt;
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
    [self applyFrame];
}

- (void)applyFrame {
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
    self.image = image;
}

#pragma mark - Roaming

- (void)scheduleRoam {
    [self.roamTimer invalidate];
    __weak typeof(self) weakSelf = self;
    NSTimeInterval delay = 2.0 + (arc4random_uniform(300) / 100.0); // 2.0 ~ 5.0s
    self.roamTimer = [NSTimer scheduledTimerWithTimeInterval:delay repeats:NO block:^(NSTimer *timer) {
        [weakSelf roamOnce];
    }];
}

- (void)roamOnce {
    if (!self.window) return;

    uint32_t roll = arc4random_uniform(100);
    if (roll < 55) {
        [self walkRandomly];
    } else if (roll < 80) {
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
