// TWSpecifiers.h — Twin 设置面板共用的 specifier 构造 + 偏好胶水。
//
// 只服务 Prefs/（PreferenceBundle），不参与 SpringBoard dylib。
// 目标：所有分节/行的构造方式统一，detail / twController / bundle / isController
// 一次设全，杜绝"面板空白 / 点子页没反应"。
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <Preferences/PSSpecifier.h>
#import <Preferences/PSListController.h>
#import "TWPath.h"
#import "TWPrefs.h"

// ---------------------------------------------------------------- 键名兜底
// 新键由主线写在 Twin/TWPath.h。这里只在"主线还没写"时补上同名字符串，
// 已经在 TWPath.h 里定义过的绝不覆盖（TWPath.h 一律优先）。
#ifndef TWKeyWakeMode
#define TWKeyWakeMode        @"TWWakeMode"        // 0=Arc 角落唤醒(默认) 1=ParallelX 边缘手柄
#endif
#ifndef TWKeyArcCorners
#define TWKeyArcCorners      @"TWArcCorners"      // 位掩码 1=右下 2=左下 4=左上 8=右上（默认 3）
#endif
#ifndef TWKeyArcCornerSize
#define TWKeyArcCornerSize   @"TWArcCornerSize"   // 触发区边长(pt) 默认 64
#endif
#ifndef TWKeyArcOpenMode
#define TWKeyArcOpenMode     @"TWArcOpenMode"     // 0=分屏启动(默认) 1=全屏启动
#endif
#ifndef TWKeySideOpenMode
#define TWKeySideOpenMode    @"TWSideOpenMode"    // 同上（侧边/手柄路径）
#endif
#ifndef TWKeyCraneAppList
#define TWKeyCraneAppList    @"TWCraneAppList"    // NSArray<NSString*> 有序 bundleID
#endif
#ifndef TWKeyCraneContainers
#define TWKeyCraneContainers @"TWCraneContainers" // NSArray<NSDictionary*> {bundleID,containerID,name,badge,enabled}
#endif
#ifndef TWKeyRememberStates
#define TWKeyRememberStates  @"TWRememberStates"  // { "bundleID|containerID" : @{p,l,docked,side,updated} }
#endif
// 旧键（TWPath.h 已定义 TWKeyArcSound，新名字是同一个字符串）
#ifndef TWKeyArcSoundEnabled
#ifdef TWKeyArcSound
#define TWKeyArcSoundEnabled TWKeyArcSound
#else
#define TWKeyArcSoundEnabled @"TWArcSoundEnabled"
#endif
#endif

// 与 Layout/Library/PreferenceLoader/Preferences/com.niubiprass.twin.plist 的
// entry.bundle 完全一致：libprefs 用它把 detail 里的类归到本 bundle。
extern NSString *_Nonnull const TWPrefsBundleName;   // @"TwinPrefs"

// PSListController 的 detail 分发是私有方法（SDK 头文件里没有声明）。直接写
// [super controllerForSpecifier:] 编不过，写死调用又可能 doesNotRecognizeSelector，
// 所以这里做"确实实现了才转发"的守卫。
id _Nullable TWSuperControllerForSpecifier(id _Nonnull host, id _Nonnull specifier);

NS_ASSUME_NONNULL_BEGIN

#pragma mark - specifier 构造

// 分组头（footer 可为 nil）。
PSSpecifier *TWGroupSpecifier(NSString * _Nullable name, NSString * _Nullable footer);

// 通用行：title/key/default/cellClass/symbol/extras。
//   controllerClass 非空 → detail + bundle + isController 同时设好（link 行）。
PSSpecifier *TWRowSpecifier(id _Nullable target,
                            NSString *title,
                            NSString * _Nullable key,
                            id _Nullable defaultValue,
                            NSString * _Nullable cellName,
                            PSCellType cellType,
                            NSString * _Nullable symbol,
                            NSString * _Nullable controllerClass,
                            NSDictionary * _Nullable extras);

// 子页入口行（TWActionCell + disclosure）。
PSSpecifier *TWLinkRowSpecifier(id _Nullable target,
                                NSString *title,
                                NSString * _Nullable symbol,
                                NSString *controllerClass,
                                NSString * _Nullable detailText,
                                NSDictionary * _Nullable extras);

// 按钮行（TWActionCell，destructive 时红色、无箭头）。
PSSpecifier *TWButtonRowSpecifier(id _Nullable target,
                                  NSString *title,
                                  NSString *action,
                                  NSString * _Nullable symbol,
                                  BOOL destructive,
                                  NSDictionary * _Nullable extras);

// 子页控制器：优先 twController，其次 detail，都没有再交回 stock。
id _Nullable TWControllerForSpecifier(PSListController *host, PSSpecifier *specifier);

#pragma mark - 记忆（形态快照）

// TWRememberAllStates() 可用就用它；不可用（Prefs 进程没链 TWRemember.m）时
// 直接读 TWKeyRememberStates 现场生成同样字段的数组，面板永不空转。
NSArray<NSDictionary *> *TWRememberSnapshot(void);
NSInteger TWRememberSnapshotCount(void);
BOOL TWRememberDeleteState(NSString *key);   // 单条删除
void TWRememberWipe(void);                   // 「重置记忆大小及位置」

#pragma mark - 分身（容器）与 Arc 顺序

NSArray<NSDictionary *> *TWCraneContainers(void);   // TWKeyCraneContainers 归一化
NSInteger TWCraneContainerCount(void);
NSArray<NSString *> *TWArcOrderList(void);          // TWKeyCraneAppList（空则用分身数据兜底）
void TWSetArcOrderList(NSArray<NSString *> *list);

// 本机应用显示名（取不到时原样返回 bundleID）。
NSString *TWPrefsAppName(NSString *bundleID);

#pragma mark - 诊断（0.4.3 观测版）

// 写应用沙盒 Documents/TwinPrefs-diagnose.log：异常原文 + 构建轨迹。
// 设备端取日志：find /var/mobile/Containers/Data/Application -name TwinPrefs-diagnose.log
extern NSString * _Nonnull const TWDiagLogPath;
NSString * _Nullable TWDiagLogPathResolve(void);
void TWDiagLog(NSString * _Nonnull fmt, ...) NS_FORMAT_FUNCTION(1, 2);
void TWDiagDumpException(NSException * _Nonnull e, NSString * _Nullable context);

NS_ASSUME_NONNULL_END