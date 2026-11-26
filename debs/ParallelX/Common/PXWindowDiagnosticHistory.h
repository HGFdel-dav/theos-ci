#pragma once
#import <Foundation/Foundation.h>
#import "PXWindowDiagnosticPolicy.h"

static inline BOOL PXWMDiagnosticValidEvent(id item) {
    if (![item isKindOfClass:NSDictionary.class]) return NO;
    NSString *event=item[@"event"], *build=item[@"build"], *session=item[@"session"];
    NSDictionary *state=item[@"state"];
    if (![event isKindOfClass:NSString.class] || !event.length || event.length>96 ||
        ![build isKindOfClass:NSString.class] || build.length>64 ||
        (session && (![session isKindOfClass:NSString.class] || session.length!=36)) ||
        ![item[@"time"] isKindOfClass:NSNumber.class] || !isfinite([item[@"time"] doubleValue]) ||
        ![item[@"pid"] isKindOfClass:NSNumber.class] ||
        (session && ![item[@"sequence"] isKindOfClass:NSNumber.class]) ||
        ![state isKindOfClass:NSDictionary.class] || state.count>128) return NO;
    for (id key in state)
        if (![key isKindOfClass:NSString.class] || [key length]>64 ||
            ![state[key] isKindOfClass:NSNumber.class] || !isfinite([state[key] doubleValue])) return NO;
    return YES;
}
static inline BOOL PXWMDiagnosticValidRecent(id value) {
    if (![value isKindOfClass:NSArray.class] || [value count]>PXWMDiagnosticRecentLimit) return NO;
    for (id event in value) if (!PXWMDiagnosticValidEvent(event)) return NO;
    return YES;
}
static inline BOOL PXWMDiagnosticSameWindow(NSDictionary *a,NSDictionary *b) {
    NSDictionary *x=a[@"state"], *y=b[@"state"];
    return a[@"session"] && [a[@"session"] isEqual:b[@"session"]] &&
        [a[@"pid"] isEqual:b[@"pid"]] && x[@"appHash"] && x[@"openSerial"] &&
        [x[@"appHash"] isEqual:y[@"appHash"]] && [x[@"openSerial"] isEqual:y[@"openSerial"]];
}
static inline BOOL PXWMDiagnosticValidArchive(id archive) {
    if (![archive isKindOfClass:NSDictionary.class] || ![archive[@"schema"] isEqual:@1] ||
        ![archive[@"incidents"] isKindOfClass:NSArray.class] ||
        [archive[@"incidents"] count]>PXWMDiagnosticIncidentLimit) return NO;
    for (id item in archive[@"incidents"]) {
        if (![item isKindOfClass:NSDictionary.class] || !PXWMDiagnosticValidEvent(item[@"trigger"]) ||
            ![item[@"before"] isKindOfClass:NSArray.class] || [item[@"before"] count]>PXWMDiagnosticBeforeLimit ||
            ![item[@"after"] isKindOfClass:NSArray.class] || [item[@"after"] count]>PXWMDiagnosticAfterLimit) return NO;
        for (NSString *group in @[@"before",@"after"])
            for (id e in item[group])
                if (!PXWMDiagnosticValidEvent(e) || !PXWMDiagnosticSameWindow(e,item[@"trigger"])) return NO;
        id last=item[@"lastOutcome"];
        if (last && (!PXWMDiagnosticValidEvent(last) || !PXWMDiagnosticSameWindow(last,item[@"trigger"]))) return NO;
        for (NSString *flag in @[@"recovered",@"closed"]) {
            id value=item[flag];
            if (value && (![value isKindOfClass:NSNumber.class] ||
                ([value doubleValue]!=0 && [value doubleValue]!=1))) return NO;
        }
    }
    return YES;
}
/* Persistent independent incidents: ordinary events update only the twelve
 * post-fault slots for their exact session/window. They never evict an incident.
 * A new faulty opening may evict the oldest of four, explicitly bounded. */
static inline NSDictionary *PXWMDiagnosticMerge(NSDictionary *previous,NSArray *recent,
                                               NSDictionary *event) {
    NSMutableArray *incidents=[previous[@"incidents"] mutableCopy] ?: [NSMutableArray array];
    BOOL found=NO;
    for (NSUInteger cursor=incidents.count;cursor>0;cursor--) {
        NSUInteger i=cursor-1;
        NSDictionary *old=incidents[i], *trigger=old[@"trigger"];
        if (!PXWMDiagnosticSameWindow(trigger,event)) continue;
        BOOL newFault=[event[@"state"][@"diagIncident"] boolValue] &&
            ![trigger[@"sequence"] isEqual:event[@"sequence"]] &&
            ([old[@"recovered"] boolValue] || [old[@"closed"] boolValue] ||
             [event[@"time"] doubleValue]-[trigger[@"time"] doubleValue]>120);
        if (newFault) break;
        found=YES;
        NSMutableArray *after=[old[@"after"] mutableCopy];
        BOOL duplicate=[trigger[@"sequence"] isEqual:event[@"sequence"]];
        for (NSDictionary *entry in after) if ([entry[@"sequence"] isEqual:event[@"sequence"]]) duplicate=YES;
        if (!duplicate && PXWMDiagnosticMayAppendAfter((unsigned)after.count,
                [trigger[@"time"] doubleValue],[event[@"time"] doubleValue])) {
            [after addObject:event]; NSMutableDictionary *next=[old mutableCopy];
            next[@"after"]=after; incidents[i]=next;
        }
        NSString *name=event[@"event"];
        BOOL contentRecovered=[name isEqual:@"content_geometry_probe"] &&
            [event[@"state"][@"measured"] boolValue] && ![event[@"state"][@"diagIncident"] boolValue] &&
            [event[@"state"][@"bundleMatch"] boolValue] && [event[@"state"][@"canvasMatch"] boolValue] &&
            [event[@"state"][@"cardMatch"] boolValue];
        BOOL closed=[name isEqual:@"native_close_no_transient_save"];
        BOOL outcome=[name isEqual:@"restore_postlayout_geometry_verified"] || closed || contentRecovered;
        double age=[event[@"time"] doubleValue]-[trigger[@"time"] doubleValue];
        if (outcome && age>=0 && age<=120) {
            NSMutableDictionary *next=[incidents[i] mutableCopy];
            next[@"lastOutcome"]=event;
            if (contentRecovered) next[@"recovered"]=@YES;
            if (closed) next[@"closed"]=@YES;
            incidents[i]=next;
        }
        break;
    }
    if (!found && [event[@"state"][@"diagIncident"] boolValue] &&
        event[@"state"][@"appHash"] && event[@"state"][@"openSerial"] && event[@"session"]) {
        NSMutableArray *before=[NSMutableArray array];
        for (NSDictionary *entry in recent) {
            if (PXWMDiagnosticSameWindow(entry,event) &&
                ![entry[@"sequence"] isEqual:event[@"sequence"]]) [before addObject:entry];
        }
        if (before.count>PXWMDiagnosticBeforeLimit)
            [before removeObjectsInRange:NSMakeRange(0,before.count-PXWMDiagnosticBeforeLimit)];
        [incidents addObject:@{@"trigger":event,@"before":before,@"after":@[]}];
        while (incidents.count>PXWMDiagnosticIncidentLimit) [incidents removeObjectAtIndex:0];
    }
    return @{@"schema":@1,@"incidents":incidents};
}
