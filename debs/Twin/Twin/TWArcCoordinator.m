// TWArcCoordinator.m
#import "TWArcCoordinator.h"
#import "TWArcMenuView.h"
#import "TWArcGeometry.h"
#import "TWPrefs.h"
#import "TWCraneBridge.h"
#import <AudioToolbox/AudioServices.h>
#import <objc/message.h>

@implementation TWArcCoordinator {
    UIPanGestureRecognizer *_pan;
    TWArcMenuView *_menu;
    CGPoint _startPoint;
    BOOL _tracking;
    BOOL _didPresent;
    BOOL _started;
    NSArray<NSString *> *_cachedBundleIDs;
}

+ (instancetype)sharedInstance {
    static TWArcCoordinator *instance;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ instance = [[self alloc] init]; });
    return instance;
}

- (instancetype)init {
    if ((self = [super init])) {
        _cachedBundleIDs = @[];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(refreshEnabledState)
                                                     name:UIApplicationDidBecomeActiveNotification object:nil];
    }
    return self;
}

#pragma mark - lifecycle

- (void)start {
    if (_started) return;
    _started = YES;
    [self attachRecognizer];
    // attach may have been too early (no window yet); retry briefly.
    if (!_pan) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self attachRecognizer];
        });
    }
}

// Tapping the status bar or system gestures must keep working; we only own
// a thin strip along the chosen edge, outside the top/bottom system zones.
- (void)attachRecognizer {
    if (_pan) return;
    UIWindow *window = nil;
    NSArray *windows = [UIApplication sharedApplication].windows;
    for (UIWindow *w in windows) {
        if (w.isKeyWindow || w.windowLevel == UIWindowLevelNormal) { window = w; break; }
    }
    if (!window) window = [UIApplication sharedApplication].keyWindow;
    if (!window) return;
    _pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
    _pan.delegate = self;
    _pan.maximumNumberOfTouches = 1;
    _pan.cancelsTouchesInView = NO;
    [window addGestureRecognizer:_pan];
}

- (void)refreshEnabledState {
    [[TWPrefs shared] reload]; // SpringBoard returned to foreground
}

#pragma mark - gesture delegate

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)recognizer {
    [[TWPrefs shared] reload]; // pick up changes made in Settings while SB was backgrounded
    if (![[TWPrefs shared] boolForKey:TWKeyEnabled defaultValue:NO]) return NO;
    if (![[TWPrefs shared] boolForKey:TWKeyArcEnabled defaultValue:YES]) return NO;
    // lock screen / cover sheet: let the system handle touches
    Class lsClass = NSClassFromString(@"SBLockScreenManager");
    if (lsClass) {
        id (*msg)(id, SEL, ...) = (id (*)(id, SEL, ...))objc_msgSend;
        id shared = msg(lsClass, NSSelectorFromString(@"sharedInstance"));
        if (shared) {
            id locked = msg(shared, NSSelectorFromString(@"isLocked"));
            if ([locked boolValue]) return NO;
        }
    }
    UIView *view = recognizer.view;
    CGPoint p = [recognizer locationInView:view];
    NSInteger side = [[TWPrefs shared] integerForKey:TWKeyArcSide defaultValue:0];
    CGFloat width = [[TWPrefs shared] floatForKey:TWKeyArcTriggerWidth defaultValue:24];
    return [TWArcGeometry point:p inTriggerRegionForSide:side width:width bounds:view.bounds];
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    return NO;
}

#pragma mark - pan handling

- (void)handlePan:(UIPanGestureRecognizer *)pan {
    CGPoint p = [pan locationInView:pan.view];
    switch (pan.state) {
        case UIGestureRecognizerStateBegan: {
            _startPoint = p;
            _tracking = NO;
            _didPresent = NO;
            break;
        }
        case UIGestureRecognizerStateChanged: {
            if (!_tracking) {
                CGFloat dx = p.x - _startPoint.x, dy = p.y - _startPoint.y;
                CGFloat dist = sqrt(dx * dx + dy * dy);
                if (dist >= 22) {
                    _tracking = YES;
                    [self presentMenuFromPoint:_startPoint];
                }
            }
            if (_tracking) [_menu updateSelectionAtPoint:p];
            break;
        }
        case UIGestureRecognizerStateEnded: {
            if (_tracking) {
                NSString *selected = [_menu finishSelectionAtPoint:p];
                if (selected.length) [self launchBundleID:selected];
            }
            _tracking = NO;
            _didPresent = NO;
            break;
        }
        case UIGestureRecognizerStateCancelled:
        case UIGestureRecognizerStateFailed: {
            if (_tracking) [_menu dismissAnimated:YES];
            _tracking = NO;
            _didPresent = NO;
            break;
        }
        default: break;
    }
}

- (void)presentMenuFromPoint:(CGPoint)point {
    if (_didPresent) return;
    _didPresent = YES;
    UIWindow *window = (UIWindow *)_pan.view; // the recognizer is attached to the SB window
    if (!_menu) {
        _menu = [[TWArcMenuView alloc] initWithFrame:window.bounds];
        _menu.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    } else {
        _menu.frame = window.bounds;
    }
    [window addSubview:_menu];

    NSArray *bundleIDs = [self recentBundleIDs];
    NSInteger side = [[TWPrefs shared] integerForKey:TWKeyArcSide defaultValue:0];
    CGFloat radius = [[TWPrefs shared] floatForKey:TWKeyArcRadius defaultValue:140];
    NSInteger count = [[TWPrefs shared] integerForKey:TWKeyArcItemCount defaultValue:6];
    count = MAX(2, MIN(8, count));
    if (bundleIDs.count > (NSUInteger)count) bundleIDs = [bundleIDs subarrayWithRange:NSMakeRange(0, (NSUInteger)count)];
    [_menu presentFromTriggerPoint:point bundleIDs:bundleIDs side:side radius:radius menuScale:1.0];
    if ([[TWPrefs shared] boolForKey:TWKeyArcSound defaultValue:YES]) {
        AudioServicesPlaySystemSound(1104);
    }
}

#pragma mark - app launching

- (void)launchBundleID:(NSString *)bundleID {
    if ([[TWPrefs shared] boolForKey:TWKeyArcSound defaultValue:YES]) {
        AudioServicesPlaySystemSound(1519);
    }
    // ParallelX (if installed): open through its panel entry so the app comes
    // up inside the split window. Otherwise fall back to a normal launch.
    Class pxEntry = NSClassFromString(@"PXPanelEntry");
    if (pxEntry && [pxEntry respondsToSelector:NSSelectorFromString(@"applicationActivated:")]) {
        void (*msg)(id, SEL, id) = (void (*)(id, SEL, id))objc_msgSend;
        msg(pxEntry, NSSelectorFromString(@"applicationActivated:"), bundleID);
    } else {
        [TWCraneBridge applyContainerIfConfiguredForBundleID:bundleID];
        id (*msg)(id, SEL, id, id) = (id (*)(id, SEL, id, id))objc_msgSend;
        msg([UIApplication sharedApplication],
            NSSelectorFromString(@"launchApplicationWithIdentifier:suspended:"),
            bundleID, @(NO));
    }
}

#pragma mark - recent apps

- (NSArray<NSString *> *)recentBundleIDs {
    NSMutableArray *ids = [NSMutableArray array];
    // SpringBoard switcher: most recently used apps first.
    Class switcherClass = NSClassFromString(@"SBMainSwitcherViewController");
    if (switcherClass) {
        id (*msg)(id, SEL, ...) = (id (*)(id, SEL, ...))objc_msgSend;
        id shared = msg(switcherClass, NSSelectorFromString(@"sharedInstance"));
        id layouts = shared ? msg(shared, NSSelectorFromString(@"recentAppLayouts")) : nil;
        if ([layouts isKindOfClass:[NSArray class]]) {
            for (id layout in layouts) {
                id items = [layout valueForKey:@"allItems"];
                if (![items isKindOfClass:[NSArray class]]) continue;
                for (id item in items) {
                    NSString *bundleID = [item valueForKey:@"bundleIdentifier"];
                    if ([bundleID isKindOfClass:[NSString class]] && bundleID.length && ![ids containsObject:bundleID]) {
                        [ids addObject:bundleID];
                    }
                }
            }
        }
    }
    // Fallback: installed user apps (ordered by localized name).
    if (ids.count < 4) {
        Class workspaceClass = NSClassFromString(@"LSApplicationWorkspace");
        if (workspaceClass) {
            id (*msg)(id, SEL, ...) = (id (*)(id, SEL, ...))objc_msgSend;
            id workspace = msg(workspaceClass, NSSelectorFromString(@"defaultWorkspace"));
            id apps = workspace ? msg(workspace, NSSelectorFromString(@"allApplications")) : nil;
            if ([apps isKindOfClass:[NSArray class]]) {
                NSMutableArray *extras = [NSMutableArray array];
                for (id proxy in apps) {
                    NSString *bundleID = [proxy valueForKey:@"bundleIdentifier"];
                    NSString *name = [proxy valueForKey:@"localizedName"];
                    if (![bundleID isKindOfClass:[NSString class]] || !bundleID.length) continue;
                    if ([bundleID hasPrefix:@"com.apple."]) continue; // skip most system apps
                    [extras addObject:@{@"id": bundleID, @"name": (name ?: bundleID)}];
                }
                [extras sortUsingComparator:^NSComparisonResult(id a, id b) {
                    return [a[@"name"] localizedCaseInsensitiveCompare:b[@"name"]];
                }];
                for (NSDictionary *entry in extras) {
                    if (ids.count >= 8) break;
                    if (![ids containsObject:entry[@"id"]]) [ids addObject:entry[@"id"]];
                }
            }
        }
    }
    return ids;
}

@end