// TWPXSubpageController.h — ParallelX 透传子页（Window / Keyboard / External /
// System 四个页面共用）。
//
// 这些开关/滑杆的真实属主是 ParallelX（com.moxuan.parallelx），Twin 不做任何
// 拷贝，直接读写同一份 jbroot plist 并 postRefresh 让 ParallelX 热刷新。因此
// 「在这改 → ParallelX 立即生效」，也「ParallelX 面板改 → 这里读到的就是新的」。
//
// pageType 取值：
//   TWPXPageWindow / TWPXPageKeyboard / TWPXPageExternal / TWPXPageSystem
#import <Preferences/PSListController.h>

typedef NS_ENUM(NSInteger, TWPXPageType) {
    TWPXPageWindow   = 0,
    TWPXPageKeyboard = 1,
    TWPXPageExternal = 2,
    TWPXPageSystem   = 3,
};

@interface TWPXSubpageController : PSListController
@property (nonatomic, assign) TWPXPageType pageType;
@end