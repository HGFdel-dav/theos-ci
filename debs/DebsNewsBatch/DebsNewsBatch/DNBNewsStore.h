//
//  DNBNewsStore.h
//  DebsNewsBatch
//

#import <Foundation/Foundation.h>
#import "DNBNewsItem.h"

@interface DNBNewsStore : NSObject

+ (instancetype)sharedStore;

/* 全部新闻，按日期倒序、按唯一键去重 */
@property (nonatomic, readonly) NSArray<DNBNewsItem *> *items;

- (void)reload;
- (NSArray<DNBNewsItem *> *)itemsMatchingFilter:(NSInteger)filter;
- (NSString *)localPathForItem:(DNBNewsItem *)item;
- (BOOL)isDownloaded:(DNBNewsItem *)item;
- (NSInteger)downloadedCount;

/* 把本次下载的文件追加到 App 自己的下载记录里（失败不影响下载结果） */
- (BOOL)appendDownloadRecords:(NSArray<NSDictionary *> *)records;

@end
