//  DBGitHubClient — 实现
#import "DBGitHubClient.h"
#import "DBCommon.h"

NSString *const DBGitHubErrorDomain = @"DBGitHubErrorDomain";

static NSDictionary *DBJSONFromData(NSData *data) {
    if (!data.length) return nil;
    return [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
}

@interface DBGitHubClient ()
@property (nonatomic, copy) NSString *owner;
@property (nonatomic, copy) NSString *repoName;
@property (nonatomic, copy) NSString *accessToken;
@property (nonatomic, copy) NSString *uploadDir;
@property (nonatomic, copy, readwrite) NSString *defaultBranch;
@property (nonatomic, copy, readwrite) NSString *headCommitSHA;
@property (nonatomic, copy, readwrite) NSString *headTreeSHA;
@end

@implementation DBGitHubClient {
    NSURLSession *_session;
}

- (instancetype)initWithRepo:(NSDictionary *)repo {
    self = [super init];
    if (self) {
        _owner = [repo[@"owner"] copy];
        _repoName = [repo[@"repoName"] copy];
        _accessToken = [repo[@"token"] copy];
        _uploadDir = [DBRepoUploadDir(repo) copy];
        NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration defaultSessionConfiguration];
        cfg.timeoutIntervalForRequest = 60;
        cfg.timeoutIntervalForResource = 300;
        _session = [NSURLSession sessionWithConfiguration:cfg];
    }
    return self;
}

- (NSMutableURLRequest *)_requestWithPath:(NSString *)path method:(NSString *)method {
    NSString *url = [NSString stringWithFormat:@"https://api.github.com/repos/%@/%@%@",
                     _owner, _repoName, path];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]];
    req.HTTPMethod = method;
    [req setValue:[NSString stringWithFormat:@"Bearer %@", _accessToken] forHTTPHeaderField:@"Authorization"];
    [req setValue:@"application/vnd.github+json" forHTTPHeaderField:@"Accept"];
    [req setValue:@"DebsBatch/0.1" forHTTPHeaderField:@"User-Agent"];
    return req;
}

- (void)_sendRequest:(NSMutableURLRequest *)req
                body:(NSData *)body
          completion:(void (^)(NSData *data, NSHTTPURLResponse *resp, NSError *err))completion {
    if (body) req.HTTPBody = body;
    __weak typeof(self) weakSelf = self;
    NSURLSessionDataTask *task = [_session dataTaskWithRequest:req
                                             completionHandler:^(NSData *data, NSURLResponse *resp, NSError *error) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) { completion(nil, nil, [NSError errorWithDomain:DBGitHubErrorDomain code:-1 userInfo:@{NSLocalizedDescriptionKey:@"客户端已释放"}]); return; }
        // 统一回调主线程，方便面板直接更新 UI
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(data, (NSHTTPURLResponse *)resp, error);
        });
    }];
    [task resume];
}

- (NSError *)_errorWithStatus:(NSInteger)status data:(NSData *)data fallback:(NSString *)fallback {
    NSString *detail = fallback;
    NSDictionary *json = DBJSONFromData(data);
    id msg = json[@"message"];
    if ([msg isKindOfClass:NSString.class] && [msg length]) {
        detail = [NSString stringWithFormat:@"%@（HTTP %ld）", msg, (long)status];
    } else if (status > 0) {
        detail = [NSString stringWithFormat:@"%@（HTTP %ld）", fallback ?: @"请求失败", (long)status];
    }
    return [NSError errorWithDomain:DBGitHubErrorDomain
                               code:(status > 0 ? status : -1)
                           userInfo:@{NSLocalizedDescriptionKey: detail ?: @"未知错误"}];
}

#pragma mark - 准备

- (void)prepareWithCompletion:(void (^)(NSError *error))completion {
    __weak typeof(self) weakSelf = self;

    // GET /repos/{owner}/{repo}
    NSMutableURLRequest *req = [self _requestWithPath:@"" method:@"GET"];
    [self _sendRequest:req body:nil completion:^(NSData *data, NSHTTPURLResponse *resp, NSError *err) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) { completion([NSError errorWithDomain:DBGitHubErrorDomain code:-1 userInfo:@{NSLocalizedDescriptionKey:@"客户端已释放"}]); return; }
        if (err) { completion(err); return; }
        NSDictionary *json = DBJSONFromData(data);
        if (resp.statusCode != 200 || !json) {
            completion([strongSelf _errorWithStatus:resp.statusCode data:data fallback:@"读取仓库信息失败"]);
            return;
        }
        strongSelf.defaultBranch = [json[@"default_branch"] isKindOfClass:NSString.class] ? json[@"default_branch"] : @"main";

        // GET /git/ref/heads/{branch}
        NSString *refPath = [NSString stringWithFormat:@"/git/ref/heads/%@", strongSelf.defaultBranch];
        NSMutableURLRequest *r2 = [strongSelf _requestWithPath:refPath method:@"GET"];
        [strongSelf _sendRequest:r2 body:nil completion:^(NSData *d2, NSHTTPURLResponse *r2r, NSError *e2) {
            __strong typeof(weakSelf) s2 = weakSelf;
            if (!s2) { completion([NSError errorWithDomain:DBGitHubErrorDomain code:-1 userInfo:@{NSLocalizedDescriptionKey:@"客户端已释放"}]); return; }
            if (e2) { completion(e2); return; }
            NSDictionary *j2 = DBJSONFromData(d2);
            if (r2r.statusCode != 200 || !j2[@"object"]) {
                completion([s2 _errorWithStatus:r2r.statusCode data:d2 fallback:@"读取分支失败"]);
                return;
            }
            s2.headCommitSHA = j2[@"object"][@"sha"];

            // GET /git/commits/{sha} → tree
            NSString *commitPath = [NSString stringWithFormat:@"/git/commits/%@", s2.headCommitSHA];
            NSMutableURLRequest *r3 = [s2 _requestWithPath:commitPath method:@"GET"];
            [s2 _sendRequest:r3 body:nil completion:^(NSData *d3, NSHTTPURLResponse *r3r, NSError *e3) {
                __strong typeof(weakSelf) s3 = weakSelf;
                if (!s3) { completion([NSError errorWithDomain:DBGitHubErrorDomain code:-1 userInfo:@{NSLocalizedDescriptionKey:@"客户端已释放"}]); return; }
                if (e3) { completion(e3); return; }
                NSDictionary *j3 = DBJSONFromData(d3);
                if (r3r.statusCode != 200 || !j3[@"tree"]) {
                    completion([s3 _errorWithStatus:r3r.statusCode data:d3 fallback:@"读取提交树失败"]);
                    return;
                }
                s3.headTreeSHA = j3[@"tree"][@"sha"];
                DBLOG(@"准备完成 %@/%@ branch=%@ head=%@", s3.owner, s3.repoName, s3.defaultBranch, s3.headCommitSHA);
                completion(nil);
            }];
        }];
    }];
}

#pragma mark - 上传单个文件

- (void)uploadData:(NSData *)data
          fileName:(NSString *)fileName
        completion:(void (^)(NSString *resultText, NSError *error))completion {
    NSString *relPath = fileName;
    if (_uploadDir.length) relPath = [_uploadDir stringByAppendingPathComponent:fileName];

    __weak typeof(self) weakSelf = self;

    // 1) POST /git/blobs
    NSDictionary *blobBody = @{@"content": [data base64EncodedStringWithOptions:0], @"encoding": @"base64"};
    NSData *blobJSON = [NSJSONSerialization dataWithJSONObject:blobBody options:0 error:NULL];
    NSMutableURLRequest *req = [self _requestWithPath:@"/git/blobs" method:@"POST"];
    [self _sendRequest:req body:blobJSON completion:^(NSData *d, NSHTTPURLResponse *r, NSError *e) {
        __strong typeof(weakSelf) s = weakSelf;
        if (!s) { completion(nil, [NSError errorWithDomain:DBGitHubErrorDomain code:-1 userInfo:@{NSLocalizedDescriptionKey:@"客户端已释放"}]); return; }
        if (e || r.statusCode != 201) {
            completion(nil, [s _errorWithStatus:r.statusCode data:d fallback:e ? e.localizedDescription : @"写入 git blob 失败"]);
            return;
        }
        NSDictionary *j = DBJSONFromData(d);
        NSString *blobSHA = [j[@"sha"] isKindOfClass:NSString.class] ? j[@"sha"] : @"";
        if (!blobSHA.length) {
            completion(nil, [NSError errorWithDomain:DBGitHubErrorDomain code:-1 userInfo:@{NSLocalizedDescriptionKey:@"blob 响应缺少 sha"}]); 
            return;
        }

        // 2) 回读校验：GET /git/blobs/{sha}（raw）
        NSMutableURLRequest *v = [s _requestWithPath:[NSString stringWithFormat:@"/git/blobs/%@", blobSHA] method:@"GET"];
        [v setValue:@"application/vnd.github.raw" forHTTPHeaderField:@"Accept"];
        [s _sendRequest:v body:nil completion:^(NSData *vd, NSHTTPURLResponse *vr, NSError *ve) {
            __strong typeof(weakSelf) s2 = weakSelf;
            if (!s2) { completion(nil, [NSError errorWithDomain:DBGitHubErrorDomain code:-1 userInfo:@{NSLocalizedDescriptionKey:@"客户端已释放"}]); return; }
            if (ve || !vd.length || vr.statusCode != 200) {
                completion(nil, [s2 _errorWithStatus:vr.statusCode data:vd fallback:ve ? ve.localizedDescription : @"服务器回读文件失败"]);
                return;
            }
            BOOL match = [vd isEqualToData:data];
            if (!match) {
                completion(nil, [NSError errorWithDomain:DBGitHubErrorDomain code:-2 userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithFormat:@"服务器回读校验不一致（%@）", blobSHA]}]); 
                return;
            }
            NSString *verifyText = @"服务器回读校验一致";

            // 3) POST /git/trees（增量：base_tree = 当前 head tree）
            NSDictionary *treeBody = @{
                @"base_tree": s2.headTreeSHA ?: @"",
                @"tree": @[@{@"path": relPath, @"mode": @"100644", @"type": @"blob", @"sha": blobSHA}]
            };
            NSData *treeJSON = [NSJSONSerialization dataWithJSONObject:treeBody options:0 error:NULL];
            NSMutableURLRequest *tr = [s2 _requestWithPath:@"/git/trees" method:@"POST"];
            [s2 _sendRequest:tr body:treeJSON completion:^(NSData *td, NSHTTPURLResponse *trr, NSError *te) {
                __strong typeof(weakSelf) s3 = weakSelf;
                if (!s3) { completion(nil, [NSError errorWithDomain:DBGitHubErrorDomain code:-1 userInfo:@{NSLocalizedDescriptionKey:@"客户端已释放"}]); return; }
                if (te || trr.statusCode != 201) {
                    completion(nil, [s3 _errorWithStatus:trr.statusCode data:td fallback:te ? te.localizedDescription : @"创建 git tree 失败"]);
                    return;
                }
                NSDictionary *tj = DBJSONFromData(td);
                NSString *treeSHA = [tj[@"sha"] isKindOfClass:NSString.class] ? tj[@"sha"] : @"";
                if (!treeSHA.length) {
                    completion(nil, [NSError errorWithDomain:DBGitHubErrorDomain code:-1 userInfo:@{NSLocalizedDescriptionKey:@"tree 响应缺少 sha"}]); 
                    return;
                }

                // 4) POST /git/commits
                NSDictionary *commitBody = @{
                    @"message": [NSString stringWithFormat:@"DebsBatch: 上传 %@", fileName],
                    @"tree": treeSHA,
                    @"parents": @[s3.headCommitSHA ?: @""]
                };
                NSData *commitJSON = [NSJSONSerialization dataWithJSONObject:commitBody options:0 error:NULL];
                NSMutableURLRequest *cr = [s3 _requestWithPath:@"/git/commits" method:@"POST"];
                [s3 _sendRequest:cr body:commitJSON completion:^(NSData *cd, NSHTTPURLResponse *crr, NSError *ce) {
                    __strong typeof(weakSelf) s4 = weakSelf;
                    if (!s4) { completion(nil, [NSError errorWithDomain:DBGitHubErrorDomain code:-1 userInfo:@{NSLocalizedDescriptionKey:@"客户端已释放"}]); return; }
                    if (ce || crr.statusCode != 201) {
                        completion(nil, [s4 _errorWithStatus:crr.statusCode data:cd fallback:ce ? ce.localizedDescription : @"创建提交失败"]);
                        return;
                    }
                    NSDictionary *cj = DBJSONFromData(cd);
                    NSString *commitSHA = [cj[@"sha"] isKindOfClass:NSString.class] ? cj[@"sha"] : @"";
                    if (!commitSHA.length) {
                        completion(nil, [NSError errorWithDomain:DBGitHubErrorDomain code:-1 userInfo:@{NSLocalizedDescriptionKey:@"commit 响应缺少 sha"}]); 
                        return;
                    }

                    // 5) PATCH /git/refs/heads/{branch}
                    NSDictionary *refBody = @{@"sha": commitSHA, @"force": @NO};
                    NSData *refJSON = [NSJSONSerialization dataWithJSONObject:refBody options:0 error:NULL];
                    NSString *refPath = [NSString stringWithFormat:@"/git/refs/heads/%@", s4.defaultBranch];
                    NSMutableURLRequest *rr = [s4 _requestWithPath:refPath method:@"PATCH"];
                    [s4 _sendRequest:rr body:refJSON completion:^(NSData *rd, NSHTTPURLResponse *rrr, NSError *re) {
                        __strong typeof(weakSelf) s5 = weakSelf;
                        if (!s5) { completion(nil, [NSError errorWithDomain:DBGitHubErrorDomain code:-1 userInfo:@{NSLocalizedDescriptionKey:@"客户端已释放"}]); return; }
                        if (re || rrr.statusCode != 200) {
                            completion(nil, [s5 _errorWithStatus:rrr.statusCode data:rd fallback:re ? re.localizedDescription : @"更新分支引用失败"]);
                            return;
                        }
                        s5.headCommitSHA = commitSHA;
                        s5.headTreeSHA = treeSHA;
                        NSString *shortSHA = blobSHA.length > 8 ? [blobSHA substringToIndex:8] : blobSHA;
                        NSString *result = [NSString stringWithFormat:@"上传成功 · HTTP 201 · %@ · %@", shortSHA, verifyText];
                        DBLOG(@"上传完成 %@ → %@（%@）", fileName, relPath, result);
                        completion(result, nil);
                    }];
                }];
            }];
        }];
    }];
}

@end