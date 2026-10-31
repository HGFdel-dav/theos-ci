//
//  MiniSightPet.h
//  MiniSight
//
//  Petdex-style animated pet. A 9-row sprite sheet: row 0 idle, 1 run-right,
//  2 run-left, 3 waving, 4 jumping, 5 failed, 6 waiting, 7 running, 8 review.
//  Frame counts/timings follow crafter-station/petdex (MIT).
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface MiniSightPetView : UIImageView

/// sprite: a 9-row sheet (e.g. 1536x1872). displaySize: the on-screen size.
- (instancetype)initWithSprite:(UIImage *)sprite displaySize:(CGSize)displaySize;

- (void)startPlaying;
- (void)stopPlaying;
- (void)setSuspended:(BOOL)suspended;

/// Long-press callback (recording toggle).
@property (nonatomic, copy, nullable) void (^onLongPress)(void);

@end

NS_ASSUME_NONNULL_END
