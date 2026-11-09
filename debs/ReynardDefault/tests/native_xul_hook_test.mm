#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <mach-o/dyld.h>
#import <string.h>
#import "../ReynardHook.xm"

// Host integration harness includes the production hook translation unit.
// Fake XUL/UIApplication only; no sample device, network, jailbreak or Gecko execution.
static unsigned checks;
#define CHECK(x) do { checks++; if (!(x)) { fprintf(stderr,"FAIL line %d: %s\n",__LINE__,#x); abort(); } } while(0)
@interface UIApplication (RDHostTest)
@property(nonatomic) BOOL rdAccepted;
@property(nonatomic,strong) NSMutableArray *rdOpened;
@end
@implementation UIApplication (RDHostTest)
static BOOL rdAcceptUniversal=YES,rdAcceptCustom=YES;
+ (UIApplication *)sharedApplication { static UIApplication *a; static dispatch_once_t once; dispatch_once(&once,^{a=[UIApplication new];objc_setAssociatedObject(a,@selector(rdOpened),[NSMutableArray array],OBJC_ASSOCIATION_RETAIN_NONATOMIC);});return a; }
- (BOOL)rdAccepted{return YES;}- (void)setRdAccepted:(BOOL)v{(void)v;}
- (NSMutableArray *)rdOpened{return objc_getAssociatedObject(self,@selector(rdOpened));}
- (void)openURL:(NSURL *)u options:(NSDictionary *)o completionHandler:(void(^)(BOOL))c { [self.rdOpened addObject:@{ @"url":u.absoluteString, @"universal":@([o[UIApplicationOpenURLOptionUniversalLinksOnly] boolValue]) }]; if(c)c(o[UIApplicationOpenURLOptionUniversalLinksOnly]?rdAcceptUniversal:rdAcceptCustom); }
- (BOOL)openURL:(NSURL *)u { [self.rdOpened addObject:@{@"url":u.absoluteString,@"universal":@NO}]; return rdAcceptCustom; }
@end
static int origCalls;
static int32_t FakeOriginal(void *s,void *c,void *u,const RDGeckoU16String *t,const RDGeckoU16String *f,void *p,void *h,bool b,uint8_t i,void *pr,void *pc){(void)s;(void)c;(void)u;(void)t;(void)f;(void)p;(void)h;(void)b;(void)i;(void)pr;(void)pc;origCalls++;return 0;}
static NSString *MakeSpec(const char *text){return [NSString stringWithUTF8String:text];}
int main(void){@autoreleasepool{
 rdOriginalOnLinkClick=FakeOriginal;
 Class c=objc_getClass("_TtC9GeckoView27GeckoEventDispatcherWrapper");CHECK(c!=Nil);
 CHECK(class_getInstanceMethod(c,@selector(attach:))!=NULL);
 Method m=class_getInstanceMethod(c,@selector(dispatchToSwift:message:callback:));CHECK(m&&method_getNumberOfArguments(m)==5);
 RDGeckoAutoCString spec={{NULL,0,0,1},32767,{0}};CHECK(offsetof(RDGeckoAutoCString,storage)==16);CHECK(sizeof(RDGeckoU16String)==16);
 const char *tg="tg:resolve?domain=moonup_chat&start=a%2Bb&post=17#x";size_t n=strlen(tg);CHECK(n<sizeof(spec.storage));memcpy(spec.storage,tg,n+1);spec.base.data=spec.storage;spec.base.length=(uint32_t)n;spec.base.dataFlags=0x11;
 NSString *read=RDURISpec(&spec);CHECK([read isEqualToString:MakeSpec(tg)]);
 char normalized[RD_URL_CAP];CHECK(RDNormalizeAppURL(read.UTF8String,normalized,sizeof(normalized)));CHECK(!strcmp(normalized,"tg://resolve?domain=moonup_chat&start=a%2Bb&post=17#x"));
 NSUInteger before=[UIApplication.sharedApplication.rdOpened count];rdEnabled=YES;
 int32_t rv=RDOnLinkClick((void*)1,(void*)2,&spec,NULL,NULL,NULL,NULL,true,1,NULL,NULL);
 CHECK(rv==RD_NS_ERROR_ABORT);CHECK(origCalls==0);CHECK([UIApplication.sharedApplication.rdOpened count]==before+1);
 CHECK([UIApplication.sharedApplication.rdOpened.lastObject[@"url"] isEqual:@"tg://resolve?domain=moonup_chat&start=a%2Bb&post=17#x"]);
 before=[UIApplication.sharedApplication.rdOpened count];rv=RDOnLinkClick((void*)1,(void*)2,&spec,NULL,NULL,NULL,NULL,false,0,NULL,NULL);CHECK(rv==0);CHECK(origCalls==1);CHECK([UIApplication.sharedApplication.rdOpened count]==before);
 const char *mail="mailto:a@example.com?subject=x%26y";n=strlen(mail);memset(&spec,0,sizeof(spec));spec.inlineCapacity=32767;memcpy(spec.storage,mail,n+1);spec.base.data=spec.storage;spec.base.length=n;spec.base.dataFlags=0x11;
 before=[UIApplication.sharedApplication.rdOpened count];rv=RDOnLinkClick((void*)1,(void*)2,&spec,NULL,NULL,NULL,NULL,true,1,NULL,NULL);CHECK(rv==RD_NS_ERROR_ABORT);CHECK([UIApplication.sharedApplication.rdOpened.lastObject[@"url"] isEqual:MakeSpec(mail)]);CHECK([UIApplication.sharedApplication.rdOpened count]==before+1);
 printf("NATIVE_XUL_HOOK_TESTS=%u\n",checks);return 0;
}}
