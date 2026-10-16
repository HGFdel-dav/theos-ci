//  DBGitHubClient — GitHub REST 批量上传
//  流程：GET repo → GET ref/heads/<branch> → POST git/blobs(201)
//        → GET git/blobs/<sha> raw 回读校验 → POST git/trees(增量 base_tree)
//        → POST git/commits → PATCH git/refs/heads/<branch>
#import <Foundation/Foundation.h>

FOUNDATION_EXPORT NSString *const DBGitHubErrorDomain;

@interface DBGitHubClient : NSObject

@property (nonatomic, copy, readonly) NSString *owner;
@property (nonatomic, copy, readonly) NSString *repoName;
@property (nonatomic, copy, readonly) NSString *defaultBranch;
@property (nonatomic, copy, readonly) NSString *headCommitSHA;
@property (nonatomic, copy, readonly) NSString *headTreeSHA;

// repo：@{@"owner":.., @"repoName":.., @"customPath":.., @"token":..}（来自 managed_github_repos.plist）
- (instancetype)initWithRepo:(NSDictionary *)repo;

// 读取 default_branch 与当前 HEAD（commit sha + tree sha）。失败 error 非空。
- (void)prepareWithCompletion:(void (^)(NSError *error))completion;

// 上传单个文件：写 blob → 回读校验 → 增量 tree → commit → 更新 ref。
// 成功：resultText 含 HTTP 201 / sha 前 8 位 / 服务器回读校验一致；
// 失败：error != nil（含 HTTP 状态与响应摘要）。
- (void)uploadData:(NSData *)data
          fileName:(NSString *)fileName
        completion:(void (^)(NSString *resultText, NSError *error))completion;

@end