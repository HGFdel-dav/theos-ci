#pragma once
#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

enum { PXCloneFailureLimit = 4, PXCloneFailureEventLimit = 12,
       PXCloneTraceReadLimit = 512 * 1024 };
typedef struct { const char *identifier; double time; } PXCloneFailureKey;
/* Keep newest unique failed transactions, oldest first. Success events never
 * enter this input. Shared by the plist adapter and executable host tests. */
static inline size_t PXCloneSelectFailures(const PXCloneFailureKey *keys, size_t count,
                                           size_t selected[PXCloneFailureLimit]) {
    size_t used = 0;
    if (!keys || !selected) return 0;
    for (size_t i = 0; i < count; ++i) {
        if (!keys[i].identifier || strlen(keys[i].identifier) != 36 ||
            !isfinite(keys[i].time) || keys[i].time <= 0) continue;
        bool duplicate = false;
        for (size_t j = 0; j < used; ++j)
            if (!strcmp(keys[selected[j]].identifier, keys[i].identifier)) duplicate = true;
        if (duplicate) continue;
        size_t position = 0;
        while (position < used && keys[selected[position]].time <= keys[i].time) ++position;
        if (used == PXCloneFailureLimit) {
            if (!position) continue;
            for (size_t j = 1; j < used; ++j) selected[j - 1] = selected[j];
            --used; --position;
        }
        for (size_t j = used; j > position; --j) selected[j] = selected[j - 1];
        selected[position] = i;
        ++used;
    }
    return used;
}

#ifdef __OBJC__
#import <Foundation/Foundation.h>
/* Import only summaries still present in an old <=32-event trace. Missing
 * diagnostics remain explicitly legacy; never invent a historical gate. */
static inline NSArray *PXCloneTraceImportLegacyEvents(NSArray *events) {
    NSMutableArray *result = [NSMutableArray array];
    NSUInteger start = events.count > 32 ? events.count - 32 : 0;
    for (NSUInteger i = start; i < events.count; ++i) {
        id item = events[i];
        if (![item isKindOfClass:NSDictionary.class]) continue;
        NSMutableDictionary *event = [item mutableCopy];
        if ([event[@"stage"] isEqual:@"failed"] && !event[@"failureID"]) {
            event[@"failureID"] = NSUUID.UUID.UUIDString;
            event[@"summary"] = @{ @"legacy": @YES };
        }
        [result addObject:event];
    }
    return result;
}
/* Same adapter is linked by the optional Apple Foundation integration test;
 * portable C tests execute its selection and pinned file I/O policy. */
static inline NSArray<NSDictionary *> *PXCloneTraceMergeFailures(NSArray *previous, NSArray *events) {
    NSMutableArray<NSDictionary *> *records = [NSMutableArray array];
    for (id record in previous) {
        if ([record isKindOfClass:NSDictionary.class] && records.count < PXCloneFailureLimit)
            [records addObject:record];
    }
    NSArray *bounded = events.count > 32 ? [events subarrayWithRange:NSMakeRange(events.count - 32, 32)] : events;
    for (NSDictionary *event in bounded) {
        if (![event isKindOfClass:NSDictionary.class] || ![event[@"stage"] isEqual:@"failed"] ||
            ![event[@"code"] isKindOfClass:NSNumber.class] || [event[@"code"] integerValue] <= 0 ||
            ![event[@"failureID"] isKindOfClass:NSString.class]) continue;
        NSMutableArray *transaction = [NSMutableArray array];
        for (NSDictionary *item in bounded)
            if ([item isKindOfClass:NSDictionary.class] && [item[@"token"] isEqual:event[@"token"]] &&
                [item[@"time"] isKindOfClass:NSNumber.class] &&
                [item[@"time"] doubleValue] <= [event[@"time"] doubleValue]) [transaction addObject:item];
        if (transaction.count > PXCloneFailureEventLimit)
            [transaction removeObjectsInRange:NSMakeRange(0, transaction.count - PXCloneFailureEventLimit)];
        NSMutableDictionary *record = [event mutableCopy];
        record[@"events"] = transaction;
        [records addObject:record];
    }
    PXCloneFailureKey keys[PXCloneFailureLimit + 32] = {0};
    for (NSUInteger index = 0; index < records.count; ++index) {
        id identifier = records[index][@"failureID"], time = records[index][@"time"];
        if ([identifier isKindOfClass:NSString.class] && [time isKindOfClass:NSNumber.class])
            keys[index] = (PXCloneFailureKey){ [identifier UTF8String], [time doubleValue] };
    }
    size_t selected[PXCloneFailureLimit];
    size_t count = PXCloneSelectFailures(keys, records.count, selected);
    NSMutableArray *result = [NSMutableArray array];
    for (size_t index = 0; index < count; ++index) [result addObject:records[selected[index]]];
    return [result copy];
}
#endif

typedef enum { PXCloneTraceReadOK, PXCloneTraceReadMissing, PXCloneTraceReadFailed } PXCloneTraceReadResult;
/* Read only the pinned directory, never follow a final symlink, bound memory,
 * and reject replacement/size races. Caller owns *bytes only on ReadOK. */
static inline PXCloneTraceReadResult PXCloneReadTraceAt(int directory, const char *name,
                                                       void **bytes, size_t *length,
                                                       int *errorNumber) {
    if (bytes) *bytes = NULL;
    if (length) *length = 0;
    if (errorNumber) *errorNumber = 0;
    if (directory < 0 || !name || !name[0] || strchr(name, '/') ||
        !strcmp(name, ".") || !strcmp(name, "..") || !bytes || !length) {
        if (errorNumber) *errorNumber = EINVAL;
        return PXCloneTraceReadFailed;
    }
    int fd = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK);
    if (fd < 0) {
        if (errno == ENOENT) return PXCloneTraceReadMissing;
        if (errorNumber) *errorNumber = errno;
        return PXCloneTraceReadFailed;
    }
    struct stat before, after, path;
    void *buffer = NULL;
    if (fstat(fd, &before) != 0) goto failed;
    if (!S_ISREG(before.st_mode) || before.st_size <= 0 || before.st_size > PXCloneTraceReadLimit) {
        errno = EFBIG; goto failed;
    }
    buffer = malloc((size_t)before.st_size);
    if (!buffer) { errno = ENOMEM; goto failed; }
    size_t consumed = 0;
    while (consumed < (size_t)before.st_size) {
        ssize_t n = read(fd, (char *)buffer + consumed, (size_t)before.st_size - consumed);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) { errno = EIO; goto failed; }
        consumed += (size_t)n;
    }
    if (fstat(fd, &after) != 0 || fstatat(directory, name, &path, AT_SYMLINK_NOFOLLOW) != 0) goto failed;
    if (before.st_size != after.st_size || before.st_dev != path.st_dev ||
        before.st_ino != path.st_ino || !S_ISREG(path.st_mode)) { errno = EIO; goto failed; }
    if (close(fd) != 0) { fd = -1; goto failed; }
    *bytes = buffer;
    *length = consumed;
    return PXCloneTraceReadOK;
failed: {
        int saved = errno ? errno : EIO;
        if (fd >= 0) close(fd);
        free(buffer);
        if (errorNumber) *errorNumber = saved;
        return PXCloneTraceReadFailed;
    }
}
