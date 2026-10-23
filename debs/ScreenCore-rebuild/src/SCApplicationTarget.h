// SCApplicationTarget.h - 逆向重建自 ScreenCore 2.0.4
#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, SCTargetType) {
    SCTargetTypeNormal = 0,
    SCTargetTypeCrane = 1  // Crane 分身
};

@interface SCApplicationTarget : NSObject <NSCopying, NSCoding>

// === 标识 ===
@property (nonatomic, copy) NSString *bundleIdentifier;
@property (nonatomic, copy) NSString *containerIdentifier;  // nil = 默认容器
@property (nonatomic, assign) SCTargetType targetType;
@property (nonatomic, assign) BOOL craneTarget;

// === 显示 ===
@property (nonatomic, copy) NSString *displayName;
@property (nonatomic, copy) NSString *shortDisplayName;  // 分身简称
@property (nonatomic, strong) UIImage *iconImage;

// === 工厂方法 ===
+ (instancetype)sc_targetWithBundleIdentifier:(NSString *)bundleID;
+ (instancetype)sc_targetWithBundleIdentifier:(NSString *)bundleID 
                           containerIdentifier:(NSString *)containerID;

// === Crane 判定 ===
- (BOOL)sc_isCraneTarget;
- (NSString *)sc_fullIdentifier;  // "bundle#container"

// === 编解码 ===
- (NSDictionary *)sc_dictionaryRepresentation;
+ (instancetype)sc_targetFromDictionary:(NSDictionary *)dict;

@end
