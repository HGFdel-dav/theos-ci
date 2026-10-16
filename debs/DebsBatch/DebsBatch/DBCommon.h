//  DebsBatch — 公共工具层
//  目标 App：Debs (com.iosdump.Debs.Debs)
//  用途：窗口/VC 获取、文件扫描、绑定仓库读取、deb 包名解析、git blob SHA1
#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>

#ifdef DEBSBATCH_STRIP_LOGS
#define DBLOG(...) do {} while (0)
#else
#define DBLOG(fmt, ...) do { NSLog(@"[DebsBatch] " fmt, ##__VA_ARGS__); } while (0)
#endif

#ifdef __cplusplus
extern "C" {
#endif

UIWindow *DBKeyWindow(void);
UIViewController *DBTopViewController(void);

NSString *DBAppDocumentsPath(void);
NSString *DBDownloadsPath(void);
NSString *DBReposPlistPath(void);

// 读取 App「我的越狱源」已绑定的 GitHub 仓库（Documents/managed_github_repos.plist）
// 元素：@{@"id":.., @"owner":.., @"repoName":.., @"customPath":.., @"token":..}
NSArray<NSDictionary *> *DBLoadBoundRepos(void);
NSString *DBRepoDisplayName(NSDictionary *repo);
NSString *DBRepoUploadDir(NSDictionary *repo);

// 扫描 管理文件 目录（Documents/Downloads 递归）中的 .deb
NSArray<NSString *> *DBScanDebFiles(void);
NSString *DBHumanSize(unsigned long long bytes);

// git blob sha1 = sha1("blob <len>\0" + data)，用于服务器回读校验
NSString *DBGitBlobSHA1(NSData *data);

#ifdef __cplusplus
}
#endif

// deb control 信息（Package / Version / Architecture）
@interface DBDebInfo : NSObject
@property (nonatomic, copy) NSString *package;
@property (nonatomic, copy) NSString *version;
@property (nonatomic, copy) NSString *architecture;
@property (nonatomic, assign) BOOL parsed;   // 是否成功解析出包名
+ (instancetype)infoForDebAtPath:(NSString *)path;
// 目标文件名：<Package>_<Version>_<Architecture>.deb；解析失败回退 fallback
- (NSString *)targetFileNameWithFallback:(NSString *)fallback;
@end