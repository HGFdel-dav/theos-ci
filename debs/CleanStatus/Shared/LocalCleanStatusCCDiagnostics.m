#import "LocalCleanStatusCCDiagnostics.h"
#import "LocalCleanStatusPaths.h"
#import "LocalCleanStatusCCEnvironment.h"
#import <sys/file.h>
#import <fcntl.h>
#import <errno.h>
#import <unistd.h>

void local_cleanstatus_ccLog(NSString *event, NSString *reason) {
    if (!event.length || event.length > 64 || reason.length > 160) return;
    if ([event containsString:@"\n"] || [reason containsString:@"\n"]) return;
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ queue=dispatch_queue_create("com.local.cleanstatus.cc-log",DISPATCH_QUEUE_SERIAL); });
    NSString *row=[NSString stringWithFormat:@"%.3f %@ %@\n",NSDate.date.timeIntervalSince1970,event,reason ?: @"-"];
    dispatch_async(queue, ^{
        @autoreleasepool {
            NSString *root=local_cleanstatus_ccRoot();
            if (!root.length) return;
            NSString *directory=[root stringByAppendingPathComponent:@"var/mobile/Library/Caches/com.local.cleanstatus"];
            if (!local_cleanstatus_pathInsideRoot(directory,root)) return;
            if (![NSFileManager.defaultManager createDirectoryAtPath:directory
                withIntermediateDirectories:YES attributes:nil error:nil]) return;
            NSString *path=[directory stringByAppendingPathComponent:@"control-center.log"];
            if (!local_cleanstatus_pathInsideRoot(path,root)) return;
            int fd=open(path.fileSystemRepresentation,O_WRONLY|O_APPEND|O_CREAT|O_NOFOLLOW|O_CLOEXEC,0600);
            if (fd<0) return;
            if (flock(fd,LOCK_EX|LOCK_NB)!=0) { close(fd); return; }
            struct stat st;
            if (fstat(fd,&st)!=0 || !S_ISREG(st.st_mode) || st.st_nlink!=1) {
                flock(fd,LOCK_UN); close(fd); return;
            }
            if (st.st_size>65536 && ftruncate(fd,0)!=0) {
                flock(fd,LOCK_UN); close(fd); return;
            }
            NSData *data=[row dataUsingEncoding:NSUTF8StringEncoding];
            const char *bytes=data.bytes;
            size_t remaining=data.length;
            while (remaining) {
                ssize_t written=write(fd,bytes,remaining);
                if (written<0 && errno==EINTR) continue;
                if (written<=0) break;
                bytes+=written; remaining-=(size_t)written;
            }
            flock(fd,LOCK_UN); close(fd);
        }
    });
}
