#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

// 诊断：结构化日志 + 一键快照
// 日志文件：<state dir>/diag.log
// 触发快照：在 state dir 放一个空文件 diag.req，下一次检查就会写快照并删除该文件
void SLDiag(NSString *cat, NSString *fmt, ...);
void SLDiagCheckRequest(void);
NSString *SLDiagSnapshot(NSString *why);

#ifdef __cplusplus
}
#endif
