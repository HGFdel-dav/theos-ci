#import <Foundation/Foundation.h>

#define SL_BUNDLE_ID   @"com.minis.shanlianrenew"
#define SL_APP_ID      @"com.shanlian.pro"
#define SL_SB_ID       @"com.apple.springboard"
#define SL_APP_GROUP   @"SZY6Z8FST5.com.lightningxvpn.shared"
#define SL_DEVICE_KEY  @"kShanLianDeviceIdKey"
#define SL_PROBE_TOKEN @"__sl_probe_token"
#define SL_STATE_NAME  @"com.minis.shanlianrenew.plist"

#define SL_NOTIFY_FIRE @"com.minis.shanlianrenew.fire"
#define SL_VER @"1.0.0"

#ifdef __cplusplus
extern "C" {
#endif

NSString *SLJbRoot(void);
NSString *SLStatePath(void);
NSString *SLStateDir(void);
NSString *SLAppGroupPrefsPath(void);
void SLLog(NSString *fmt, ...);

#ifdef __cplusplus
}
#endif
