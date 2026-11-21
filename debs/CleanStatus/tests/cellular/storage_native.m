#import <Foundation/Foundation.h>
#import "LCSCellularSettings.h"
#include <unistd.h>
#include <stdlib.h>
#include <sys/stat.h>
static unsigned checks;
#define REQUIRE(x) do { if(!(x)){fprintf(stderr,"storage check failed at line %d\n",__LINE__);return 1;}checks++; } while(0)
int main(void) {
    @autoreleasepool {
        NSFileManager *fm=NSFileManager.defaultManager;
        NSString *base=[NSTemporaryDirectory() stringByAppendingPathComponent:[NSUUID.UUID UUIDString]];
        NSString *root=[base stringByAppendingPathComponent:@".jbroot-CURRENT"];
        NSString *program=[base stringByAppendingPathComponent:@"program"];
        [fm createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:NULL];
        NSString *marker=[program stringByAppendingPathComponent:@"Library/MobileSubstrate/DynamicLibraries/LocalCleanStatusAnimations.dylib"];
        [fm createDirectoryAtPath:marker.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:NULL];
        REQUIRE([[@"fixture only" dataUsingEncoding:NSUTF8StringEncoding] writeToFile:marker atomically:YES]);
        REQUIRE([fm createSymbolicLinkAtPath:[root stringByAppendingPathComponent:@".jbroot"] withDestinationPath:program error:NULL]);
        setenv("LCS_CELLULAR_FIXTURE_GROUP",base.fileSystemRepresentation,1);
        setenv("LCS_CELLULAR_FIXTURE_ROOTLESS",[base stringByAppendingPathComponent:@"unused-rootless"].fileSystemRepresentation,1);
        REQUIRE([LCSCellularRoot() isEqualToString:root]);
        REQUIRE(![fm fileExistsAtPath:[root stringByAppendingPathComponent:@"Library/MobileSubstrate"]]);
        REQUIRE(![LCSCellularReadPreferences()[@"simManager"] boolValue]);
        REQUIRE(![LCSCellularReadPreferences()[@"dataSwitch"] boolValue]);
        REQUIRE([LCSCellularReadPreferences()[@"diagnostics"] boolValue]);
        NSError *error=nil;
        NSMutableArray *legacy=[NSMutableArray new];
        for(NSString *name in @[@"legacy/one",@"legacy/two"]) {
            NSString *file=[[base stringByAppendingPathComponent:name] stringByAppendingPathComponent:@"var/mobile/Library/Preferences/com.local.cleanstatus.cellular.plist"];
            [fm createDirectoryAtPath:file.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:NULL];
            NSDictionary *v=@{@"schema":@1,@"simManager":@YES,@"dataSwitch":@([name hasSuffix:@"two"]),@"diagnostics":@YES};
            NSData *data=[NSPropertyListSerialization dataWithPropertyList:v format:NSPropertyListBinaryFormat_v1_0 options:0 error:NULL];
            REQUIRE([data writeToFile:file atomically:YES]);
            REQUIRE([fm setAttributes:@{NSFileModificationDate:[NSDate dateWithTimeIntervalSince1970:[name hasSuffix:@"two"]?200:100]} ofItemAtPath:file error:NULL]);
            [legacy addObject:file];
        }
        REQUIRE(LCSCellularMigratePreferences(&error));
        REQUIRE([LCSCellularReadPreferences()[@"simManager"] boolValue]&&[LCSCellularReadPreferences()[@"dataSwitch"] boolValue]);
        for(NSString *file in legacy)REQUIRE(![fm fileExistsAtPath:file]);
        REQUIRE(LCSCellularSaveSetting(@"simManager",YES,&error));
        REQUIRE([LCSCellularReadPreferences()[@"simManager"] boolValue]);
        REQUIRE(LCSCellularSaveSetting(@"dataSwitch",YES,&error));
        REQUIRE([LCSCellularReadPreferences()[@"simManager"] boolValue]&&[LCSCellularReadPreferences()[@"dataSwitch"] boolValue]);
        REQUIRE(LCSCellularSaveSetting(@"diagnostics",NO,&error));
        REQUIRE(![LCSCellularReadPreferences()[@"diagnostics"] boolValue]);
        REQUIRE(!LCSCellularSaveSetting(@"unrecognized",YES,&error));
        NSString *path=LCSCellularPreferencesPath();
        REQUIRE([path hasPrefix:[root stringByAppendingString:@"/"]]);
        struct stat s;REQUIRE(lstat(path.fileSystemRepresentation,&s)==0&&S_ISREG(s.st_mode)&&s.st_nlink==1);
        NSData *stored=[NSData dataWithContentsOfFile:path];
        REQUIRE([NSPropertyListSerialization propertyListWithData:stored options:0 format:NULL error:NULL]!=nil);
        int lock=LCSCellularAcquireOperationLock(&error);REQUIRE(lock>=0);
        int second=LCSCellularAcquireOperationLock(&error);REQUIRE(second<0);LCSCellularReleaseOperationLock(lock);
        int third=LCSCellularAcquireOperationLock(&error);REQUIRE(third>=0);LCSCellularReleaseOperationLock(third);
        [@"damaged-plist" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        REQUIRE(![LCSCellularReadPreferences()[@"simManager"] boolValue]);
        REQUIRE(LCSCellularSaveSetting(@"dataSwitch",YES,&error));
        REQUIRE([LCSCellularReadPreferences()[@"dataSwitch"] boolValue]);
        NSString *outside=[base stringByAppendingPathComponent:@"outside"];
        NSData *sentinel=[@"do-not-change" dataUsingEncoding:NSUTF8StringEncoding];[sentinel writeToFile:outside atomically:YES];
        [fm removeItemAtPath:path error:NULL];[fm createSymbolicLinkAtPath:path withDestinationPath:outside error:NULL];
        REQUIRE(!LCSCellularSaveSetting(@"simManager",YES,&error));
        REQUIRE([[NSData dataWithContentsOfFile:outside] isEqualToData:sentinel]);
        [fm removeItemAtPath:path error:NULL];REQUIRE(link(outside.fileSystemRepresentation,path.fileSystemRepresentation)==0);
        REQUIRE(!LCSCellularSaveSetting(@"simManager",YES,&error));
        REQUIRE([[NSData dataWithContentsOfFile:outside] isEqualToData:sentinel]);
        [fm removeItemAtPath:path error:NULL];
        NSString *parent=path.stringByDeletingLastPathComponent,*moved=[parent stringByAppendingString:@"-old"];
        NSString *external=[base stringByAppendingPathComponent:@"external"];
        [fm createDirectoryAtPath:external withIntermediateDirectories:YES attributes:nil error:NULL];
        REQUIRE([fm moveItemAtPath:parent toPath:moved error:NULL]);
        REQUIRE([fm createSymbolicLinkAtPath:parent withDestinationPath:external error:NULL]);
        REQUIRE(!LCSCellularSaveSetting(@"simManager",YES,&error));
        REQUIRE(![fm fileExistsAtPath:[external stringByAppendingPathComponent:path.lastPathComponent]]);
        [fm removeItemAtPath:parent error:NULL];[fm moveItemAtPath:moved toPath:parent error:NULL];
        NSString *different=[base stringByAppendingPathComponent:@"new-root"];
        [fm createDirectoryAtPath:different withIntermediateDirectories:YES attributes:nil error:NULL];
        setenv("LCS_CELLULAR_FIXTURE_GROUP",different.fileSystemRepresentation,1);
        REQUIRE([LCSCellularRoot() isEqualToString:root]); // Cached once, not reranked on every write.
        [fm removeItemAtPath:root error:NULL];REQUIRE(!LCSCellularSaveSetting(@"simManager",YES,&error));
        [fm removeItemAtPath:base error:NULL];
        printf("PASS Apple Foundation cellular storage: %u real-filesystem checks; fixture-only, no device or radio operations.\n",checks);
    }
    return 0;
}
