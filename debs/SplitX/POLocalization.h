//
//  POLocalization.h
//  SplitX
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

NSBundle *POLocalizationBundle(void);

NSString *POLocalizedString(NSString *key, NSString *table);

NS_ASSUME_NONNULL_END
