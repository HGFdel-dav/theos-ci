#import "TWContainerActionsPrefs.h"
#import "TWPrefs.h"
#import "TWPath.h"
#import "TWPXPrefs.h"
#import <UIKit/UIKit.h>
#import <objc/message.h>

static NSArray *TWCPArray(id value) { return [value isKindOfClass:NSArray.class] ? value : @[]; }
static BOOL TWCPOwned(id item) {
    return [item isKindOfClass:NSDictionary.class] && [item[@"twOwner"] isEqual:@"com.niubiprass.twin.container"];
}
static BOOL TWCPID(id item) { return [item isKindOfClass:NSString.class] && [item hasPrefix:@"px.custom.twin-container."]; }
static NSString *TWCPName(NSString *bid, NSString *cid, NSDictionary *cache) {
    for (id app in TWCPArray(cache[@"apps"])) {
        if (![app isKindOfClass:NSDictionary.class] || ![app[@"bundleID"] isEqual:bid]) continue;
        for (id row in TWCPArray(app[@"containers"]))
            if ([row isKindOfClass:NSDictionary.class] && [row[@"id"] isEqual:cid] && [row[@"name"] isKindOfClass:NSString.class]) return row[@"name"];
    }
    return [cid isEqual:@"DEFAULT"] ? @"默认" : cid;
}
static NSData *TWCPBadgeIcon(NSString *bid, NSString *cid, NSUInteger index) {
    SEL sel = NSSelectorFromString(@"_applicationIconImageForBundleIdentifier:format:scale:");
    UIImage *icon = [UIImage respondsToSelector:sel] ? ((id (*)(id, SEL, id, long, double))objc_msgSend)(UIImage.class, sel, bid, 0, (double)UIScreen.mainScreen.scale) : nil;
    if (![icon isKindOfClass:UIImage.class]) return nil;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(64, 64)];
    UIImage *image = [renderer imageWithActions:^(__unused UIGraphicsImageRendererContext *context) {
        [icon drawInRect:CGRectMake(0, 0, 64, 64)];
        [[UIColor systemPurpleColor] setFill];
        [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(38, 38, 26, 26) cornerRadius:9] fill];
        NSString *badge = [cid isEqual:@"DEFAULT"] ? @"默" : [NSString stringWithFormat:@"%lu", (unsigned long)index];
        [badge drawInRect:CGRectMake(39, 41, 24, 22) withAttributes:@{NSFontAttributeName:[UIFont boldSystemFontOfSize:15], NSForegroundColorAttributeName:UIColor.whiteColor}];
    }];
    return UIImagePNGRepresentation(image);
}
BOOL TWPublishContainerActions(void) {
    TWPrefs *prefs = TWPrefs.shared;
    TWPXPrefs *px = [[TWPXPrefs alloc] init];
    id rawOrder = [prefs objectForKey:TWKeyCraneAppList];
    NSArray *order = TWCPArray(rawOrder);
    if (![rawOrder isKindOfClass:NSArray.class]) {
        NSMutableOrderedSet *migrated = [NSMutableOrderedSet orderedSet];
        for (id item in TWCPArray([px objectForKey:@"applications" defaultValue:nil]))
            if ([item isKindOfClass:NSString.class] && ![item hasPrefix:@"px."]) [migrated addObject:item];
        order = migrated.array;
        [prefs setObject:order forKey:TWKeyCraneAppList]; [prefs synchronize];
    }
    NSArray *containers = TWCPArray([prefs objectForKey:TWKeyCraneContainers]);
    BOOL crane = [prefs boolForKey:TWKeyCraneEnabled defaultValue:YES];
    NSMutableDictionary<NSString *, NSMutableArray *> *byApp = [NSMutableDictionary dictionary];
    for (id row in containers) {
        if (![row isKindOfClass:NSDictionary.class]) continue;
        NSString *bid = row[@"bundleID"], *cid = row[@"containerID"];
        if (![bid isKindOfClass:NSString.class] || !bid.length) continue;
        if (![cid isKindOfClass:NSString.class] || !cid.length) cid = @"DEFAULT";
        if (!byApp[bid]) byApp[bid] = [NSMutableArray array];
        // Keep empty groups: all disabled must not reappear as a normal app.
        if (!row[@"enabled"] || [row[@"enabled"] boolValue]) [byApp[bid] addObject:@{@"cid":cid, @"name":row[@"name"] ?: bid}];
    }
    NSMutableArray *actions = [NSMutableArray array];
    for (id item in TWCPArray([px objectForKey:@"customActions" defaultValue:nil])) if (!TWCPOwned(item)) [actions addObject:item];
    NSMutableArray *selection = [NSMutableArray array];
    id rawImages = [px objectForKey:@"shortcutImages" defaultValue:nil];
    NSMutableDictionary *images = [rawImages isKindOfClass:NSDictionary.class] ? [rawImages mutableCopy] : [NSMutableDictionary dictionary];
    // Original runtime 0x55f00..0x560c4 consumes [id: NSData] and UIImage(data:).
    for (id key in images.allKeys) if (TWCPID(key)) [images removeObjectForKey:key];
    // Preserve non-Twin system tools / workflows / URLs. App order follows the one shared list.
    for (id item in TWCPArray([px objectForKey:@"applications" defaultValue:nil])) {
        if ([item isKindOfClass:NSString.class] && [item hasPrefix:@"px."] && !TWCPID(item)) [selection addObject:item];
    }
    NSDictionary *cache = [NSDictionary dictionaryWithContentsOfFile:@"/var/mobile/Library/Twin/crane-containers.plist"] ?: @{};
    NSMutableSet *seen = [NSMutableSet set];
    for (id raw in order) {
        if (![raw isKindOfClass:NSString.class] || ![raw length] || [seen containsObject:raw]) continue;
        [seen addObject:raw];
        NSArray *rows = byApp[raw];
        if (!crane || !rows) { [selection addObject:raw]; continue; }
        NSUInteger containerIndex = 0;
        for (NSDictionary *row in rows) {
            containerIndex++;
            NSString *cid = row[@"cid"];
            // Stable, reversible pair encoding; '.' does not occur in base64.
            NSString *(^encode)(NSString *) = ^NSString *(NSString *s) { return [[s dataUsingEncoding:NSUTF8StringEncoding] base64EncodedStringWithOptions:0]; };
            NSString *identifier = [NSString stringWithFormat:@"px.custom.twin-container.%@.%@", encode(raw), encode(cid)];
            NSString *name = [NSString stringWithFormat:@"%@ · %@", row[@"name"], TWCPName(raw, cid, cache)];
            [actions addObject:@{@"id":identifier, @"title":name, @"kind":@"twin.container", @"app":raw,
                @"twContainerID":cid, @"twOwner":@"com.niubiprass.twin.container"}];
            NSData *icon = TWCPBadgeIcon(raw, cid, containerIndex);
            if (icon) images[identifier] = icon;
            [selection addObject:identifier];
        }
    }
    if (![px setObject:actions forKey:@"customActions"]) return NO;
    if (![px setObject:images forKey:@"shortcutImages"]) return NO;
    if (![px setObject:selection forKey:@"applications"]) return NO;
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
        CFSTR("com.moxuan.parallelx.handle-updated"), NULL, NULL, YES);
    return YES;
}
