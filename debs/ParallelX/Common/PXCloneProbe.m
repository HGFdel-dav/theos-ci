#import "PXCloneProbe.h"
#import "PXClonePaths.h"
#include <fcntl.h>
#include <string.h>
#include <unistd.h>

static NSString *const PXProbeRelative = @"/var/mobile/Library/Caches/parallelx-probe.log";
static const off_t PXProbeLimit = 160 * 1024;

@implementation PXCloneProbe

+ (NSString *)path {
    NSError *error = nil;
    NSString *root = PXCloneActiveRoot(&error);
    if (!root.length) {
        // Fresh respring may not have a root yet; the logical path is a
        // read-back-only fallback and still resolves through RootHide.
        root = @"";
    }
    NSString *path = [root stringByAppendingString:PXProbeRelative];
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *dir = path.stringByDeletingLastPathComponent;
    if (![fm fileExistsAtPath:dir])
        [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:NULL];
    return path;
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
