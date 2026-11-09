#pragma once
#import "LCSATypeEncoding.h"
#include <atomic>
#include <initializer_list>

static BOOL LCSAMethod(Class cls, SEL sel, const char *result, std::initializer_list<const char *> args = {}, BOOL classMethod = NO) {
    Method m = cls ? (classMethod ? class_getClassMethod(cls, sel) : class_getInstanceMethod(cls, sel)) : NULL;
    if (!m || method_getNumberOfArguments(m) != args.size() + 2) return NO;
    char *type = method_copyReturnType(m); BOOL ok = LCSAEncodingMatches(type, result); free(type);
    unsigned index = 2;
    for (const char *argument : args) {
        type = method_copyArgumentType(m, index++);
        ok = ok && LCSAEncodingMatches(type, argument); free(type);
    }
    return ok;
}
static BOOL LCSACall(id obj, SEL sel, const char *result, std::initializer_list<const char *> args = {}) {
    // object_getClass(Class) is the metaclass: the same check covers class receivers too.
    return obj && LCSAMethod(object_getClass(obj), sel, result, args);
}
static id LCSAObject(id obj, const char *name) {
    SEL sel = sel_registerName(name);
    return LCSACall(obj, sel, @encode(id)) ? ((id (*)(id, SEL))objc_msgSend)(obj, sel) : nil;
}
static BOOL LCSABool(id obj, const char *name, BOOL fallback = NO) {
    SEL sel = sel_registerName(name);
    return LCSACall(obj, sel, @encode(BOOL)) ? ((BOOL (*)(id, SEL))objc_msgSend)(obj, sel) : fallback;
}
static id LCSAObjectIvar(id obj, const char *name) {
    Ivar iv = obj ? class_getInstanceVariable(object_getClass(obj), name) : NULL;
    const char *type = iv ? ivar_getTypeEncoding(iv) : NULL;
    return type && LCSAEncodingMatches(type, @encode(id)) ? object_getIvar(obj, iv) : nil;
}
static SEL LCSASetter(NSString *key) {
    if (!key.length) return NULL;
    return NSSelectorFromString([NSString stringWithFormat:@"set%@%@:", [[key substringToIndex:1] uppercaseString], [key substringFromIndex:1]]);
}
static const char *LCSANumberType(id obj, NSString *key) {
    SEL get = NSSelectorFromString(key), set = LCSASetter(key);
    if (LCSACall(obj, get, @encode(double)) && LCSACall(obj, set, "v", {@encode(double)})) return @encode(double);
    if (LCSACall(obj, get, @encode(BOOL)) && LCSACall(obj, set, "v", {@encode(BOOL)})) return @encode(BOOL);
    return NULL;
}
static NSNumber *LCSAReadNumber(id obj, NSString *key) {
    const char *type = LCSANumberType(obj, key); if (!type) return nil;
    SEL get = NSSelectorFromString(key);
    return type[0] == 'd' ? @(((double (*)(id, SEL))objc_msgSend)(obj, get)) : @(((BOOL (*)(id, SEL))objc_msgSend)(obj, get));
}
static BOOL LCSAWriteNumber(id obj, NSString *key, NSNumber *value) {
    const char *type = LCSANumberType(obj, key); if (!type) return NO;
    if (type[0] == 'd') ((void (*)(id, SEL, double))objc_msgSend)(obj, LCSASetter(key), value.doubleValue);
    else ((void (*)(id, SEL, BOOL))objc_msgSend)(obj, LCSASetter(key), value.boolValue);
    return YES;
}

@interface LCSANumberState : NSObject
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *before, *written;
@property (nonatomic, copy) NSString *scope;
@property (nonatomic, strong) NSMutableSet<NSString *> *abandoned;
@end
@implementation LCSANumberState
@end
static const void *kLCSANumberStateKey = &kLCSANumberStateKey;
static NSHashTable<id> *gLCSANumberObjects;
static BOOL LCSASetSavedNumber(id obj, NSString *key, double value, NSString *scope) {
    NSNumber *before = LCSAReadNumber(obj, key); if (!before || !isfinite(value)) return NO;
    LCSANumberState *state = objc_getAssociatedObject(obj, kLCSANumberStateKey);
    if (!state) {
        state = [LCSANumberState new]; state.before = [NSMutableDictionary dictionary]; state.written = [NSMutableDictionary dictionary]; state.scope = scope; state.abandoned = [NSMutableSet set];
        objc_setAssociatedObject(obj, kLCSANumberStateKey, state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (!gLCSANumberObjects) gLCSANumberObjects = [NSHashTable weakObjectsHashTable];
        [gLCSANumberObjects addObject:obj];
    }
    if ([state.abandoned containsObject:key]) return NO;
    if (!state.before[key]) state.before[key] = before;
    else if (state.written[key] && ![before isEqualToNumber:state.written[key]]) {
        // Another writer took this property: leave it alone until the next ownership interval.
        [state.before removeObjectForKey:key]; [state.written removeObjectForKey:key]; [state.abandoned addObject:key]; return NO;
    }
    if (!LCSAWriteNumber(obj, key, @(value))) return NO;
    state.written[key] = LCSAReadNumber(obj, key); return YES;
}
static void LCSARestoreNumberObject(id obj, NSString *scope) {
    if (!obj) return;
    LCSANumberState *state = objc_getAssociatedObject(obj, kLCSANumberStateKey);
    if (!state || (scope && ![state.scope isEqualToString:scope])) return;
    for (NSString *key in state.before) {
        NSNumber *current = LCSAReadNumber(obj, key);
        if (current && [current isEqualToNumber:state.written[key]]) LCSAWriteNumber(obj, key, state.before[key]);
    }
    objc_setAssociatedObject(obj, kLCSANumberStateKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [gLCSANumberObjects removeObject:obj];
}
static void LCSARestoreNumbers(NSString *scope) {
    for (id obj in gLCSANumberObjects.allObjects) LCSARestoreNumberObject(obj, scope);
}

// Only model properties actually changed by the fly animation are tracked; foreign animation keys stay intact.
@interface LCSALayerState : NSObject
@property (nonatomic, weak) CALayer *layer;
@property (nonatomic, copy) NSArray *filters, *writtenFilters;
@property (nonatomic, strong) NSHashTable *ownedFilters;
@property (nonatomic) CATransform3D sublayer, writtenSublayer;
@property (nonatomic) float opacity, writtenOpacity;
@property (nonatomic) BOOL hasFilters, hasSublayer, hasOpacity;
@end
@implementation LCSALayerState
@end
static const void *kLCSALayerStateKey = &kLCSALayerStateKey;
static NSHashTable<CALayer *> *gLCSALayers;
static LCSALayerState *LCSATouchLayer(CALayer *layer) {
    if (!layer) return nil;
    LCSALayerState *state = objc_getAssociatedObject(layer, kLCSALayerStateKey);
    if (!state) {
        state = [LCSALayerState new]; state.layer = layer;
        objc_setAssociatedObject(layer, kLCSALayerStateKey, state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (!gLCSALayers) gLCSALayers = [NSHashTable weakObjectsHashTable]; [gLCSALayers addObject:layer];
    }
    return state;
}
static float LCSAOriginalOpacity(CALayer *layer) {
    LCSALayerState *s = objc_getAssociatedObject(layer, kLCSALayerStateKey);
    return s.hasOpacity ? s.opacity : layer.opacity;
}
static void LCSASetOpacity(CALayer *layer, float value) {
    LCSALayerState *s = LCSATouchLayer(layer); if (!s) return;
    if (!s.hasOpacity) { s.opacity = layer.opacity; s.hasOpacity = YES; }
    else if (layer.opacity != s.writtenOpacity) return;
    layer.opacity = s.writtenOpacity = value;
}
static void LCSASetSublayer(CALayer *layer, CATransform3D value) {
    LCSALayerState *s = LCSATouchLayer(layer); if (!s) return;
    if (!s.hasSublayer) { s.sublayer = layer.sublayerTransform; s.hasSublayer = YES; }
    else if (!CATransform3DEqualToTransform(layer.sublayerTransform, s.writtenSublayer)) return;
    layer.sublayerTransform = s.writtenSublayer = CATransform3DConcat(s.sublayer, value);
}
static void LCSASetFilters(CALayer *layer, NSArray *added) {
    LCSALayerState *s = LCSATouchLayer(layer); if (!s) return;
    if (!s.hasFilters) { s.filters = [layer.filters copy]; s.hasFilters = YES; }
    else if (layer.filters != s.writtenFilters && ![layer.filters isEqual:s.writtenFilters]) return;
    if (!s.ownedFilters) s.ownedFilters = [NSHashTable strongObjectsHashTable];
    for (id filter in added) [s.ownedFilters addObject:filter];
    NSArray *value = added.count ? [(s.filters ?: @[]) arrayByAddingObjectsFromArray:added] : s.filters;
    layer.filters = value; s.writtenFilters = [layer.filters copy];
}
static void LCSARestoreLayer(CALayer *layer, NSString *animationKey) {
    LCSALayerState *s = objc_getAssociatedObject(layer, kLCSALayerStateKey);
    [layer removeAnimationForKey:animationKey];
    if (s.hasOpacity && layer.opacity == s.writtenOpacity) layer.opacity = s.opacity;
    if (s.hasSublayer && CATransform3DEqualToTransform(layer.sublayerTransform, s.writtenSublayer)) layer.sublayerTransform = s.sublayer;
    if (s.hasFilters && (layer.filters == s.writtenFilters || [layer.filters isEqual:s.writtenFilters])) layer.filters = s.filters;
    else if (s.ownedFilters.count) {
        NSMutableArray *retained = [NSMutableArray array];
        for (id filter in layer.filters) if (![s.ownedFilters containsObject:filter]) [retained addObject:filter];
        layer.filters = [retained copy];
    }
    objc_setAssociatedObject(layer, kLCSALayerStateKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC); [gLCSALayers removeObject:layer];
}
static void LCSARestoreLayerTree(UIView *view, NSString *key) {
    if (!view) return;
    LCSARestoreLayer(view.layer, key);
    for (UIView *child in view.subviews) LCSARestoreLayerTree(child, key);
}
