#ifndef MINISIGHT_APPROVAL_SUMMARY_H
#define MINISIGHT_APPROVAL_SUMMARY_H
#import <Foundation/Foundation.h>
#include "MiniSightApprovalSummaryCore.h"

/// action is presentation text from confirm.json, not a trustworthy tool name.
/// Never derive effects from that title. No change to the approval protocol.
static NSString *MiniSightDescribeCommand(NSString *action, NSString *command) {
    (void)action;
    MSApprovalSummary usage = MSApprovalDescribe(command.UTF8String);
    NSString *title = [NSString stringWithUTF8String:usage.title];
    NSString *purpose = [NSString stringWithUTF8String:usage.purpose];
    NSString *risk = [NSString stringWithUTF8String:usage.risk];
    NSString *summary = [NSString stringWithFormat:@"%@\n%@\n%@", title, purpose, risk];
    // The existing pet bubble scrolls. Until a separate detail control exists,
    // retain the ENTIRE authorization for uncertain commands, without clipping.
    // Known actions stay concise; the native dialog has a collapsed detail view.
    if (usage.unknown) return [summary stringByAppendingFormat:@"\n\n完整命令（可滚动查看）：\n%@", command ?: @""];
    return summary;
}
#endif
