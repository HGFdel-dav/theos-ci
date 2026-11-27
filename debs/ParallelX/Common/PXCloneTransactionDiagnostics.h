#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <string.h>
#include <math.h>

enum { PXCloneTransactionLimit = 4, PXCloneTransactionStageLimit = 40 };
/* Shared production policy: visibility samples never consume an edge slot.
 * Keep the first edge and update repeated observations in place. Reserve two
 * terminal slots even for unexpected excess stages; overflow is explicit. */
typedef struct { const char *stage; unsigned retry; } PXCloneTransactionEdgeKey;
static inline bool PXCloneTransactionImportant(const char *stage) {
    if (!stage) return false;
    return strcmp(stage, "open_visibility") && strcmp(stage, "open_detail") &&
        strcmp(stage, "open_before_retry_or_failure") && strcmp(stage, "open_before_cleanup") &&
        strcmp(stage, "latest_same_target") && strcmp(stage, "queued_latest_target");
}
static inline int PXCloneTransactionSlot(const PXCloneTransactionEdgeKey *keys, size_t count,
                                         const char *stage, unsigned retry) {
    if (!PXCloneTransactionImportant(stage) || count > PXCloneTransactionStageLimit || (count && !keys)) return -1;
    for (size_t i = 0; i < count; ++i)
        if (keys[i].retry == retry && !strcmp(keys[i].stage, stage)) return (int)i;
    bool terminal = !strcmp(stage, "done") || !strcmp(stage, "transaction_finished");
    return count < (size_t)(terminal ? PXCloneTransactionStageLimit : PXCloneTransactionStageLimit - 2) ? (int)count : -1;
}
static inline double PXCloneTransactionDeltaMS(double before, double now) {
    return isfinite(before) && isfinite(now) && now >= before ? (now - before) * 1000.0 : -1.0;
}

#ifdef __OBJC__
#import <Foundation/Foundation.h>
static inline NSString *PXCloneTransactionID(NSDictionary *record) {
    return [NSString stringWithFormat:@"%@:%@", record[@"session"], record[@"token"]];
}
static inline BOOL PXCloneTransactionNumber(id value,BOOL integer) {
    if (![value isKindOfClass:NSNumber.class]) return NO;
    double n=[value doubleValue];
    return isfinite(n) && n>=0 && (!integer || floor(n)==n);
}
static inline BOOL PXCloneTransactionsValid(id archive) {
    if (![archive isKindOfClass:NSArray.class] || [archive count] > PXCloneTransactionLimit) return NO;
    NSMutableSet *ids = [NSMutableSet set];
    for (id row in archive) {
        if (![row isKindOfClass:NSDictionary.class] || ![row[@"schema"] isEqual:@1] ||
            ![row[@"session"] isKindOfClass:NSString.class] || ![[NSUUID alloc] initWithUUIDString:row[@"session"]] ||
            !PXCloneTransactionNumber(row[@"token"],YES) || ![row[@"token"] unsignedLongLongValue] ||
            ![row[@"stages"] isKindOfClass:NSArray.class] || [row[@"stages"] count]>PXCloneTransactionStageLimit ||
            ![row[@"phaseDurationsMS"] isKindOfClass:NSDictionary.class] || [row[@"phaseDurationsMS"] count]>8 ||
            !PXCloneTransactionNumber(row[@"phase"],YES) || [row[@"phase"] unsignedIntValue]>7 ||
            ![@[@"in_progress",@"success",@"failed",@"superseded"] containsObject:row[@"status"]] ||
            ![row[@"bundle"] isKindOfClass:NSString.class] || [row[@"bundle"] length]>255) return NO;
        for (NSString *key in @[@"startMonotonic",@"lastMonotonic",@"phaseStartedMonotonic",@"lastEdgeMonotonic",@"elapsedMS"])
            if (!PXCloneTransactionNumber(row[key],NO)) return NO;
        for (id phase in row[@"phaseDurationsMS"])
            if (![@[@"0",@"1",@"2",@"3",@"4",@"5",@"6",@"7"] containsObject:phase] ||
                !PXCloneTransactionNumber(row[@"phaseDurationsMS"][phase],NO)) return NO;
        for (NSString *key in @[@"visibilitySamples",@"droppedStages",@"retryCount",@"completed"])
            if (!PXCloneTransactionNumber(row[key],YES)) return NO;
        if ([row[@"completed"] unsignedIntValue]>1) return NO;
        for (id edge in row[@"stages"]) {
            if (![edge isKindOfClass:NSDictionary.class] || ![edge[@"stage"] isKindOfClass:NSString.class] ||
                ![edge[@"stage"] length] || [edge[@"stage"] length]>80) return NO;
            for (NSString *key in @[@"retry",@"phase",@"count"])
                if (!PXCloneTransactionNumber(edge[key],YES)) return NO;
            for (NSString *key in @[@"elapsedMS",@"lastElapsedMS",@"sincePreviousStageMS",@"phaseElapsedMS"])
                if (!PXCloneTransactionNumber(edge[key],NO)) return NO;
            if ([edge[@"phase"] unsignedIntValue]>7) return NO;
        }
        NSString *identifier=PXCloneTransactionID(row);
        if ([ids containsObject:identifier]) return NO;
        [ids addObject:identifier];
    }
    return YES;
}
/* Pure immutable summary builder; input is already-observed numbers only.
 * Every transaction (including fast success and unfinished/cancelled) is kept.
 * No wall-clock duration, process query, account read or I/O in this helper. */
static inline NSArray *PXCloneTransactionObserve(NSArray *previous, NSDictionary *event) {
    NSString *session = event[@"session"], *raw = event[@"stage"];
    if (![session isKindOfClass:NSString.class] || ![[NSUUID alloc] initWithUUIDString:session] ||
        ![raw isKindOfClass:NSString.class] || !raw.length || raw.length>192 ||
        !PXCloneTransactionNumber(event[@"token"],YES) || ![event[@"token"] unsignedLongLongValue] ||
        !PXCloneTransactionNumber(event[@"phase"],YES) || [event[@"phase"] unsignedIntValue]>7 ||
        !PXCloneTransactionNumber(event[@"retry"],YES) ||
        ![event[@"monotonic"] isKindOfClass:NSNumber.class]) return previous;
    double now = [event[@"monotonic"] doubleValue];
    if (!isfinite(now) || now < 0) return previous;
    NSString *stage = [[raw componentsSeparatedByString:@" "] firstObject];
    NSMutableArray *rows = [previous mutableCopy] ?: [NSMutableArray array];
    NSString *identifier = PXCloneTransactionID(event);
    NSUInteger index = [rows indexOfObjectPassingTest:^BOOL(NSDictionary *row, NSUInteger i, BOOL *stop) {
        (void)i; (void)stop; return [PXCloneTransactionID(row) isEqual:identifier];
    }];
    if (index == NSNotFound && ![stage isEqual:@"request"]) return previous;
    NSMutableDictionary *row = index == NSNotFound ? [@{
        @"schema": @1, @"session": session, @"token": event[@"token"],
        @"bundle": event[@"bundle"] ?: @"", @"targetHash": event[@"targetHash"] ?: @0,
        @"startMonotonic": @(now), @"lastMonotonic": @(now), @"lastEdgeMonotonic": @(now),
        @"phaseStartedMonotonic": @(now), @"phase": event[@"phase"] ?: @0,
        @"stages": @[], @"phaseDurationsMS": @{}, @"status": @"in_progress",
        @"visibilitySamples": @0, @"droppedStages": @0, @"completed": @NO
    } mutableCopy] : [rows[index] mutableCopy];
    if ([row[@"completed"] boolValue]) return previous;
    double delta = PXCloneTransactionDeltaMS([row[@"lastMonotonic"] doubleValue], now);
    if (delta < 0) return previous;
    double elapsed = PXCloneTransactionDeltaMS([row[@"startMonotonic"] doubleValue], now);
    NSMutableDictionary *durations = [row[@"phaseDurationsMS"] mutableCopy];
    NSString *oldPhase = [row[@"phase"] stringValue];
    durations[oldPhase] = @([durations[oldPhase] doubleValue] + delta);
    row[@"phaseDurationsMS"] = [durations copy];
    NSNumber *phase = event[@"phase"] ?: @0;
    if (![row[@"phase"] isEqual:phase]) row[@"phaseStartedMonotonic"] = @(now);
    row[@"phase"] = phase;
    row[@"lastMonotonic"] = @(now); row[@"elapsedMS"] = @(elapsed);
    NSMutableArray *edges = [row[@"stages"] mutableCopy];
    PXCloneTransactionEdgeKey keys[PXCloneTransactionStageLimit] = {0};
    for (NSUInteger i = 0; i < edges.count; ++i)
        keys[i] = (PXCloneTransactionEdgeKey){[edges[i][@"stage"] UTF8String], [edges[i][@"retry"] unsignedIntValue]};
    unsigned retry = [event[@"retry"] unsignedIntValue];
    int slot = PXCloneTransactionSlot(keys, edges.count, stage.UTF8String, retry);
    if (slot >= 0) {
        BOOL repeated = (NSUInteger)slot < edges.count;
        NSMutableDictionary *edge = repeated ? [edges[slot] mutableCopy] : [@{
            @"stage": stage, @"elapsedMS": @(elapsed), @"phase": phase, @"retry": @(retry),
            @"sincePreviousStageMS": @(PXCloneTransactionDeltaMS([row[@"lastEdgeMonotonic"] doubleValue], now)),
            @"phaseElapsedMS": @(PXCloneTransactionDeltaMS([row[@"phaseStartedMonotonic"] doubleValue], now)), @"count": @0
        } mutableCopy];
        edge[@"lastElapsedMS"] = @(elapsed); edge[@"code"] = event[@"code"] ?: @0;
        edge[@"count"] = @([edge[@"count"] unsignedIntegerValue] + 1);
        if ([event[@"processPID"] isKindOfClass:NSNumber.class]) edge[@"processPID"] = event[@"processPID"];
        if (repeated) edges[slot] = [edge copy];
        else { [edges addObject:[edge copy]]; row[@"lastEdgeMonotonic"] = @(now); }
    } else if ([stage isEqual:@"open_visibility"]) {
        row[@"visibilitySamples"] = @([row[@"visibilitySamples"] unsignedIntegerValue] + 1);
        row[@"lastVisibilityMS"] = @(elapsed);
    } else if (PXCloneTransactionImportant(stage.UTF8String)) {
        row[@"droppedStages"] = @([row[@"droppedStages"] unsignedIntegerValue] + 1);
    }
    row[@"stages"] = [edges copy];
    row[@"retryCount"] = @(MAX([row[@"retryCount"] unsignedIntValue], retry));
    if ([event[@"code"] integerValue] != 0) row[@"hadErrorOrRetry"] = @YES;
    if ([stage isEqual:@"failed"]) row[@"status"] = @"failed";
    if ([stage isEqual:@"done"] && [raw rangeOfString:@"ok=1"].location != NSNotFound) row[@"status"] = @"success";
    if ([stage isEqual:@"transaction_finished"]) {
        if ([row[@"status"] isEqual:@"in_progress"]) row[@"status"] = @"superseded";
        row[@"completed"] = @YES;
    }
    if (index == NSNotFound) [rows addObject:[row copy]]; else rows[index] = [row copy];
    while (rows.count > PXCloneTransactionLimit) [rows removeObjectAtIndex:0];
    return [rows copy];
}
/* Worker-queue merge does not compare uptime across process sessions. New
 * session+token pairs append; snapshots replace their own transaction only. */
static inline NSArray *PXCloneTransactionsMerge(NSArray *saved, NSArray *current) {
    NSMutableArray *result = [saved mutableCopy] ?: [NSMutableArray array];
    for (NSDictionary *row in current) {
        NSString *identifier = PXCloneTransactionID(row);
        NSUInteger index = [result indexOfObjectPassingTest:^BOOL(NSDictionary *old, NSUInteger i, BOOL *stop) {
            (void)i; (void)stop; return [PXCloneTransactionID(old) isEqual:identifier];
        }];
        if (index == NSNotFound) [result addObject:row]; else result[index] = row;
        while (result.count > PXCloneTransactionLimit) [result removeObjectAtIndex:0];
    }
    return [result copy];
}
#endif
