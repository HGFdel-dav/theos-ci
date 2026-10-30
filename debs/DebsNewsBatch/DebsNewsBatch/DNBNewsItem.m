//
//  DNBNewsItem.m
//  DebsNewsBatch
//

#import "DNBNewsItem.h"
#import "DNBLogic.h"

static NSString *DNBString(id value)
{
    if ([value isKindOfClass:[NSString class]]) {
        return [(NSString *)value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    }
    if ([value isKindOfClass:[NSNumber class]]) {
        return [(NSNumber *)value stringValue];
    }
    return nil;
}

@implementation DNBNewsItem

+ (instancetype)itemWithDictionary:(NSDictionary *)dictionary
{
    if (![dictionary isKindOfClass:[NSDictionary class]]) {
        return nil;
    }
    NSDictionary *package = dictionary[@"package"];
    NSDictionary *source = dictionary[@"source"];
    if (![package isKindOfClass:[NSDictionary class]] || ![source isKindOfClass:[NSDictionary class]]) {
        return nil;
    }
    NSDictionary *sourceURL = source[@"url"];
    NSString *base = nil;
    if ([sourceURL isKindOfClass:[NSDictionary class]]) {
        base = DNBString(sourceURL[@"relative"]);
        if (base.length == 0) {
            base = DNBString(sourceURL[@"absolute"]);
        }
    } else if ([sourceURL isKindOfClass:[NSString class]]) {
        base = DNBString(sourceURL);
    }

    NSString *rel = DNBString(package[@"filename"]);
    NSString *name = DNBString(package[@"name"]);
    if (name.length == 0) {
        name = DNBString(package[@"id"]);
    }
    if (name.length == 0 || rel.length == 0) {
        return nil;
    }

    DNBNewsItem *item = [[DNBNewsItem alloc] init];
    item.name = name;
    item.version = DNBString(package[@"version"]) ?: @"";
    item.architecture = DNBString(package[@"architecture"]) ?: @"";
    item.packageID = DNBString(package[@"id"]) ?: @"";
    item.relFilename = rel;
    item.sourceName = DNBString(source[@"name"]) ?: @"未知源";
    item.sourceBase = base ?: @"";
    item.packageDescription = DNBString(package[@"packageDescription"]) ?: @"";
    item.maintainer = DNBString(package[@"maintainer"]) ?: @"";
    item.rawPackage = package;
    item.rawSource = source;

    id dateValue = dictionary[@"date"];
    if ([dateValue isKindOfClass:[NSDate class]]) {
        item.date = dateValue;
    } else if ([dateValue isKindOfClass:[NSString class]]) {
        static NSDateFormatter *fmt = nil;
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            fmt = [[NSDateFormatter alloc] init];
            fmt.dateFormat = @"yyyy-MM-dd HH:mm:ss.SSSSSS";
            fmt.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
            fmt.timeZone = [NSTimeZone timeZoneWithName:@"UTC"];
        });
        NSString *text = [(NSString *)dateValue stringByReplacingOccurrencesOfString:@"T" withString:@" "];
        item.date = [fmt dateFromString:text];
    }

    char url[4096];
    if (dnblogic_join_url(url, sizeof(url), item.sourceBase.UTF8String, item.relFilename.UTF8String)) {
        item.urlString = [NSString stringWithUTF8String:url];
    }
    char save[512];
    if (dnblogic_save_name(save, sizeof(save),
                           item.name.UTF8String, item.version.UTF8String, item.architecture.UTF8String)) {
        item.saveName = [NSString stringWithUTF8String:save];
    }
    if (item.urlString.length == 0 || item.saveName.length == 0) {
        return nil;
    }
    return item;
}

- (NSString *)uniqueKey
{
    return [NSString stringWithFormat:@"%@|%@|%@|%@", self.name, self.version, self.architecture, self.sourceBase];
}

- (NSString *)displayArch
{
    if (dnblogic_arch_is_arm64e(self.architecture.UTF8String)) {
        return @"arm64e";
    }
    if (dnblogic_arch_is_arm64(self.architecture.UTF8String)) {
        return @"arm64";
    }
    return self.architecture.length ? self.architecture : @"未知架构";
}

@end
