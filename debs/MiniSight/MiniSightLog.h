#ifndef MINISIGHT_LOG_H
#define MINISIGHT_LOG_H
#import <Foundation/Foundation.h>

/// Async, bounded local diagnostics. Disabled by default. No credential ever
/// passes through here; callers log status/counters only.
void MSDiagConfigure(BOOL enabled, NSString * _Nullable container);
void MSDiag(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
#endif
