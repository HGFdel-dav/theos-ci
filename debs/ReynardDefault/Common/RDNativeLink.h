#ifndef RD_NATIVE_LINK_H
#define RD_NATIVE_LINK_H
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <mach-o/dyld.h>
#import <substrate.h>
#import <string.h>
#import <atomic>
#import "Common/Common.h"
#import "RDLinkPolicy.h"

#define RD_NS_ERROR_ABORT ((int32_t)0x80004004)
#define RD_XUL_ON_LINK_CLICK 0x5d74298ULL
static NSString *const kRDReynardBundleID = @"com.minh-ton.Reynard";
static const uint8_t kRDExpectedXULUUID[16] = {0x4c,0x4c,0x44,0x3a,0x55,0x55,0x31,0x44,0xa1,0xf3,0x62,0x45,0x76,0x1c,0xfd,0xe8};
static const uint32_t kRDLinkPrologue[5] = {0xa9ba6ffc,0xa90167fa,0xa9025ff8,0xa90357f6,0xa9044ff4};

/* Firefox 159 nsTStringRepr / nsTAutoStringN<char,16384> ABI. */
struct RDGeckoCString { char *data; uint32_t length; uint16_t dataFlags; uint16_t classFlags; };
struct RDGeckoLengthStorage { uint32_t value; };
struct RDGeckoAutoCString { RDGeckoCString base; RDGeckoLengthStorage inlineCapacity; char storage[64]; };
struct RDGeckoU16String { char16_t *data; uint32_t length; uint16_t dataFlags; uint16_t classFlags; };
struct RDGeckoStringBufferHeader { std::atomic<uint32_t> refCount; uint32_t storageSize; };
typedef int32_t (*RDGeckoGetSpecFn)(void *, RDGeckoCString *);
// Never C++-cast an nsIURI interface to a hand-written vtable class: nsIURI
// derives from nsISupports2 and the inherited vtable order is version-sensitive.
// The exact nsIURI vtable was checked on the installed XUL; slot 3 is GetSpec.
static constexpr uint32_t kRDGetSpecVTableSlot = 3;
typedef int32_t (*RDOnLinkClickFn)(void *,void *,void *,const RDGeckoU16String *,const RDGeckoU16String *,void *,void *,bool,uint8_t,void *,void *);
static_assert(sizeof(RDGeckoCString)==16,"nsCString ABI mismatch");
static_assert(offsetof(RDGeckoAutoCString,inlineCapacity)==16,"nsTAutoString length offset mismatch");
static_assert(offsetof(RDGeckoAutoCString,storage)==20,"nsTAutoString storage offset mismatch");
static_assert(sizeof(RDGeckoAutoCString)==88,"nsTAutoStringN<char,64> ABI mismatch");
static_assert(sizeof(RDGeckoU16String)==16,"nsAString ABI mismatch");
static_assert(sizeof(RDGeckoStringBufferHeader)==8,"StringBuffer header ABI mismatch");
static RDOnLinkClickFn rdOriginalOnLinkClick = nullptr;

#ifdef REYNARD_STRIP_LOGS
#define RD_NATIVE_NSLOG(...) do {} while (0)
#else
#define RD_NATIVE_NSLOG(...) NSLog(__VA_ARGS__)
#endif
static void RDNativeLog(NSString *format, ...) {
    va_list args; va_start(args, format);
    NSString *line = [[NSString alloc] initWithFormat:format arguments:args]; va_end(args);
    RD_NATIVE_NSLOG(@"[ReynardDefault] %@", line);
    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"ReynardDefault.log"];
    NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:NULL];
    if (attrs && [[attrs objectForKey:NSFileSize] unsignedLongLongValue] > 256*1024) {
        [[NSFileManager defaultManager] removeItemAtPath:path error:NULL]; attrs = nil;
    }
    NSData *data = [[NSString stringWithFormat:@"%@ [ReynardDefault] %@\n", [NSDate date], line] dataUsingEncoding:NSUTF8StringEncoding];
    if (!attrs) { [data writeToFile:path atomically:YES]; return; }
    NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path]; if (!handle) return;
    @try { [handle seekToEndOfFile]; [handle writeData:data]; } @catch (NSException *e) { (void)e; }
    [handle closeFile];
}
static BOOL RDNativeEnabled(void) {
    return RDReadBoolPref(kEnabledKey, YES) && RDReadBoolPref(kHandoffKey, YES);
}
static BOOL RDNativeInternalScheme(NSString *scheme) {
    static NSSet *set; static dispatch_once_t once;
    dispatch_once(&once, ^{ set=[NSSet setWithArray:@[@"http",@"https",@"about",@"data",@"blob",@"javascript",@"moz-extension",@"jar",@"view-source",@"file",@"resource",@"wyciwyg",@"ws",@"wss",@"ftp",@"reynard",@"chrome",@"chrome-extension"]]; });
    return [set containsObject:scheme.lowercaseString];
}
static NSString *RDNativeURISpec(void *uri) {
    if (!uri) return nil;
    RDGeckoAutoCString out = {{NULL,0,0,0},{63},{0}};
    out.base.data=out.storage;
    out.base.dataFlags=0x11;
    out.base.classFlags=0x01;
    out.storage[0]=0;
    void **table=*reinterpret_cast<void ***>(uri);
    if(!table||!table[kRDGetSpecVTableSlot])return nil;
    RDGeckoGetSpecFn getSpec=reinterpret_cast<RDGeckoGetSpecFn>(table[kRDGetSpecVTableSlot]);
    int32_t result=getSpec(uri,&out.base);
    // Bound to the verified nsTAutoCString capacity; long URLs fall through to Gecko.
    if(result!=0||!out.base.data||out.base.length>=sizeof(out.storage)||
       out.base.data!=out.storage||!(out.base.dataFlags&0x10))return nil;
    return [[NSString alloc]initWithBytes:out.base.data length:out.base.length encoding:NSUTF8StringEncoding];
}

static NSString *RDNormalizeAndroidIntent(NSString *spec) {
    if (![spec hasPrefix:@"intent://"]) return nil;
    NSRange marker = [spec rangeOfString:@"#Intent;"];
    if (marker.location == NSNotFound) return nil;
    NSString *base = [spec substringWithRange:NSMakeRange(7, marker.location-7)];
    NSString *tail = [spec substringFromIndex:NSMaxRange(marker)];
    NSString *scheme = nil;
    for (NSString *part in [tail componentsSeparatedByString:@";"]) {
        if ([part hasPrefix:@"scheme="]) { scheme=[part substringFromIndex:7]; break; }
    }
    if (!scheme.length) return nil;
    NSCharacterSet *allowed=[NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789+.-"];
    if ([scheme rangeOfCharacterFromSet:[allowed invertedSet]].location!=NSNotFound ||
        ![[NSCharacterSet letterCharacterSet] characterIsMember:[scheme characterAtIndex:0]]) return nil;
    return [NSString stringWithFormat:@"%@://%@", scheme, base];
}
static NSURL *RDNativeCustomURL(NSString *spec) {
    if (!spec.length || spec.length > RD_URL_CAP-1 ||
        [spec rangeOfCharacterFromSet:[NSCharacterSet controlCharacterSet]].location!=NSNotFound ||
        [spec rangeOfCharacterFromSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]].location!=NSNotFound) return nil;
    NSString *input = RDNormalizeAndroidIntent(spec) ?: spec;
    char normalized[RD_URL_CAP+2];
    if (!RDNormalizeAppURL(input.UTF8String, normalized, sizeof(normalized))) return nil;
    NSURLComponents *parts=[NSURLComponents componentsWithString:[NSString stringWithUTF8String:normalized]];
    if (!parts.scheme.length || RDNativeInternalScheme(parts.scheme)) return nil;
    return parts.URL;
}
static NSURL *RDTelegramUniversalURL(NSURL *appURL) {
    NSURLComponents *source=[NSURLComponents componentsWithURL:appURL resolvingAgainstBaseURL:NO];
    if (![source.scheme.lowercaseString isEqualToString:@"tg"] || ![source.host.lowercaseString isEqualToString:@"resolve"]) return nil;
    NSMutableDictionary *query=[NSMutableDictionary dictionary];
    for (NSURLQueryItem *item in source.queryItems ?: @[]) if (item.value) query[item.name]=item.value;
    NSString *domain=query[@"domain"]; if (!domain.length) return nil;
    NSMutableString *path=[NSMutableString stringWithFormat:@"/%@",domain];
    if (query[@"appname"]) [path appendFormat:@"/%@",query[@"appname"]];
    if (query[@"thread"]) [path appendFormat:@"/%@",query[@"thread"]];
    if (query[@"post"]) [path appendFormat:@"/%@",query[@"post"]];
    if (query[@"album"]) [path appendFormat:@"/a/%@",query[@"album"]];
    else if (query[@"collection"]) [path appendFormat:@"/c/%@",query[@"collection"]];
    NSSet *pathKeys=[NSSet setWithArray:@[@"domain",@"appname",@"thread",@"post",@"album",@"collection"]];
    NSMutableArray *rest=[NSMutableArray array];
    for (NSURLQueryItem *item in source.queryItems ?: @[]) if (![pathKeys containsObject:item.name]) [rest addObject:item];
    NSURLComponents *web=[NSURLComponents componentsWithString:@"https://t.me/"];
    web.percentEncodedPath=[path stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLPathAllowedCharacterSet]];
    web.queryItems=rest.count?rest:nil; web.percentEncodedFragment=source.percentEncodedFragment;
    return web.URL;
}
static BOOL RDOpenUniversalSynchronously(NSURL *url) {
    __block BOOL done=NO, accepted=NO;
    [[UIApplication sharedApplication] openURL:url options:@{UIApplicationOpenURLOptionUniversalLinksOnly:@YES}
       completionHandler:^(BOOL success){ accepted=success; done=YES; }];
    CFAbsoluteTime deadline=CFAbsoluteTimeGetCurrent()+1.5;
    while(!done && CFAbsoluteTimeGetCurrent()<deadline) CFRunLoopRunInMode(kCFRunLoopDefaultMode,0.02,false);
    return done && accepted;
}
static BOOL RDOpenCustomSynchronously(NSURL *url) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    BOOL result=[[UIApplication sharedApplication] openURL:url];
#pragma clang diagnostic pop
    return result;
}
static int32_t RDCallOriginal(void*self,void*content,void*uri,const RDGeckoU16String*target,const RDGeckoU16String*file,void*post,void*headers,bool user,uint8_t involvement,void*principal,void*policy) {
    return rdOriginalOnLinkClick(self,content,uri,target,file,post,headers,user,involvement,principal,policy);
}
static int32_t RDNativeOnLinkClick(void*self,void*content,void*uri,const RDGeckoU16String*target,const RDGeckoU16String*file,void*post,void*headers,bool user,uint8_t involvement,void*principal,void*policy) {
    if(!rdOriginalOnLinkClick) return 0;
    if(!RDNativeClickAllowed(RDNativeEnabled(), user, involvement,
                            file == nullptr || file->length == UINT32_MAX,
                            post != nullptr, headers != nullptr))
        return RDCallOriginal(self,content,uri,target,file,post,headers,user,involvement,principal,policy);
    NSString *spec=RDNativeURISpec(uri);
    if(!spec) return RDCallOriginal(self,content,uri,target,file,post,headers,user,involvement,principal,policy);
    NSURLComponents *parts=[NSURLComponents componentsWithString:spec]; NSString *scheme=parts.scheme.lowercaseString;
    if([scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"]) {
        NSURL *web=parts.URL;
        if(web && web.host.length && !web.user.length && !web.password.length && RDOpenUniversalSynchronously(web)) {
            RDNativeLog(@"clicked universal accepted %@",web.absoluteString);
            return RD_NS_ERROR_ABORT;
        }
        return RDCallOriginal(self,content,uri,target,file,post,headers,user,involvement,principal,policy);
    }
    NSURL *app=RDNativeCustomURL(spec);
    if(!app) return RDCallOriginal(self,content,uri,target,file,post,headers,user,involvement,principal,policy);
    NSURL *tgUniversal=RDTelegramUniversalURL(app);
    if(tgUniversal) {
        // The iOS t.me universal link follows Safari into the exact peer/post.
        // Fallback to Telegram's custom URI if Universal Links aren't accepted.
        // Universal link wins only if Telegram accepts it. Otherwise fall back
        // once to the original custom URI; never launch both destinations.
        __block BOOL done=NO, accepted=NO;
        [[UIApplication sharedApplication] openURL:tgUniversal options:@{UIApplicationOpenURLOptionUniversalLinksOnly:@YES}
            completionHandler:^(BOOL ok){accepted=ok;done=YES;}];
        CFAbsoluteTime until=CFAbsoluteTimeGetCurrent()+1.5;
        while(!done&&CFAbsoluteTimeGetCurrent()<until) CFRunLoopRunInMode(kCFRunLoopDefaultMode,0.02,false);
        if(!done||!accepted) RDOpenCustomSynchronously(app);
        return RD_NS_ERROR_ABORT;
    }
    if(RDOpenCustomSynchronously(app)) return RD_NS_ERROR_ABORT;
    return RDCallOriginal(self,content,uri,target,file,post,headers,user,involvement,principal,policy);
}
static BOOL RDNativeXULMatches(const struct mach_header_64 *header) {
    if(!header || header->magic!=MH_MAGIC_64) return NO;
    const uint8_t *p=(const uint8_t *)(header+1); uint64_t textSize=0; BOOL uuid=NO, ios=NO;
    for(uint32_t i=0;i<header->ncmds;i++) {
        const struct load_command *lc=(const struct load_command *)p;
        if(lc->cmdsize<sizeof(*lc)) return NO;
        if(lc->cmd==LC_UUID && lc->cmdsize>=sizeof(struct uuid_command)) uuid=memcmp(((const struct uuid_command *)lc)->uuid,kRDExpectedXULUUID,16)==0;
        if(lc->cmd==LC_SEGMENT_64 && lc->cmdsize>=sizeof(struct segment_command_64)) {
            const struct segment_command_64 *s=(const struct segment_command_64 *)lc;
            if(strncmp(s->segname,"__TEXT",16)==0 && s->vmaddr==0) textSize=s->vmsize;
        }
        if(lc->cmd==LC_BUILD_VERSION && lc->cmdsize>=sizeof(struct build_version_command)) {
            const struct build_version_command *b=(const struct build_version_command *)lc;
            ios=b->platform==PLATFORM_IOS && b->minos<=(15u<<16|5u<<8);
        }
        p+=lc->cmdsize;
    }
    return uuid&&ios&&textSize>RD_XUL_ON_LINK_CLICK+sizeof(kRDLinkPrologue);
}
static void RDInstallNativeXULHook(void) {
    for(uint32_t i=0;i<_dyld_image_count();i++) {
        const char *n=_dyld_get_image_name(i); if(!n||!strstr(n,"/Frameworks/XUL")) continue;
        const struct mach_header_64 *h=(const struct mach_header_64 *)_dyld_get_image_header(i);
        if(!RDNativeXULMatches(h)) { RDNativeLog(@"XUL UUID/version mismatch; hook skipped"); return; }
        uintptr_t a=(uintptr_t)_dyld_get_image_vmaddr_slide(i)+RD_XUL_ON_LINK_CLICK;
        if(memcmp((const void *)a,kRDLinkPrologue,sizeof(kRDLinkPrologue))!=0) { RDNativeLog(@"OnLinkClick prologue mismatch; hook skipped"); return; }
        MSHookFunction((void *)a,(void *)&RDNativeOnLinkClick,(void **)&rdOriginalOnLinkClick);
        RDNativeLog(@"native-only OnLinkClick installed=%d",rdOriginalOnLinkClick!=NULL); return;
    }
    RDNativeLog(@"XUL image missing; original Safari redirect retained");
}
#endif
