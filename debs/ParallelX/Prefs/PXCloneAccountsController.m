#import "PXCloneAccountsController.h"
#import "../Common/PXCloneCrane.h"
#import "../Common/PXClonePrefs.h"
#import <Preferences/PSSpecifier.h>



@interface PXCloneAccountsController () {
    NSUInteger _generation;
    BOOL _visible;
    NSString *_storageErrorText;
    PSSpecifier *_errorSpecifier;
}
@end

@implementation PXCloneAccountsController

- (instancetype)init {
    self = [super init];
    if (self) {
        _generation = 0;
        _visible = NO;
    }
    return self;
}

#pragma mark - Specifiers (main thread, memory only)

- (PSSpecifier *)groupNamed:(NSString *)name footer:(NSString *)footer {
    PSSpecifier *group = [PSSpecifier groupSpecifierWithName:name];
    if (footer.length) [group setProperty:footer forKey:@"footerText"];
    return group;
}

- (PSSpecifier *)switchForBundle:(NSString *)bundle
                       container:(NSString *)container
                            name:(NSString *)name {
    // The getter/setter selectors must match the implementations below
    // (readShown: / writeShown:specifier:). Pointing them at names that do not
    // exist leaves the cell with no getter at all - the switch then renders
    // "off" and never stores anything, which is exactly the dead-toggle
    // symptom this build had.
    PSSpecifier *specifier = [PSSpecifier preferenceSpecifierNamed:name
                                                            target:self
                                                               set:@selector(writeShown:specifier:)
                                                               get:@selector(readShown:)
                                                            detail:nil
                                                              cell:PSSwitchCell
                                                              edit:nil];
    [specifier setProperty:bundle forKey:@"cxBundleID"];
    [specifier setProperty:container forKey:@"cxContainerID"];
    [specifier setProperty:@(PXClonePrefs.shared != nil &&
                             [PXClonePrefs.shared isVisibleBundle:bundle container:container])
                    forKey:@"default"];
    return specifier;
}

- (NSMutableArray<PSSpecifier *> *)buildSpecifiers {
    NSMutableArray<PSSpecifier *> *specifiers = [NSMutableArray array];
    _errorSpecifier = nil;

    NSError *storageError = PXClonePrefs.shared.storageError;
    if (storageError) {
        _storageErrorText = storageError.localizedDescription;
        _errorSpecifier = [self groupNamed:@"存储状态" footer:_storageErrorText];
        [specifiers addObject:_errorSpecifier];
    }

    if (![PXCloneCrane prepareManager]) {
        [specifiers addObject:[self groupNamed:@"分身账号"
                                        footer:@"未检测到 Crane。显示开关仍会保存，安装 Crane 后生效。"]];
        return specifiers;
    }

    NSArray<NSDictionary *> *catalog = [PXCloneCrane cachedCatalog];
    if (!catalog.count) {
        [specifiers addObject:[self groupNamed:@"分身账号"
                                        footer:@"暂未发现带分身的应用，下拉刷新或稍后重试。"]];
        return specifiers;
    }

    for (NSDictionary *app in catalog) {
        NSString *bundle = app[@"bundle"];
        NSArray<NSDictionary *> *containers = app[@"containers"];
        if (![bundle isKindOfClass:NSString.class] || !bundle.length) continue;
        if (![containers isKindOfClass:NSArray.class] || containers.count < 2) continue;

        NSString *appName = app[@"name"];
        [specifiers addObject:[self groupNamed:appName footer:nil]];
        for (NSDictionary *container in containers) {
            NSString *identifier = container[@"container"];
            if (![identifier isKindOfClass:NSString.class] || !identifier.length) continue;
            BOOL isDefault = [container[@"isDefault"] boolValue];
            NSString *title = isDefault ? @"默认账号"
                                        : (container[@"name"] ?: identifier);
            if (isDefault) title = @"默认账号";
            [specifiers addObject:[self switchForBundle:bundle container:identifier name:title]];
        }
    }
    return specifiers;
}

- (NSArray *)specifiers {
    if (!_specifiers) {
        _specifiers = [self buildSpecifiers];
        [self refreshCatalog];
    }
    return _specifiers;
}

- (void)refreshCatalog {
    NSUInteger generation = ++_generation;
    __weak typeof(self) weakSelf = self;
    [PXCloneCrane refreshCatalogWithCompletion:^(NSArray<NSDictionary *> *catalog, NSError *error) {
        PXCloneAccountsController *strongSelf = weakSelf;
        if (!strongSelf || generation != strongSelf->_generation) return;
        if (error) strongSelf->_storageErrorText = error.localizedDescription;
        if (!strongSelf.isViewLoaded || !strongSelf.view.window) return;
        [strongSelf rebuildAndReload];
    }];
}

- (void)rebuildAndReload {
    // Rebuild into a temp array first so a partial failure never leaves a
    // half-constructed _specifiers cache.
    NSMutableArray *fresh = [self buildSpecifiers];
    _specifiers = fresh;
    [self reloadSpecifiers];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    _visible = YES;
    NSUInteger generation = ++_generation;
    __weak typeof(self) weakSelf = self;
    // Load the store before the catalog: until the store is loaded every switch
    // reads fail-closed ("off"), so a page built first would show every account
    // as hidden no matter what is actually stored.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *storeError = nil;
        BOOL loaded = [PXClonePrefs.shared reloadSnapshot:&storeError];
        dispatch_async(dispatch_get_main_queue(), ^{
            PXCloneAccountsController *strongSelf = weakSelf;
            if (!strongSelf || !strongSelf->_visible || generation != strongSelf->_generation) return;
            if (!loaded) strongSelf->_storageErrorText = storeError.localizedDescription ?: @"存储无法读取";
            // A cached catalog is shown immediately; refresh completes off-main.
            [PXCloneCrane refreshCatalogWithCompletion:^(NSArray<NSDictionary *> *catalog, NSError *error) {
                PXCloneAccountsController *self2 = weakSelf;
                if (!self2 || !self2->_visible || generation != self2->_generation) return;
                if (error) self2->_storageErrorText = error.localizedDescription;
                [self2 rebuildAndReload];
            }];
        });
    });
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    _visible = NO;
    _generation++;
}

#pragma mark - Switch accessors

- (id)readShown:(PSSpecifier *)specifier {
    NSString *bundle = [specifier propertyForKey:@"cxBundleID"];
    NSString *container = [specifier propertyForKey:@"cxContainerID"];
    if (!bundle.length || !container.length) return @NO;
    return @([PXClonePrefs.shared isVisibleBundle:bundle container:container]);
}

- (void)writeShown:(id)value specifier:(PSSpecifier *)specifier {
    NSString *bundle = [specifier propertyForKey:@"cxBundleID"];
    NSString *container = [specifier propertyForKey:@"cxContainerID"];
    if (!bundle.length || !container.length) return;

    BOOL visible = [value boolValue];
    NSUInteger generation = _generation;
    __weak typeof(self) weakSelf = self;
    __weak PSSpecifier *weakSpecifier = specifier;
    [PXClonePrefs.shared setVisible:visible bundle:bundle container:container
                         completion:^(BOOL ok, NSError *error) {
        PXCloneAccountsController *strongSelf = weakSelf;
        PSSpecifier *strongSpecifier = weakSpecifier;
        if (!strongSelf || !strongSpecifier) return;
        if (generation != strongSelf->_generation) return;

        if (ok) {
            if (strongSelf->_errorSpecifier) {
                [strongSelf removeSpecifier:strongSelf->_errorSpecifier animated:YES];
                strongSelf->_errorSpecifier = nil;
                strongSelf->_storageErrorText = nil;
            }
            return;
        }
        strongSelf->_storageErrorText = error.localizedDescription ?: @"写入失败";
        if (!strongSelf->_errorSpecifier) {
            PSSpecifier *group = [strongSelf groupNamed:@"存储状态" footer:strongSelf->_storageErrorText];
            strongSelf->_errorSpecifier = group;
            [strongSelf insertSpecifier:group atIndex:0 animated:YES];
        }
        [strongSelf reloadSpecifier:strongSpecifier animated:YES];
    }];
}

@end
