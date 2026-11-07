#import "PXCloneProbe.h"
#import "PXClonePaths.h"
#include <fcntl.h>
#include <string.h>
#include <unistd.h>

static NSString *const PXProbeRelative = @"/var/mobile/Library/Caches/parallelx-probe.log";
static const off_t PXProbeLimit = 160 * 1024;

// Sandboxed apps cannot write /var/mobile/Library/Caches (only SpringBoard and
// daemons can). Fall back to the process's own tmp dir so app-side events are
// still recorded; the file name carries no app content.
static NSString *PXProbeChosenPath(void) {
    static NSString *chosen;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *shared = nil;
        NSError *error = nil;
        NSString *root = PXCloneActiveRoot(&error);
        if (root.length) shared = [root stringByAppendingString:PXProbeRelative];
        NSFileManager *fm = NSFileManager.defaultManager;
        if (shared.length) {
            [fm createDirectoryAtPath:shared.stringByDeletingLastPathComponent
                withIntermediateDirectories:YES attributes:nil error:NULL];
            int fd = open(shared.fileSystemRepresentation, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0600);
            if (fd >= 0) { close(fd); chosen = shared; }
        }
        if (!chosen.length) {
            NSString *tmp = NSTemporaryDirectory();
            if (tmp.length) chosen = [tmp stringByAppendingPathComponent:@"parallelx-probe.log"];
        }
    });
    return chosen;
}

@implementation PXCloneProbe

+ (NSString *)path {
    return PXProbeChosenPath() ?: @"";
}

+ (void)log:(NSString *)format, ... {
    va_list arguments;
    va_start(arguments, format);
    NSString *body = [[NSString alloc] initWithFormat:format arguments:arguments];
    va_end(arguments);

    NSString *path = [self path];
    if (!path.length) return;
    NSFileManager *fm = NSFileManager.defaultManager;
    NSDictionary *attributes = [fm attributesOfItemAtPath:path error:NULL];
    if ([attributes[NSFileSize] longLongValue] > PXProbeLimit)
        [fm removeItemAtPath:path error:NULL];

    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.dateFormat = @"HH:mm:ss.SSS";
    NSString *line = [NSString stringWithFormat:@"%@ %@\n", [formatter stringFromDate:NSDate.date], body];
    NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
    if (!data) return;

    int fd = open(path.fileSystemRepresentation, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0600);
    if (fd < 0) return;
    ssize_t written = write(fd, data.bytes, data.length);
    (void)written;
    close(fd);
}

@end
