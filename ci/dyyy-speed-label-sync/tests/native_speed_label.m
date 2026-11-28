#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>
#import <math.h>
#include <stdlib.h>
#include <stdio.h>
// Foundation-only dependencies: no real UIKit, player, device or preferences are used.
@interface TestView : NSObject
@property(nonatomic,strong) id window;
@end
@implementation TestView @end
@interface UIViewController : NSObject
@property(nonatomic,strong) TestView *viewIfLoaded;
@end
@implementation UIViewController @end
@interface AWEAwemeModel : NSObject
@property(nonatomic,copy) NSString *itemID;
@end
@implementation AWEAwemeModel @end
@interface AWEPlayInteractionViewController : UIViewController
@property(nonatomic,strong) AWEAwemeModel *model;
- (void)viewDidLayoutSubviews;
@end
@implementation AWEPlayInteractionViewController @end
@interface FloatingSpeedButton : NSObject
@property(nonatomic,copy) NSString *title;
- (void)setTitle:(NSString *)title forState:(NSUInteger)state;
@end
static NSUInteger gTitleWrites, gOriginalLayouts, gRegistrations, gRefreshes, gChecks;
@implementation FloatingSpeedButton
- (void)setTitle:(NSString *)title forState:(NSUInteger)state { self.title=title; gTitleWrites++; }
@end
static const NSUInteger UIControlStateNormal=0;
FloatingSpeedButton *speedButton;
BOOL showSpeedX=NO;
static __weak AWEAwemeModel *dyyyCurrentSpeedAweme;
static NSString *dyyyLastAutoRestoredSpeedAwemeIdentifier;
static BOOL dyyyLongPressFastSpeedActive, dyyyLongPressLockedSpeedActive;
static AWEPlayInteractionViewController *gCurrent;
static AWEAwemeModel *gRetainedPreviousModel;
static NSArray *gSpeeds;
// In-memory defaults isolate production functions from persistent settings.
@interface TestDefaults : NSObject
@property(nonatomic,strong) NSMutableDictionary *values;
+ (instancetype)standardUserDefaults;
- (BOOL)boolForKey:(NSString *)key;
- (double)doubleForKey:(NSString *)key;
- (NSInteger)integerForKey:(NSString *)key;
- (void)setInteger:(NSInteger)value forKey:(NSString *)key;
@end
@implementation TestDefaults
+ (instancetype)standardUserDefaults { static TestDefaults *d; if (!d) { d=[self new]; d.values=[NSMutableDictionary dictionary]; } return d; }
- (BOOL)boolForKey:(NSString *)key { return [self.values[key] boolValue]; }
- (double)doubleForKey:(NSString *)key { return [self.values[key] doubleValue]; }
- (NSInteger)integerForKey:(NSString *)key { return [self.values[key] integerValue]; }
- (void)setInteger:(NSInteger)value forKey:(NSString *)key { self.values[key]=@(value); }
@end
#define NSUserDefaults TestDefaults
@interface DYYYFloatingButtonCoordinator : NSObject
+ (void)registerInteractionController:(UIViewController *)controller;
+ (void)refresh;
@end
@implementation DYYYFloatingButtonCoordinator
+ (void)registerInteractionController:(UIViewController *)controller { gRegistrations++; }
+ (void)refresh { gRefreshes++; }
@end
id DYYYCurrentSpeedInteractionController(void) { return gCurrent; }
NSArray *getSpeedOptions(void) { return gSpeeds; }
void setCurrentSpeedIndex(NSInteger index);
/* PRODUCTION_EXCERPTS */
#define CHECK(expr) do { gChecks++; if (!(expr)) { fprintf(stderr,"FAIL line %d: %s\n",__LINE__,#expr); abort(); } } while(0)
static AWEAwemeModel *Model(NSString *item) { AWEAwemeModel *m=[AWEAwemeModel new]; m.itemID=item; return m; }
static AWEPlayInteractionViewController *Controller(NSString *item) {
    AWEPlayInteractionViewController *c=[AWEPlayInteractionViewController new]; c.model=Model(item);
    c.viewIfLoaded=[TestView new]; c.viewIfLoaded.window=[NSObject new]; return c;
}
static void Reset(void) {
    [TestDefaults standardUserDefaults].values=[@{@"DYYYEnableFloatSpeedButton":@YES,@"DYYYAutoRestoreSpeed":@YES,@"DYYYDefaultSpeed":@1.0} mutableCopy];
    gSpeeds=@[@"0.75",@"1",@"1.25",@"1.5",@"1.65",@"2",@"2.5",@"3"];
    gCurrent=Controller(@"A"); gRetainedPreviousModel=gCurrent.model;
    dyyyCurrentSpeedAweme=gCurrent.model; dyyyLastAutoRestoredSpeedAwemeIdentifier=@"A";
    dyyyLongPressFastSpeedActive=NO; dyyyLongPressLockedSpeedActive=NO;
    speedButton=[FloatingSpeedButton new]; showSpeedX=NO;
    CHECK(setCurrentSpeedValue(1.65f)); updateSpeedButtonUI(); CHECK([speedButton.title isEqualToString:@"1.65"]);
    gTitleWrites=gOriginalLayouts=gRegistrations=gRefreshes=0;
}
static void Expect(NSString *label, NSString *item) {
    CHECK([speedButton.title isEqualToString:label]);
    CHECK([dyyyLastAutoRestoredSpeedAwemeIdentifier isEqualToString:item]);
}
int main(void) { @autoreleasepool {
    Reset(); [gCurrent viewDidLayoutSubviews]; Expect(@"1.65",@"A"); CHECK(gTitleWrites==0); CHECK(gOriginalLayouts==1);
    Reset(); gCurrent.model=Model(@"B"); [gCurrent viewDidLayoutSubviews]; Expect(@"1",@"B"); CHECK(fabsf(getCurrentSpeed()-1.0f)<0.001f); CHECK(dyyyCurrentSpeedAweme==gCurrent.model); CHECK(gTitleWrites==1);
    CHECK(setCurrentSpeedValue(1.65f)); updateSpeedButtonUI(); NSUInteger writes=gTitleWrites; [gCurrent viewDidLayoutSubviews]; Expect(@"1.65",@"B"); CHECK(gTitleWrites==writes);
    Reset(); [TestDefaults standardUserDefaults].values[@"DYYYAutoRestoreSpeed"]=@NO; gCurrent.model=Model(@"B"); [gCurrent viewDidLayoutSubviews]; CHECK([speedButton.title isEqualToString:@"1.65"]); CHECK(!dyyyLastAutoRestoredSpeedAwemeIdentifier);
    Reset(); [TestDefaults standardUserDefaults].values[@"DYYYEnableFloatSpeedButton"]=@NO; gCurrent.model=Model(@"B"); [gCurrent viewDidLayoutSubviews]; CHECK([speedButton.title isEqualToString:@"1.65"]);
    Reset(); [TestDefaults standardUserDefaults].values[@"DYYYDefaultSpeed"]=@1.5; gCurrent.model=Model(@"B"); [gCurrent viewDidLayoutSubviews]; Expect(@"1.5",@"B");
    Reset(); [TestDefaults standardUserDefaults].values[@"DYYYDefaultSpeed"]=@1.65; gCurrent.model=Model(@"B"); [gCurrent viewDidLayoutSubviews]; Expect(@"1.65",@"B");
    Reset(); gCurrent.model=Model(@"B"); gCurrent.viewIfLoaded.window=nil; [gCurrent viewDidLayoutSubviews]; Expect(@"1.65",@"A"); CHECK(gRegistrations==0);
    Reset(); AWEPlayInteractionViewController *preload=Controller(@"B"); [preload viewDidLayoutSubviews]; Expect(@"1.65",@"A"); CHECK(dyyyCurrentSpeedAweme==gCurrent.model);
    Reset(); AWEPlayInteractionViewController *inactive=Controller(@"B"); gCurrent=nil; [inactive viewDidLayoutSubviews]; Expect(@"1.65",@"A"); CHECK(gTitleWrites==0);
    Reset(); dyyyLongPressFastSpeedActive=YES; gCurrent.model=Model(@"A"); [gCurrent viewDidLayoutSubviews]; Expect(@"1.65",@"A"); CHECK(dyyyLongPressFastSpeedActive);
    Reset(); dyyyLongPressFastSpeedActive=YES; dyyyLongPressLockedSpeedActive=YES; gCurrent.model=Model(@"B"); [gCurrent viewDidLayoutSubviews]; Expect(@"1",@"B"); CHECK(!dyyyLongPressFastSpeedActive); CHECK(!dyyyLongPressLockedSpeedActive);
    Reset(); dyyyLongPressLockedSpeedActive=YES; [gCurrent viewDidLayoutSubviews]; Expect(@"1.65",@"A"); CHECK(dyyyLongPressLockedSpeedActive);
    Reset(); gCurrent.model=Model(@"B"); [gCurrent viewDidLayoutSubviews]; gCurrent.model=Model(@"C"); [gCurrent viewDidLayoutSubviews]; Expect(@"1",@"C"); CHECK(gTitleWrites==2);
    Reset(); showSpeedX=YES; gCurrent.model=Model(@"B"); [gCurrent viewDidLayoutSubviews]; Expect(@"1x",@"B");
    printf("PASS production-excerpt speed-label scenarios=15 assertions=%lu\n",(unsigned long)gChecks);
} return 0; }
