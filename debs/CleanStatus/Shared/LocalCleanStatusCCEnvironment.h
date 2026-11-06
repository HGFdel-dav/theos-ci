#pragma once
#import <Foundation/Foundation.h>
#ifdef __cplusplus
extern "C" {
#endif
BOOL local_cleanstatus_ccIsSpringBoard(void);
BOOL local_cleanstatus_ccUnlocked(void);
NSString *local_cleanstatus_ccRoot(void);
NSString *local_cleanstatus_ccResourcePath(NSString *logicalPath);
NSString *local_cleanstatus_ccModulePath(void);
NSString *local_cleanstatus_ccToolPath(NSString *name);
// Crashing SpringBoard twice across two boots is the only supported way for a
// tweak to request Dopamine/RootHide safe mode. The flag carries a timestamp so
// it self-expires instead of looping forever.
void local_cleanstatus_ccConsumeSafeModeFlag(void);
#ifdef __cplusplus
}
#endif
