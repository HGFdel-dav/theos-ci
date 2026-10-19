// TWPXPrefs.h — 接收器：读写 ParallelX（com.moxuan.parallelx）的真实偏好。
//
// ParallelX 运行时读取它自己的 plist（com.moxuan.parallelx.plist）来决定
// 窗口/键盘/外部打开/系统 各开关与滑杆。Twin 的「窗口与交互」「外部打开与
// 系统」子页直接操作同一份文件，做到"改一处、两边都生效"。
//
// 位置：ParallelX 与 Twin 同属 RootHide/越狱 AppGroup，plist 落在某个
// .jbroot-* 的 var/mobile/Library/Preferences/com.moxuan.parallelx.plist。
// 这里用 TWPath 的 TWSweepParallelXPrefsPath() 动态扫描全部 .jbroot-* 找它；
// 找不到（用户还没打开过一次 ParallelX 面板 / 尚未生成）返回 NO。
//
// 写完总开关/滑杆后必须发 PostNotification：
//     com.moxuan.parallelx.capture-updated
// 让 ParallelX 运行时实例热刷新（CFNotificationCenter Darwin 通知）。
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>  // CGFloat

NS_ASSUME_NONNULL_BEGIN

@class NSNumber;

@interface TWPXPrefs : NSObject

// 定位 com.moxuan.parallelx.plist 真实路径（多个 .jbroot-* 时取最活跃的那个）。
// 找不到返回空串。
- (NSString *)parallelXFilePath;
// 是否定位到了 ParallelX 偏好文件（决定子页给"可编辑"还是"需先打开面板"提示）。
- (BOOL)available;

- (id _Nullable)objectForKey:(NSString *)key defaultValue:(id _Nullable)fallback;
- (BOOL)boolForKey:(NSString *)key defaultValue:(BOOL)def;
- (NSInteger)integerForKey:(NSString *)key defaultValue:(NSInteger)def;
- (CGFloat)floatForKey:(NSString *)key defaultValue:(CGFloat)def;

// 写值 + 立即落盘 + 发 Darwin 通知通知 ParallelX 刷新。返回写入是否成功。
- (BOOL)setObject:(id _Nullable)value forKey:(NSString *)key;

// 显式触发 ParallelX 刷新（一般不直接调；setObject: 内部已做）。
- (void)postRefresh;

// 备份与恢复用：整份 plist 的读写。
- (NSDictionary *)allValues;
- (void)removeAll;
- (void)synchronize;

@end

NS_ASSUME_NONNULL_END