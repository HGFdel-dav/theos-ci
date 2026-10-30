//
//  DNBDownloader.h
//  DebsNewsBatch
//
//  串行下载器：一次只下一个包，避免把源打炸；每个包落到 Downloads/DEBs/。
//

#import <Foundation/Foundation.h>
#import "DNBNewsItem.h"

typedef NS_ENUM(NSInteger, DNBItemState) {
    DNBItemStateWaiting = 0,
    DNBItemStateDownloading,
    DNBItemStateFinished,
    DNBItemStateFailed,
    DNBItemStateSkipped,
    DNBItemStateCancelled
};

@class DNBDownloader;

@protocol DNBDownloaderDelegate <NSObject>
- (void)downloader:(DNBDownloader *)downloader
      itemDidChange:(DNBNewsItem *)item
              state:(DNBItemState)state
             detail:(NSString *)detail;
- (void)downloader:(DNBDownloader *)downloader
    progressChanged:(NSInteger)done
             total:(NSInteger)total;
- (void)downloaderDidFinish:(DNBDownloader *)downloader
                    success:(NSInteger)success
                     failed:(NSInteger)failed
                    skipped:(NSInteger)skipped;
@end

@interface DNBDownloader : NSObject

@property (nonatomic, weak) id<DNBDownloaderDelegate> delegate;
@property (nonatomic, readonly) BOOL running;
@property (nonatomic, readonly) NSInteger successCount;
@property (nonatomic, readonly) NSInteger failedCount;
@property (nonatomic, readonly) NSInteger skippedCount;

- (instancetype)initWithItems:(NSArray<DNBNewsItem *> *)items
                    overwrite:(BOOL)overwrite
                  writeRecord:(BOOL)writeRecord;
- (void)start;
- (void)stop;

@end
