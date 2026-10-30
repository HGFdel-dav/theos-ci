//
//  DNBDownloader.m
//  DebsNewsBatch
//

#import "DNBDownloader.h"
#import "DNBCommon.h"
#import "DNBNewsStore.h"
#import "DNBLogic.h"

@interface DNBDownloader ()
@property (nonatomic, strong) NSArray<DNBNewsItem *> *items;
@property (nonatomic, assign) BOOL overwrite;
@property (nonatomic, assign) BOOL writeRecord;
@property (nonatomic, assign) BOOL running;
@property (nonatomic, assign) NSInteger index;
@property (nonatomic, assign) NSInteger successCount;
@property (nonatomic, assign) NSInteger failedCount;
@property (nonatomic, assign) NSInteger skippedCount;
@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic, strong) NSURLSessionDownloadTask *currentTask;
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *records;
@property (nonatomic, assign) BOOL recordWritten;
@end

@implementation DNBDownloader

- (instancetype)initWithItems:(NSArray<DNBNewsItem *> *)items
                    overwrite:(BOOL)overwrite
                  writeRecord:(BOOL)writeRecord
{
    self = [super init];
    if (self) {
        _items = [items copy] ?: @[];
        _overwrite = overwrite;
        _writeRecord = writeRecord;
        _records = [NSMutableArray array];
        NSURLSessionConfiguration *config = [NSURLSessionConfiguration ephemeralSessionConfiguration];
        config.timeoutIntervalForRequest = 30.0;
        config.timeoutIntervalForResource = 600.0;
        config.allowsCellularAccess = YES;
        config.HTTPShouldUsePipelining = NO;
        NSOperationQueue *queue = [[NSOperationQueue alloc] init];
        queue.maxConcurrentOperationCount = 1;      /* 串行 */
        queue.name = @"com.niubiprass.debsnewsbatch.download";
        _session = [NSURLSession sessionWithConfiguration:config delegate:nil delegateQueue:queue];
    }
    return self;
}

- (void)dealloc
{
    [_session invalidateAndCancel];
}

- (void)start
{
    if (self.running || self.items.count == 0) {
        return;
    }
    self.running = YES;
    self.index = 0;
    self.successCount = 0;
    self.failedCount = 0;
    self.skippedCount = 0;
    self.recordWritten = NO;
    [self.records removeAllObjects];
    DNBLog(@"开始批量下载：%lu 个包，覆盖=%@，写下载记录=%@",
           (unsigned long)self.items.count, self.overwrite ? @"是" : @"否", self.writeRecord ? @"是" : @"否");
    [self startNext];
}

- (void)stop
{
    if (!self.running) {
        return;
    }
    self.running = NO;
    [self.currentTask cancel];
    self.currentTask = nil;
    for (NSInteger i = self.index; i < (NSInteger)self.items.count; i++) {
        [self notifyItem:self.items[i] state:DNBItemStateCancelled detail:@"已取消"];
    }
    DNBLog(@"用户停止批量下载：已完成 %ld，失败 %ld，跳过 %ld",
           (long)self.successCount, (long)self.failedCount, (long)self.skippedCount);
    [self finish];
}

- (void)startNext
{
    if (!self.running) {
        return;
    }
    if (self.index >= (NSInteger)self.items.count) {
        [self finish];
        return;
    }

    DNBNewsItem *item = self.items[self.index];
    [self notifyItem:item state:DNBItemStateWaiting detail:@"准备中"];
    [self notifyProgress];

    NSString *destination = [[DNBNewsStore sharedStore] localPathForItem:item];
    if (destination.length == 0) {
        [self failItem:item detail:@"文件名无效"];
        return;
    }

    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL exists = [fm fileExistsAtPath:destination];
    if (!dnblogic_should_write(exists ? 1 : 0, self.overwrite ? 1 : 0)) {
        DNBLog(@"同名已存在，跳过：%@", item.saveName);
        self.skippedCount++;
        [self notifyItem:item state:DNBItemStateSkipped detail:@"已存在，跳过"];
        [self advance];
        return;
    }

    NSURL *url = [NSURL URLWithString:item.urlString];
    if (!url.scheme.length) {
        DNBLog(@"地址无效：%@", item.urlString);
        [self failItem:item detail:@"地址无效"];
        return;
    }

    DNBEnsureDirectory(DNBDownloadsDir());
    DNBLog(@"下载中：%@ <- %@", item.saveName, item.urlString);
    [self notifyItem:item state:DNBItemStateDownloading detail:@"下载中…"];

    __weak typeof(self) weakSelf = self;
    self.currentTask = [self.session downloadTaskWithURL:url
                                       completionHandler:^(NSURL *location, NSURLResponse *response, NSError *error) {
        __strong typeof(self) self_ = weakSelf;
        if (!self_) {
            return;
        }
        [self_ handleResponse:response location:location error:error item:item destination:destination];
    }];
    [self.currentTask resume];
}

- (void)handleResponse:(NSURLResponse *)response
              location:(NSURL *)location
                 error:(NSError *)error
                  item:(DNBNewsItem *)item
           destination:(NSString *)destination
{
    if (!self.running) {
        return;                                     /* 已被停止，不再计入结果 */
    }
    if (error) {
        if (error.code == NSURLErrorCancelled) {
            [self notifyItem:item state:DNBItemStateCancelled detail:@"已取消"];
            self.running = NO;
            [self finish];
            return;
        }
        DNBLog(@"下载失败 %@：%@", item.saveName, error.localizedDescription);
        [self failItem:item detail:[NSString stringWithFormat:@"失败：%@", error.localizedDescription ?: @"未知错误"]];
        return;
    }

    NSInteger status = 0;
    if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
        status = [(NSHTTPURLResponse *)response statusCode];
    }
    if (status != 0 && status != 200) {
        DNBLog(@"下载失败 %@：HTTP %ld", item.saveName, (long)status);
        [self failItem:item detail:[NSString stringWithFormat:@"失败：HTTP %ld", (long)status]];
        return;
    }
    if (!location) {
        [self failItem:item detail:@"失败：无数据"];
        return;
    }

    NSFileManager *fm = [NSFileManager defaultManager];

    /* 校验 deb 魔术字节，避免把源返回的 HTML / 错误页当成功 */
    NSData *head = nil;
    NSFileHandle *reader = [NSFileHandle fileHandleForReadingAtPath:location.path];
    if (reader) {
        @try {
            head = [reader readDataOfLength:8];
        } @catch (__unused NSException *exception) {
            head = nil;
        } @finally {
            [reader closeFile];
        }
    }
    NSDictionary *fileAttrs = [fm attributesOfItemAtPath:location.path error:NULL];
    unsigned long long size = [fileAttrs fileSize];
    if (!dnblogic_is_deb_magic(head.bytes, head.length)) {
        DNBLog(@"校验失败 %@：不是 deb（大小 %llu 字节）", item.saveName, size);
        [self failItem:item detail:@"失败：不是 deb 文件"];
        return;
    }

    if ([[NSFileManager defaultManager] fileExistsAtPath:destination]) {
        [fm removeItemAtPath:destination error:NULL];
    }
    NSError *moveError = nil;
    if (![fm moveItemAtPath:location.path toPath:destination error:&moveError]) {
        DNBLog(@"保存失败 %@：%@", destination, moveError.localizedDescription);
        [self failItem:item detail:@"失败：保存出错"];
        return;
    }

    self.successCount++;
    DNBLog(@"完成：%@（%llu KB）", item.saveName, size / 1024);
    [self notifyItem:item state:DNBItemStateFinished
              detail:[NSString stringWithFormat:@"完成 · %.1f MB", (double)size / 1024.0 / 1024.0]];

    if (self.writeRecord) {
        NSMutableDictionary *record = [NSMutableDictionary dictionary];
        if ([item.rawPackage isKindOfClass:[NSDictionary class]]) {
            record[@"package"] = item.rawPackage;
        }
        if ([item.rawSource isKindOfClass:[NSDictionary class]]) {
            /* iconData 体积大，写记录时丢掉，其余原样保留 */
            NSMutableDictionary *source = [item.rawSource mutableCopy];
            [source removeObjectForKey:@"iconData"];
            record[@"source"] = source;
        }
        record[@"fileName"] = item.saveName;
        [self.records addObject:record];
    }

    [self advance];
}

- (void)failItem:(DNBNewsItem *)item detail:(NSString *)detail
{
    self.failedCount++;
    [self notifyItem:item state:DNBItemStateFailed detail:detail];
    [self advance];
}

- (void)advance
{
    self.currentTask = nil;
    self.index++;
    [self notifyProgress];
    if (!self.running) {
        return;
    }
    /* 放到下一个 runloop，避免递归过深 */
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        [weakSelf startNext];
    });
}

- (void)finish
{
    if (self.running) {
        self.running = NO;
    }
    if (!self.recordWritten && self.writeRecord && self.records.count > 0) {
        self.recordWritten = YES;
        [[DNBNewsStore sharedStore] appendDownloadRecords:self.records];
    }
    [self.session finishTasksAndInvalidate];
    DNBLog(@"批量下载结束：成功 %ld，失败 %ld，跳过 %ld",
           (long)self.successCount, (long)self.failedCount, (long)self.skippedCount);
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        __strong typeof(self) self_ = weakSelf;
        if (!self_ || !self_.delegate) {
            return;
        }
        if ([self_.delegate respondsToSelector:@selector(downloaderDidFinish:success:failed:skipped:)]) {
            [self_.delegate downloaderDidFinish:self_
                                        success:self_.successCount
                                         failed:self_.failedCount
                                        skipped:self_.skippedCount];
        }
    });
}

- (void)notifyItem:(DNBNewsItem *)item state:(DNBItemState)state detail:(NSString *)detail
{
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        __strong typeof(self) self_ = weakSelf;
        if (!self_ || !self_.delegate) {
            return;
        }
        if ([self_.delegate respondsToSelector:@selector(downloader:itemDidChange:state:detail:)]) {
            [self_.delegate downloader:self_ itemDidChange:item state:state detail:detail];
        }
    });
}

- (void)notifyProgress
{
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        __strong typeof(self) self_ = weakSelf;
        if (!self_ || !self_.delegate) {
            return;
        }
        if ([self_.delegate respondsToSelector:@selector(downloader:progressChanged:total:)]) {
            [self_.delegate downloader:self_
                       progressChanged:self_.index
                                 total:self_.items.count];
        }
    });
}

@end
