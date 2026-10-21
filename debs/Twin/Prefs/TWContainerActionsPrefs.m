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
    // The engine's `applications` list drives the side panel. It must contain
    // application identifiers only: injecting one row per container flooded
    // the panel, forced a second page and broke its ring layout.
    TWPrefs *prefs = TWPrefs.shared;
    TWPXPrefs *px = [[TWPXPrefs alloc] init];
    id rawOrder = [prefs objectForKey:TWKeyCraneAppList];
    if (![rawOrder isKindOfClass:NSArray.class]) return NO;
    // Container rows are published as regular engine actions so both wake
    // methods show the same entries; the ring capacity limits keep the panel
    // from overflowing into a second page.
    NSArray *containers = TWCPArray([prefs objectForKey:TWKeyCraneContainers]);
    BOOL crane = [prefs boolForKey:TWKeyCraneEnabled defaultValue:YES];
    NSMutableDictionary<NSString *, NSMutableArray *> *byApp = [NSMutableDictionary dictionary];
    for (id row in containers) {
        if (![row isKindOfClass:NSDictionary.class]) continue;
        NSString *bid = row[@"bundleID"], *cid = row[@"containerID"];
        if (![bid isKindOfClass:NSString.class] || !bid.length) continue;
        if (![cid isKindOfClass:NSString.class] || !cid.length) cid = @"DEFAULT";
        if (row[@"enabled"] && ![row[@"enabled"] boolValue]) continue;
        if (!byApp[bid]) byApp[bid] = [NSMutableArray array];
        [byApp[bid] addObject:@{@"cid":cid, @"name":row[@"name"] ?: bid}];
    }
    NSMutableArray *actions = [NSMutableArray array];
    for (id item in TWCPArray([px objectForKey:@"customActions" defaultValue:nil])) if (!TWCPOwned(item)) [actions addObject:item];
    NSDictionary *cache = [NSDictionary dictionaryWithContentsOfFile:@"/var/mobile/Library/Twin/crane-containers.plist"] ?: @{};
    NSMutableArray *selection = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];
    for (id item in TWCPArray([px objectForKey:@"applications" defaultValue:nil])) {
        if (![item isKindOfClass:NSString.class] || !item.length || [seen containsObject:item]) continue;
        if (TWCPID(item)) continue;
        // Only the built-in system actions belong in the menu; URL shortcuts
        // and custom actions are edited on their own pages. Keeping them here
        // pushed the menu to 52 entries (raw px.url.* identifiers) and forced
        // the panel onto a second page.
        if ([item hasPrefix:@"px.action."] || [(NSArray *)rawOrder containsObject:item]) {
            [seen addObject:item];
            [selection addObject:item];
        }
    }
    for (id raw in (NSArray *)rawOrder) {
        if (![raw isKindOfClass:NSString.class] || ![raw length] || [seen containsObject:raw]) continue;
        [seen addObject:raw];
        NSArray *rows = crane ? byApp[raw] : nil;
        if (!rows.count) { [selection addObject:raw]; continue; }
        for (NSDictionary *row in rows) {
            NSString *cid = row[@"cid"];
            NSString *(^encode)(NSString *) = ^NSString *(NSString *s) { return [[s dataUsingEncoding:NSUTF8StringEncoding] base64EncodedStringWithOptions:0]; };
            NSString *identifier = [NSString stringWithFormat:@"px.custom.twin-container.%@.%@", encode(raw), encode(cid)];
            [actions addObject:@{@"id":identifier, @"title":[NSString stringWithFormat:@"%@ · %@", row[@"name"], TWCPName(raw, cid, cache)],
                @"kind":@"twin.container", @"app":raw, @"twContainerID":cid,
                @"twOwner":@"com.niubiprass.twin.container"}];
            [selection addObject:identifier];
        }
    }
    if (![px setObject:actions forKey:@"customActions"]) return NO;
    return [px setObject:selection forKey:@"applications"];
}
