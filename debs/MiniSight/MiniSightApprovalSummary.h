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
    // Presentation only: keep the original request in the existing transport,
    // but never concatenate executable text into the user-facing approval.
    return summary;
}
#endif
