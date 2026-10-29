//
//  DNBNewsItem.h
//  DebsNewsBatch
//
//  一条新闻 = 某个源上某个软件包的某次上传，字段直接对应 news.plist 里的结构。
//

#import <Foundation/Foundation.h>

@interface DNBNewsItem : NSObject

@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *version;
@property (nonatomic, copy) NSString *architecture;
@property (nonatomic, copy) NSString *packageID;
@property (nonatomic, copy) NSString *relFilename;      /* 相对路径，如 debs/xxx.deb */
@property (nonatomic, copy) NSString *sourceName;
@property (nonatomic, copy) NSString *sourceBase;       /* 源地址，如 https://a.example/repo */
@property (nonatomic, copy) NSString *urlString;        /* 拼好的完整下载地址 */
@property (nonatomic, copy) NSString *saveName;         /* 保存文件名 */
@property (nonatomic, copy) NSString *packageDescription;
@property (nonatomic, copy) NSString *maintainer;
@property (nonatomic, strong) NSDate *date;
@property (nonatomic, strong) NSDictionary *rawPackage; /* 原始 package 字典，写下载记录时原样回填 */
@property (nonatomic, strong) NSDictionary *rawSource;  /* 原始 source 字典（含 iconData） */

+ (instancetype)itemWithDictionary:(NSDictionary *)dictionary;
- (NSString *)uniqueKey;      /* 去重/选择用的稳定键 */
- (NSString *)displayArch;

@end
