#import "PXCloneTrace.h"
#import "PXClonePaths.h"
#import "PXCloneRootPolicy.h"
#import "PXCloneTraceIO.h"
#import <notify.h>
#include <limits.h>
#include <stdlib.h>

NSString *const PXCloneTraceNotification = @"com.niubiprass.parallelxclone/trace-state";

static int PXTraceStateToken(void) {
    static int token = -1;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        if (notify_register_check(PXCloneTraceNotification.UTF8String, &token) != NOTIFY_STATUS_OK) token = -1;
    });
    return token;
}

static NSError *PXTraceError(PXCloneTraceState state, NSString *message, NSError *cause) {
    NSMutableDictionary *details = [NSMutableDictionary dictionaryWithObject:message
                                                                    forKey:NSLocalizedDescriptionKey];
    if (cause) details[NSUnderlyingErrorKey] = cause;
    return [NSError errorWithDomain:@"com.niubiprass.parallelxclone.trace" code:(NSInteger)state userInfo:details];
}

static void PXPublishTraceState(PXCloneTraceState state, NSError *error,
                                void (^completion)(PXCloneTraceState, NSError *)) {
    int token = PXTraceStateToken();
    if (token >= 0) {
        uint64_t current = 0;
        notify_get_state(token, &current);
        if (current != (uint64_t)state) {
            notify_set_state(token, (uint64_t)state);
            notify_post(PXCloneTraceNotification.UTF8String);
        }
    }
    if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(state, error); });
}

static BOOL PXTraceDirectoryIsCurrent(NSString *root, NSString *parent, int directory,
                                      struct stat identity) {
    if (!PXCloneValidateRoot(root, NULL)) return NO;
    struct stat pathDirectory, pinned;
    if (stat(parent.fileSystemRepresentation, &pathDirectory) != 0 ||
        fstat(directory, &pinned) != 0 || pathDirectory.st_dev != pinned.st_dev ||
        pathDirectory.st_ino != pinned.st_ino) return NO;
    char canonical[PATH_MAX];
    if (!realpath(parent.fileSystemRepresentation, canonical)) return NO;
    // Same rule as EnsureStorage: var/ may resolve back to the live domain, so
    // require AppGroup membership of the resolved directory, not a prefix.
    return PXCloneRootIsAppGroup(canonical);
}

@implementation PXCloneTrace

+ (PXCloneTraceState)state {
    uint64_t state = 0;
    int token = PXTraceStateToken();
    if (token < 0 || notify_get_state(token, &state) != NOTIFY_STATUS_OK ||
        state > (uint64_t)PXCloneTraceStateReadbackFailure) return PXCloneTraceStateUnknown;
    return (PXCloneTraceState)state;
}

+ (NSString *)descriptionForState:(PXCloneTraceState)state {
    switch (state) {
        case PXCloneTraceStatePersisted: return @"切换记录已保存并读回";
        case PXCloneTraceStatePathFailure: return @"切换记录未保存：隐根路径或目录不可用";
        case PXCloneTraceStateSerializationFailure: return @"切换记录未保存：记录编码失败";
        case PXCloneTraceStateWriteFailure: return @"切换记录未保存：文件写入失败";
        case PXCloneTraceStateReadbackFailure: return @"切换记录未确认：文件读回失败";
        default: return @"本次尚未确认切换记录落盘";
    }
}

+ (void)writeEvents:(NSArray<NSDictionary *> *)events
        completion:(void (^)(PXCloneTraceState, NSError *))completion {
    static dispatch_queue_t worker;
    static NSString *tracePath;
    static NSString *rootPath;
    static int directory = -1;
    static struct stat rootIdentity;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ worker = dispatch_queue_create("com.niubiprass.parallelxclone.trace-writer", DISPATCH_QUEUE_SERIAL); });
    NSArray *snapshot = [events copy];
    void (^done)(PXCloneTraceState, NSError *) = [completion copy];
    dispatch_async(worker, ^{
        NSError *error = nil;
        if (directory < 0) {
            if (!PXCloneEnsureStorage(&error)) {
                PXPublishTraceState(PXCloneTraceStatePathFailure,
                    PXTraceError(PXCloneTraceStatePathFailure, @"隐根目录初始化失败", error), done);
                return;
            }
            rootPath = PXCloneActiveRoot(&error);
            tracePath = PXCloneCurrentTracePath(&error);
            if (!rootPath.length || !tracePath.length ||
                stat(rootPath.fileSystemRepresentation, &rootIdentity) != 0) {
                PXPublishTraceState(PXCloneTraceStatePathFailure,
                    PXTraceError(PXCloneTraceStatePathFailure, @"隐根记录路径解析失败", error), done);
                return;
            }
            directory = open(tracePath.stringByDeletingLastPathComponent.fileSystemRepresentation,
                             O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
            if (directory < 0) {
                NSError *cause = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil];
                PXPublishTraceState(PXCloneTraceStatePathFailure,
                    PXTraceError(PXCloneTraceStatePathFailure, @"隐根记录目录无法固定", cause), done);
                return;
            }
        }
        NSString *parent = tracePath.stringByDeletingLastPathComponent;
        if (!PXTraceDirectoryIsCurrent(rootPath, parent, directory, rootIdentity)) {
            PXPublishTraceState(PXCloneTraceStatePathFailure,
                PXTraceError(PXCloneTraceStatePathFailure, @"缓存隐根或目录已变化，未改写其他位置", nil), done);
            return;
        }
        NSArray *limited = snapshot.count > 32 ?
            [snapshot subarrayWithRange:NSMakeRange(snapshot.count - 32, 32)] : snapshot;
        NSDictionary *document = @{ @"CXLaunchTrace": limited ?: @[] };
        NSData *data = [NSPropertyListSerialization dataWithPropertyList:document
                         format:NSPropertyListBinaryFormat_v1_0 options:0 error:&error];
        if (!data) {
            PXPublishTraceState(PXCloneTraceStateSerializationFailure,
                PXTraceError(PXCloneTraceStateSerializationFailure, @"记录编码失败", error), done);
            return;
        }
        int errorNumber = 0;
        PXCloneTraceIOResult result = PXCloneWriteTraceAt(directory, tracePath.lastPathComponent.fileSystemRepresentation,
                                                        data.bytes, data.length, &errorNumber);
        if (result != PXCloneTraceIOVerified) {
            PXCloneTraceState state = result == PXCloneTraceIOReadbackFailed ?
                                     PXCloneTraceStateReadbackFailure : PXCloneTraceStateWriteFailure;
            NSError *cause = [NSError errorWithDomain:NSPOSIXErrorDomain code:errorNumber userInfo:nil];
            PXPublishTraceState(state, PXTraceError(state, @"记录原子写入或逐字节读回失败", cause), done);
            return;
        }
        if (!PXTraceDirectoryIsCurrent(rootPath, parent, directory, rootIdentity)) {
            PXPublishTraceState(PXCloneTraceStatePathFailure,
                PXTraceError(PXCloneTraceStatePathFailure, @"记录目录身份变化，未确认保存", nil), done);
            return;
        }
        PXPublishTraceState(PXCloneTraceStatePersisted, nil, done);
    });
}

@end
