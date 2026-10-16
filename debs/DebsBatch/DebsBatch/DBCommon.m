//  DebsBatch — 公共工具层实现
#import "DBCommon.h"
#import <zlib.h>
#import <CommonCrypto/CommonDigest.h>
#import <spawn.h>
#import <fcntl.h>
#import <signal.h>
#import <string.h>
#import <stdlib.h>
#import <sys/wait.h>
#import <unistd.h>

#pragma mark - 窗口 / 顶层 VC

UIWindow *DBKeyWindow(void) {
    UIApplication *app = UIApplication.sharedApplication;
    for (UIWindow *w in app.windows) {
        if (w.isKeyWindow) return w;
    }
    for (UIWindow *w in app.windows) {
        if (w.rootViewController && !w.hidden) return w;
    }
    return app.windows.firstObject;
}

UIViewController *DBTopViewController(void) {
    UIWindow *win = DBKeyWindow();
    UIViewController *vc = win.rootViewController;
    NSInteger guard = 0;
    while (vc && guard++ < 32) {
        UIViewController *next = vc.presentedViewController;
        if (next) { vc = next; continue; }
        if ([vc isKindOfClass:UINavigationController.class]) {
            UINavigationController *nav = (UINavigationController *)vc;
            if (nav.topViewController && nav.topViewController != (UIViewController *)nav) { vc = nav.topViewController; continue; }
        } else if ([vc isKindOfClass:UITabBarController.class]) {
            UIViewController *sel = ((UITabBarController *)vc).selectedViewController;
            if (sel && sel != vc) { vc = sel; continue; }
        }
        break;
    }
    return vc;
}

#pragma mark - 路径

NSString *DBAppDocumentsPath(void) {
    static NSString *path = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        path = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents"];
    });
    return path;
}

NSString *DBDownloadsPath(void) {
    return [DBAppDocumentsPath() stringByAppendingPathComponent:@"Downloads"];
}

NSString *DBReposPlistPath(void) {
    return [DBAppDocumentsPath() stringByAppendingPathComponent:@"managed_github_repos.plist"];
}

#pragma mark - 绑定仓库（复用 App「我的越狱源」配置）

NSArray<NSDictionary *> *DBLoadBoundRepos(void) {
    NSString *plistPath = DBReposPlistPath();
    NSData *data = [NSData dataWithContentsOfFile:plistPath];
    if (!data.length) {
        DBLOG(@"读取绑定仓库失败：文件不存在 %@", plistPath);
        return @[];
    }
    NSError *err = nil;
    id obj = [NSPropertyListSerialization propertyListWithData:data
                                                       options:NSPropertyListImmutable
                                                        format:NULL
                                                         error:&err];
    if (![obj isKindOfClass:NSArray.class]) {
        DBLOG(@"绑定仓库 plist 格式异常：%@", err.localizedDescription);
        return @[];
    }
    NSMutableArray<NSDictionary *> *out = [NSMutableArray array];
    for (id item in (NSArray *)obj) {
        if (![item isKindOfClass:NSDictionary.class]) continue;
        NSDictionary *dict = (NSDictionary *)item;
        NSString *owner = dict[@"owner"];
        NSString *name  = dict[@"repoName"];
        NSString *token = dict[@"token"];
        if (![owner isKindOfClass:NSString.class] || ![name isKindOfClass:NSString.class] ||
            ![token isKindOfClass:NSString.class] || !owner.length || !name.length || !token.length) {
            continue;
        }
        [out addObject:dict];
    }
    DBLOG(@"已绑定仓库 %lu 个", (unsigned long)out.count);
    return out;
}

NSString *DBRepoDisplayName(NSDictionary *repo) {
    NSString *owner = repo[@"owner"] ?: @"?";
    NSString *name = repo[@"repoName"] ?: @"?";
    return [NSString stringWithFormat:@"%@/%@", owner, name];
}

NSString *DBRepoUploadDir(NSDictionary *repo) {
    id dir = repo[@"customPath"];
    if ([dir isKindOfClass:NSString.class]) {
        NSString *s = [(NSString *)dir stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        s = [s stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"/"]];
        return s ?: @"";
    }
    return @"";
}

#pragma mark - 文件扫描（管理文件目录）

NSArray<NSString *> *DBScanDebFiles(void) {
    NSMutableArray<NSString *> *files = [NSMutableArray array];
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *root = DBDownloadsPath();
    BOOL isDir = NO;
    if (!([fm fileExistsAtPath:root isDirectory:&isDir] && isDir)) {
        DBLOG(@"管理文件目录不存在：%@", root);
        return files;
    }
    NSURL *rootURL = [NSURL fileURLWithPath:root isDirectory:YES];
    NSDirectoryEnumerator<NSURL *> *en = [fm enumeratorAtURL:rootURL
                                   includingPropertiesForKeys:@[NSURLIsDirectoryKey]
                                                      options:NSDirectoryEnumerationSkipsHiddenFiles
                                                 errorHandler:^BOOL(NSURL *url, NSError *error) {
        return YES;
    }];
    for (NSURL *u in en) {
        NSNumber *isDirectory = nil;
        [u getResourceValue:&isDirectory forKey:NSURLIsDirectoryKey error:NULL];
        if (isDirectory.boolValue) continue;
        if ([u.pathExtension.lowercaseString isEqualToString:@"deb"]) {
            [files addObject:u.path];
        }
    }
    [files sortUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        return [a.lastPathComponent localizedStandardCompare:b.lastPathComponent];
    }];
    DBLOG(@"扫描到 %lu 个 Deb 文件", (unsigned long)files.count);
    return files;
}

NSString *DBHumanSize(unsigned long long bytes) {
    if (bytes < 1024ULL) return [NSString stringWithFormat:@"%llu B", bytes];
    if (bytes < 1024ULL * 1024ULL) return [NSString stringWithFormat:@"%.1f KB", (double)bytes / 1024.0];
    return [NSString stringWithFormat:@"%.1f MB", (double)bytes / 1048576.0];
}

#pragma mark - git blob SHA1（服务器回读校验用）

NSString *DBGitBlobSHA1(NSData *data) {
    NSMutableData *blob = [NSMutableData dataWithCapacity:data.length + 32];
    [blob appendData:[@"blob " dataUsingEncoding:NSUTF8StringEncoding]];
    [blob appendData:[[NSString stringWithFormat:@"%lu", (unsigned long)data.length] dataUsingEncoding:NSUTF8StringEncoding]];
    [blob appendBytes:"\0" length:1];
    [blob appendData:data];
    unsigned char digest[CC_SHA1_DIGEST_LENGTH] = {0};
    CC_SHA1(blob.bytes, (CC_LONG)blob.length, digest);
    NSMutableString *hex = [NSMutableString stringWithCapacity:CC_SHA1_DIGEST_LENGTH * 2];
    for (int i = 0; i < CC_SHA1_DIGEST_LENGTH; i++) [hex appendFormat:@"%02x", digest[i]];
    return hex;
}

#pragma mark - dpkg-deb 路径候选与执行

static NSArray<NSString *> *DBDpkgCandidates(void) {
    NSMutableArray<NSString *> *arr = [NSMutableArray array];
    [arr addObject:@"/var/jb/usr/bin/dpkg-deb"];
    [arr addObject:@"/usr/bin/dpkg-deb"];
    [arr addObject:@"/usr/local/bin/dpkg-deb"];
    // RootHide：/var/containers/Bundle/Application/.jbroot-*/usr/bin/dpkg-deb
    NSString *base = @"/var/containers/Bundle/Application";
    NSArray<NSString *> *subs = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:base error:NULL];
    NSInteger found = 0;
    for (NSString *s in subs) {
        if (![s hasPrefix:@".jbroot-"]) continue;
        [arr addObject:[base stringByAppendingPathComponent:[NSString stringWithFormat:@"%@/usr/bin/dpkg-deb", s]]];
        [arr addObject:[base stringByAppendingPathComponent:[NSString stringWithFormat:@"%@/var/jb/usr/bin/dpkg-deb", s]]];
        if (++found >= 4) break;
    }
    return arr;
}

// 同步执行并捕获 stdout+stderr，超时强杀。沙盒内 spawn 失败返回 nil。
static NSString *DBExecCapture(NSString *tool, NSArray<NSString *> *args, NSTimeInterval timeout) {
    int fds[2];
    if (pipe(fds) != 0) return nil;

    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_adddup2(&actions, fds[1], STDOUT_FILENO);
    posix_spawn_file_actions_adddup2(&actions, fds[1], STDERR_FILENO);
    posix_spawn_file_actions_addclose(&actions, fds[0]);
    posix_spawn_file_actions_addclose(&actions, fds[1]);

    NSMutableArray<NSString *> *argv = [NSMutableArray arrayWithObject:tool];
    [argv addObjectsFromArray:args];
    char **cargv = calloc(argv.count + 1, sizeof(char *));
    for (NSUInteger i = 0; i < argv.count; i++) cargv[i] = strdup(argv[i].UTF8String);

    extern char **environ;
    pid_t pid = -1;
    int rc = posix_spawn(&pid, tool.UTF8String, &actions, NULL, cargv, environ);
    posix_spawn_file_actions_destroy(&actions);
    for (NSUInteger i = 0; i < argv.count; i++) free(cargv[i]);
    free(cargv);

    if (rc != 0) {
        close(fds[0]); close(fds[1]);
        DBLOG(@"spawn %@ 失败 rc=%d", tool, rc);
        return nil;
    }

    close(fds[1]);
    fcntl(fds[0], F_SETFL, fcntl(fds[0], F_GETFL) | O_NONBLOCK);

    NSMutableData *out = [NSMutableData data];
    uint8_t buf[4096];
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    BOOL eof = NO;
    while (!eof && ([deadline timeIntervalSinceNow] > 0)) {
        ssize_t n = read(fds[0], buf, sizeof(buf));
        if (n > 0) {
            [out appendBytes:buf length:(NSUInteger)n];
            if (out.length > 512 * 1024) break;
        } else if (n == 0) {
            eof = YES;
        } else {
            usleep(20000);
        }
    }
    close(fds[0]);
    if (waitpid(pid, NULL, WNOHANG) == 0) {
        kill(pid, SIGKILL);
    }
    waitpid(pid, NULL, 0);

    if (!out.length) return nil;
    return [[NSString alloc] initWithData:out encoding:NSUTF8StringEncoding];
}

#pragma mark - deb 内置解析（ar → control.tar[.gz] → control）

static void DBParseControlText(NSString *controlText, DBDebInfo *info) {
    for (NSString *rawLine in [controlText componentsSeparatedByString:@"\n"]) {
        NSString *line = [rawLine stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (line.length == 0 || [line hasPrefix:@"#"]) continue;
        NSRange colon = [line rangeOfString:@":"];
        if (colon.location == NSNotFound) continue;
        NSString *key = [[line substringToIndex:colon.location] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        NSString *val = [[line substringFromIndex:colon.location + 1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if ([key isEqualToString:@"Package"]) info.package = val;
        else if ([key isEqualToString:@"Version"]) info.version = val;
        else if ([key isEqualToString:@"Architecture"]) info.architecture = val;
        if (info.package.length && info.version.length && info.architecture.length) break;
    }
    if (info.package.length) info.parsed = YES;
}

static NSData *DBGunzip(NSData *data) {
    if (!data.length) return nil;
    z_stream strm;
    memset(&strm, 0, sizeof(strm));
    if (inflateInit2(&strm, 16 + MAX_WBITS) != Z_OK) return nil; // 16+MAX_WBITS = gzip
    NSMutableData *out = [NSMutableData dataWithCapacity:data.length * 4];
    uint8_t buf[16384];
    strm.next_in = (Bytef *)data.bytes;
    strm.avail_in = (uInt)data.length;
    int ret = Z_OK;
    do {
        strm.next_out = buf;
        strm.avail_out = sizeof(buf);
        ret = inflate(&strm, Z_NO_FLUSH);
        if (ret != Z_OK && ret != Z_STREAM_END && ret != Z_BUF_ERROR) break;
        if (strm.avail_out < sizeof(buf)) {
            [out appendBytes:buf length:(sizeof(buf) - strm.avail_out)];
            if (out.length > 16 * 1024 * 1024) break;
        }
        if (ret == Z_STREAM_END) break;
        if (strm.avail_in == 0 && strm.avail_out == sizeof(buf)) break; // 无进展防死循环
    } while (ret == Z_OK || ret == Z_BUF_ERROR);
    inflateEnd(&strm);
    return out.length ? out : nil;
}

// 在 tar 字节流中查找 control 文件并返回其文本内容（未压缩的 tar 数据）
static NSString *DBExtractControlText(NSData *tarData) {
    NSUInteger len = tarData.length;
    const uint8_t *bytes = tarData.bytes;
    NSUInteger off = 0;
    while (off + 512 <= len) {
        const uint8_t *hdr = bytes + off;
        char nameBuf[101];
        memcpy(nameBuf, hdr, 100);
        nameBuf[100] = '\0';
        NSString *name = [NSString stringWithUTF8String:nameBuf];
        char sizeBuf[13];
        memcpy(sizeBuf, hdr + 124, 12);
        sizeBuf[12] = '\0';
        unsigned long long size = strtoull(sizeBuf, NULL, 8);
        char typeflag = hdr[156];
        NSString *trimmed = [name stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (trimmed.length == 0 && size == 0) break; // EOF 块
        if (typeflag == 'x' || typeflag == 'g' || typeflag == 'L' || typeflag == 'K') {
            // pax/长名块：跳过其数据
            off += 512 + (NSUInteger)(((size + 511) / 512) * 512);
            continue;
        }
        if (size > 0 && ([trimmed isEqualToString:@"./control"] || [trimmed isEqualToString:@"control"]) && typeflag == '0') {
            NSUInteger dataOff = off + 512;
            NSUInteger dataLen = (NSUInteger)size;
            if (dataOff + dataLen <= len) {
                NSData *ctl = [NSData dataWithBytes:bytes + dataOff length:dataLen];
                NSString *text = [[NSString alloc] initWithData:ctl encoding:NSUTF8StringEncoding];
                if (text.length) return text;
            }
        }
        off += 512 + (NSUInteger)(((size + 511) / 512) * 512);
    }
    return nil;
}

// ar 容器解析：!<arch>\n + 60 字节头（name 16 / mtime 12 / uid 6 / gid 6 / mode 8 / size 10 / magic 2）
static NSString *DBDebControlText(NSData *debData) {
    if (debData.length < 8) return nil;
    if (memcmp(debData.bytes, "!<arch>\n", 8) != 0) return nil;
    NSUInteger off = 8;
    const uint8_t *bytes = debData.bytes;
    NSUInteger len = debData.length;
    while (off + 60 <= len) {
        const uint8_t *h = bytes + off;
        char nameBuf[17];
        memcpy(nameBuf, h, 16);
        nameBuf[16] = '\0';
        char sizeBuf[11];
        memcpy(sizeBuf, h + 48, 10);
        sizeBuf[10] = '\0';
        BOOL oddPad = (h[58] == 0x60);
        NSString *name = [NSString stringWithUTF8String:nameBuf];
        NSString *trimmed = [name stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        unsigned long long size = strtoull(sizeBuf, NULL, 10);
        NSUInteger dataOff = off + 60;
        NSUInteger dataLen = (NSUInteger)size;
        if (dataOff + dataLen > len) break;
        if ([trimmed isEqualToString:@"control.tar.gz"] || [trimmed isEqualToString:@"control.tar"]) {
            NSData *member = [NSData dataWithBytes:bytes + dataOff length:dataLen];
            NSData *tar = member;
            if ([trimmed hasSuffix:@".gz"]) {
                NSData *u = DBGunzip(member);
                if (u) tar = u;
            }
            return DBExtractControlText(tar);
        }
        off = dataOff + dataLen + ((oddPad && (dataLen % 2 == 1)) ? 1 : 0);
    }
    return nil;
}

@implementation DBDebInfo

+ (instancetype)infoForDebAtPath:(NSString *)path {
    DBDebInfo *info = [DBDebInfo new];
    // 1) 设备自带 dpkg-deb（覆盖 gz/xz/zstd 全部压缩格式）
    for (NSString *tool in DBDpkgCandidates()) {
        if (![[NSFileManager defaultManager] isExecutableFileAtPath:tool]) continue;
        NSString *out = DBExecCapture(tool, @[@"-f", path, @"Package", @"Version", @"Architecture"], 4.0);
        if (!out.length) continue;
        NSInteger idx = 0;
        for (NSString *l in [out componentsSeparatedByString:@"\n"]) {
            NSString *t = [l stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (!t.length) continue;
            if (idx == 0) info.package = t;
            else if (idx == 1) info.version = t;
            else if (idx == 2) {
                info.architecture = t;
                break;
            }
            idx++;
        }
        if (info.package.length) {
            info.parsed = YES;
            DBLOG(@"dpkg-deb 解析成功：%@", info.package);
            return info;
        }
    }
    // 2) 内置解析（无外部工具兜底）
    NSData *data = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:NULL];
    if (data.length) {
        NSString *controlText = DBDebControlText(data);
        if (controlText.length) DBParseControlText(controlText, info);
    }
    if (info.parsed) {
        DBLOG(@"内置解析成功：%@", info.package);
    } else {
        DBLOG(@"解析包名失败：%@", [path lastPathComponent]);
    }
    return info;
}

- (NSString *)targetFileNameWithFallback:(NSString *)fallback {
    if (self.parsed && self.package.length) {
        NSString *v = self.version.length ? self.version : @"0";
        NSString *a = self.architecture.length ? self.architecture : @"iphoneos-arm64";
        NSString *name = [NSString stringWithFormat:@"%@_%@_%@.deb", self.package, v, a];
        name = [name stringByReplacingOccurrencesOfString:@"/" withString:@"_"];
        name = [name stringByReplacingOccurrencesOfString:@" " withString:@""];
        return name;
    }
    if (fallback.length) return fallback;
    return @"unknown.deb";
}

@end