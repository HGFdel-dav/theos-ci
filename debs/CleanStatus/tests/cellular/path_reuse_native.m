// Test-only filesystem fixtures: never link CoreTelephony or execute a helper.
#import <Foundation/Foundation.h>
#import "LCSCellularSettings.h"
#import "LocalCleanStatusAnimationPreferences.h"
#include <sys/stat.h>
#include <unistd.h>
#include <stdlib.h>
static unsigned checks;
#define REQUIRE(x) do{if(!(x)){fprintf(stderr,"path-reuse assertion failed at %d\n",__LINE__);return 1;}checks++;}while(0)
static NSFileManager *fm;
static BOOL Directory(NSString *p){return [fm createDirectoryAtPath:p withIntermediateDirectories:YES attributes:nil error:NULL];}
static BOOL File(NSString *p){return Directory(p.stringByDeletingLastPathComponent)&&[[@"fixture only: not code" dataUsingEncoding:NSUTF8StringEncoding] writeToFile:p atomically:YES];}
static NSString *LCSFixtureAnimationMarker(NSString *p){return [p stringByAppendingPathComponent:@"Library/MobileSubstrate/DynamicLibraries/LocalCleanStatusAnimations.dylib"];}
static NSString *Tool(NSString *p){return [p stringByAppendingPathComponent:@"usr/libexec/LocalCleanStatus/LocalCleanStatusSIMTool"];}
int main(int argc,char **argv){@autoreleasepool {
    if(argc!=3)return 64;
    fm=NSFileManager.defaultManager;NSString *mode=[NSString stringWithUTF8String:argv[1]],*base=[NSString stringWithUTF8String:argv[2]];
    NSString *group=[base stringByAppendingPathComponent:@"AppGroup"],*root=[group stringByAppendingPathComponent:@".jbroot-CURRENT"],*program=[base stringByAppendingPathComponent:@"Bundle/Application/.jbroot-CURRENT"],*fallback=[base stringByAppendingPathComponent:@"rootless"];
    REQUIRE(Directory(group));
    setenv("LCS_CELLULAR_FIXTURE_GROUP",group.fileSystemRepresentation,1);setenv("LCS_CELLULAR_FIXTURE_ROOTLESS",fallback.fileSystemRepresentation,1);
    BOOL readOnly=[mode isEqualToString:@"share-read"];
    BOOL flat=[mode isEqualToString:@"flat"];
    BOOL none=[mode isEqualToString:@"missing"]||[mode isEqualToString:@"rootless"];
    BOOL unranked=[mode isEqualToString:@"unranked"];
    BOOL symlinkRoot=[mode isEqualToString:@"symlink-root"];
    if(!readOnly) {
        if(!none) {
            if(symlinkRoot){REQUIRE(Directory(program));REQUIRE([fm createSymbolicLinkAtPath:root withDestinationPath:program error:NULL]);}
            else REQUIRE(Directory(root));
            if(!unranked) {
                REQUIRE(File(LCSFixtureAnimationMarker(flat?root:program)));
                if(!flat&&!symlinkRoot)REQUIRE([fm createSymbolicLinkAtPath:[root stringByAppendingPathComponent:@".jbroot"] withDestinationPath:program error:NULL]);
            }
        }
        if([mode isEqualToString:@"rootless"]||unranked)REQUIRE(Directory([fallback stringByAppendingPathComponent:@"usr/lib"]));
    }
    BOOL refuse=[mode isEqualToString:@"missing"]||unranked||symlinkRoot;
    if(refuse) {
        REQUIRE(!LCSCellularRoot());REQUIRE(!LCSCellularPreferencesPath());NSError *error=nil;
        REQUIRE(!LCSCellularSaveSetting(@"simManager",YES,&error));REQUIRE(error!=nil);REQUIRE(!LCSCellularSIMToolPath());
        printf("PASS native path-reuse %s: %u assertions; original resolver rejects unavailable/unranked roots.\n",argv[1],checks);return 0;
    }
    if([mode isEqualToString:@"rootless"])root=fallback;
    REQUIRE([LCSCellularRoot() isEqualToString:root]);
    NSString *animation=local_cleanstatus_animationPreferencesPath(),*path=LCSCellularPreferencesPath();
    REQUIRE([path.stringByDeletingLastPathComponent isEqualToString:animation.stringByDeletingLastPathComponent]);
    REQUIRE([path.lastPathComponent isEqualToString:@"com.local.cleanstatus.cellular.plist"]);
    REQUIRE(![path isEqualToString:animation]);
    if(readOnly){REQUIRE([LCSCellularReadPreferences()[@"simManager"] boolValue]);REQUIRE([LCSCellularReadPreferences()[@"dataSwitch"] boolValue]);printf("PASS native path-reuse share-read: %u assertions; separate process, fixture only.\n",checks);return 0;}
    NSData *sentinel=[@"original animation stays untouched" dataUsingEncoding:NSUTF8StringEncoding];REQUIRE(Directory(animation.stringByDeletingLastPathComponent));REQUIRE([sentinel writeToFile:animation atomically:YES]);
    NSString *main=[animation.stringByDeletingLastPathComponent stringByAppendingPathComponent:@"com.local.cleanstatus.plist"];REQUIRE([sentinel writeToFile:main atomically:YES]);
    if([mode isEqualToString:@"escape"]) {
        NSString *parent=path.stringByDeletingLastPathComponent,*outside=[base stringByAppendingPathComponent:@"outside"];
        REQUIRE([fm moveItemAtPath:parent toPath:[parent stringByAppendingString:@"-backup"] error:NULL]);REQUIRE(Directory(outside));
        REQUIRE([fm createSymbolicLinkAtPath:parent withDestinationPath:outside error:NULL]);NSError *error=nil;
        REQUIRE(!LCSCellularSaveSetting(@"simManager",YES,&error));REQUIRE(![fm fileExistsAtPath:[outside stringByAppendingPathComponent:path.lastPathComponent]]);
    } else {
        NSError *error=nil;REQUIRE(LCSCellularSaveSetting(@"simManager",YES,&error));REQUIRE(LCSCellularSaveSetting(@"dataSwitch",YES,&error));
        REQUIRE([LCSCellularReadPreferences()[@"simManager"] boolValue]);REQUIRE([LCSCellularReadPreferences()[@"dataSwitch"] boolValue]);
        REQUIRE([[NSData dataWithContentsOfFile:animation] isEqualToData:sentinel]);REQUIRE([[NSData dataWithContentsOfFile:main] isEqualToData:sentinel]);
        REQUIRE(!LCSCellularSIMToolPath());
        if(![mode isEqualToString:@"rootless"]) {
            NSString *tool=Tool(flat?root:program);REQUIRE(File(tool));REQUIRE(chmod(tool.fileSystemRepresentation,0755)==0);
            NSString *resolved=LCSCellularSIMToolPath();REQUIRE(resolved.length>0);
            REQUIRE([resolved.stringByResolvingSymlinksInPath isEqualToString:tool.stringByResolvingSymlinksInPath]);
            REQUIRE([fm removeItemAtPath:tool error:NULL]);
            REQUIRE([fm createSymbolicLinkAtPath:tool withDestinationPath:animation error:NULL]);REQUIRE(!LCSCellularSIMToolPath());
        }
        if([mode isEqualToString:@"stale"]) {
            REQUIRE([fm removeItemAtPath:root error:NULL]);REQUIRE(!LCSCellularSaveSetting(@"simManager",NO,&error));
        }
    }
    printf("PASS native path-reuse %s: %u assertions; no device, radio or executable helper invoked.\n",argv[1],checks);
}return 0;}
