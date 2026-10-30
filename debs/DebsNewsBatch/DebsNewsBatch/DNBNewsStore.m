//
//  DNBNewsStore.m
//  DebsNewsBatch
//

#import "DNBNewsStore.h"
#import "DNBCommon.h"
#import "DNBLogic.h"

@interface DNBNewsStore ()
@property (nonatomic, strong) NSArray<DNBNewsItem *> *items;
@property (nonatomic, strong) NSMutableSet<NSString *> *existingNames;
@end

@implementation DNBNewsStore

+ (instancetype)sharedStore
{
    static DNBNewsStore *store = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        store = [[DNBNewsStore alloc] init];
        [store reload];
    });
    return store;
}

- (void)reload
{
    NSString *path = DNBNewsPath();
    NSArray *raw = [NSArray arrayWithContentsOfFile:path];
    if (![raw isKindOfClass:[NSArray class]]) {
        DNBLog(@"读取新闻失败：%@（文件不存在或格式不符）", path);
        self.items = @[];
        return;
    }

    NSMutableArray<DNBNewsItem *> *parsed = [NSMutableArray arrayWithCapacity:raw.count];
    NSMutableDictionary<NSString *, DNBNewsItem *> *deduped = [NSMutableDictionary dictionary];
    for (id entry in raw) {
        DNBNewsItem *item = [DNBNewsItem itemWithDictionary:entry];
        if (!item) {
            continue;
        }
        NSString *key = [item uniqueKey];
        DNBNewsItem *old = deduped[key];
        if (!old) {
            deduped[key] = item;
            continue;
        }
        NSDate *a = item.date ?: [NSDate distantPast];
        NSDate *b = old.date ?: [NSDate distantPast];
        if ([a compare:b] == NSOrderedDescending) {
            deduped[key] = item;
        }
    }
    [parsed addObjectsFromArray:deduped.allValues];

    NSMutableArray<DNBNewsItem *> *sorted = [parsed mutableCopy];
    [sorted sortUsingComparator:^NSComparisonResult(DNBNewsItem *lhs, DNBNewsItem *rhs) {
        NSDate *a = lhs.date ?: [NSDate distantPast];
        NSDate *b = rhs.date ?: [NSDate distantPast];
        NSComparisonResult result = [b compare:a];
        if (result != NSOrderedSame) {
            return result;
        }
        return [lhs.name compare:rhs.name];
    }];

    self.items = sorted;
    [self refreshExistingCache];
    DNBLog(@"新闻载入完成：原始 %lu 条，去重后 %lu 条", (unsigned long)raw.count, (unsigned long)self.items.count);
}

- (void)refreshExistingCache
{
    NSMutableSet<NSString *> *names = [NSMutableSet set];
    NSArray<NSString *> *contents = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:DNBDownloadsDir() error:NULL];
    for (NSString *name in contents) {
        if (name.length) {
            [names addObject:name];
        }
    }
    self.existingNames = names;
}

- (NSArray<DNBNewsItem *> *)itemsMatchingFilter:(NSInteger)filter
{
    [self refreshExistingCache];
    NSMutableArray<DNBNewsItem *> *result = [NSMutableArray array];
    for (DNBNewsItem *item in self.items) {
        if (dnblogic_filter_match((int)filter, item.architecture.UTF8String, [self isDownloaded:item] ? 1 : 0)) {
            [result addObject:item];
        }
    }
    return result;
}

- (NSString *)localPathForItem:(DNBNewsItem *)item
{
    if (item.saveName.length == 0) {
        return nil;
    }
    return [DNBDownloadsDir() stringByAppendingPathComponent:item.saveName];
}

- (BOOL)isDownloaded:(DNBNewsItem *)item
{
    if (item.saveName.length == 0) {
        return NO;
    }
    if ([self.existingNames containsObject:item.saveName]) {
        return YES;
    }
    return [[NSFileManager defaultManager] fileExistsAtPath:[self localPathForItem:item]];
}

- (NSInteger)downloadedCount
{
    NSInteger count = 0;
    for (DNBNewsItem *item in self.items) {
        if ([self isDownloaded:item]) {
            count++;
        }
    }
    return count;
}

- (BOOL)appendDownloadRecords:(NSArray<NSDictionary *> *)records
{
    if (records.count == 0) {
        return YES;
    }
    NSString *path = DNBMetadataPath();
    NSMutableArray *list = nil;
    if ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
        list = [NSMutableArray arrayWithContentsOfFile:path];
    }
    if (!list) {
        list = [NSMutableArray array];
    }

    NSMutableSet<NSString *> *known = [NSMutableSet set];
    for (id entry in list) {
        if ([entry isKindOfClass:[NSDictionary class]]) {
            NSString *name = entry[@"fileName"];
            if ([name isKindOfClass:[NSString class]]) {
                [known addObject:name];
            }
        }
    }

    NSInteger added = 0;
    for (NSDictionary *record in records) {
        NSString *name = record[@"fileName"];
        if ([name isKindOfClass:[NSString class]] && [known containsObject:name]) {
            continue;
        }
        [list addObject:record];
        if ([name isKindOfClass:[NSString class]]) {
            [known addObject:name];
        }
        added++;
    }
    if (added == 0) {
        DNBLog(@"下载记录已包含这些文件，跳过写入");
        return YES;
    }

    /* 写之前留一份备份，方便用户回滚 */
    NSString *backup = [path stringByAppendingString:@".debsnewsbatch.bak"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:backup]) {
        [[NSFileManager defaultManager] copyItemAtPath:path toPath:backup error:NULL];
    }

    BOOL ok = [list writeToFile:path atomically:YES];
    DNBLog(@"写入下载记录 %ld 条 -> %@ (%@)", (long)added, path.lastPathComponent, ok ? @"成功" : @"失败");
    return ok;
}

@end
