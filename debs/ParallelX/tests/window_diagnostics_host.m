#define main PXWMLegacyStoreHostMain
#include "window_memory_store_host.m"
#undef main
#import "../Common/PXWindowDiagnosticHistory.h"
#import "../Common/PXCloneTraceIO.h"

@interface PXWindowMemoryStore (DiagnosticTestBoundary)
- (int)lockDocument:(NSError **)error;
- (id)readDocument:(const char *)name absent:(BOOL *)absent error:(NSError **)error;
- (BOOL)writeDocument:(id)value name:(const char *)name error:(NSError **)error;
- (void)receiveDiagnosticStatus:(uint64_t)value;
@end
@interface PXWMDiagnosticTestStore : PXWindowMemoryStore
@property(nonatomic) unsigned fault;
@property(nonatomic) uint64_t observedHealth;
@end
@implementation PXWMDiagnosticTestStore
- (int)lockDocument:(NSError **)error {
 if (self.fault==1) { if(error)*error=[NSError errorWithDomain:@"fixture" code:EACCES userInfo:nil];return -1; }
 return [super lockDocument:error];
}
- (id)readDocument:(const char *)name absent:(BOOL *)absent error:(NSError **)error {
 BOOL recent=strstr(name,"diagnostics")!=NULL,archive=strstr(name,"incidents")!=NULL;
 if ((self.fault==2 && recent)||(self.fault==3 && archive)) {
  if(absent)*absent=NO;if(error)*error=[NSError errorWithDomain:@"fixture" code:EIO userInfo:nil];return nil;
 }
 return [super readDocument:name absent:absent error:error];
}
- (BOOL)writeDocument:(id)value name:(const char *)name error:(NSError **)error {
 BOOL recent=strstr(name,"diagnostics")!=NULL,archive=strstr(name,"incidents")!=NULL;
 if ((recent && (self.fault==4||self.fault==6)) || (archive && (self.fault==5||self.fault==7))) {
  if(error)*error=[NSError errorWithDomain:@"fixture" code:EIO userInfo:@{@"traceIOResult":@(self.fault>=6?PXCloneTraceIOReadbackFailed:PXCloneTraceIOWriteFailed)}];return NO;
 }
 return [super writeDocument:value name:name error:error];
}
- (void)receiveDiagnosticStatus:(uint64_t)value {
 if ((value>>48)==(uint64_t)(getpid()&65535)) self.observedHealth=value;
 [super receiveDiagnosticStatus:value];
}
@end
static unsigned checks;
#define CHECK(x) do { checks++;if(!(x)){fprintf(stderr,"FAIL line %d %s\n",__LINE__,#x);return 1;} } while(0)
static BOOL barrier(PXWindowMemoryStore *store) {
 // The existing no-change settings transaction completes on the same worker
 // after all preceding log writes; unlike a notification, it cannot be stale.
 return drain(store);
}
static NSDictionary *event(unsigned sequence,unsigned serial,BOOL fault,NSString *session) {
 return @{@"event":@"fixture",@"build":@"clone0.116",@"pid":@7,@"session":session,@"sequence":@(sequence),
  @"time":@(1000+sequence*.1),@"state":@{@"appHash":@10,@"openSerial":@(serial),@"diagIncident":@(fault)}};
}
static int history(void) {
 NSString *session=@"00000000-0000-0000-0000-000000000001";
 NSMutableArray *recent=[NSMutableArray array];NSDictionary *archive=@{@"schema":@1,@"incidents":@[]};
 for(unsigned i=0;i<300;i++) {
  NSDictionary *e=event(i,1,i==20,session);archive=PXWMDiagnosticMerge(archive,recent,e);
  [recent addObject:e];while(recent.count>256)[recent removeObjectAtIndex:0];
 }
 CHECK(PXWMDiagnosticValidArchive(archive));CHECK([archive[@"incidents"] count]==1);
 NSDictionary *item=[archive[@"incidents"] firstObject];
 CHECK([item[@"before"] count]==12 && [item[@"after"] count]==12);
 CHECK([item[@"trigger"][@"sequence"] unsignedIntValue]==20);
 CHECK([recent[0][@"sequence"] unsignedIntValue]>20);
 NSDictionary *frozen=archive;
 for(unsigned i=301;i<900;i++) archive=PXWMDiagnosticMerge(archive,recent,event(i,99,NO,session));
 CHECK([archive isEqual:frozen]); // Other apps/openings cannot fill or evict a fragment.
 NSMutableDictionary *recovery=[event(300,1,NO,session) mutableCopy];recovery[@"event"]=@"restore_postlayout_geometry_verified";
 archive=PXWMDiagnosticMerge(archive,recent,[recovery copy]);
 CHECK([archive[@"incidents"][0][@"lastOutcome"] isEqual:recovery]);
 CHECK(![archive[@"incidents"][0][@"recovered"] boolValue]);
 recovery[@"event"]=@"content_geometry_probe";
 recovery[@"sequence"]=@301;
 recovery[@"state"]=@{@"appHash":@10,@"openSerial":@1,@"diagIncident":@NO,@"measured":@YES};
 archive=PXWMDiagnosticMerge(archive,recent,[recovery copy]);
 CHECK(![archive[@"incidents"][0][@"recovered"] boolValue]);
 recovery[@"sequence"]=@302;
 recovery[@"state"]=@{@"appHash":@10,@"openSerial":@1,@"diagIncident":@NO,@"measured":@YES,
     @"bundleMatch":@YES,@"canvasMatch":@YES,@"cardMatch":@YES};
 archive=PXWMDiagnosticMerge(archive,recent,[recovery copy]);
 CHECK([archive[@"incidents"][0][@"recovered"] boolValue]);
 archive=PXWMDiagnosticMerge(archive,recent,event(310,1,YES,session));
 CHECK([archive[@"incidents"] count]==2);
 for(unsigned i=2;i<10;i++) archive=PXWMDiagnosticMerge(archive,recent,event(320+i,i,YES,session));
 CHECK([archive[@"incidents"] count]==4);CHECK(PXWMDiagnosticValidArchive(archive));
 NSDictionary *other=event(400,1,YES,@"00000000-0000-0000-0000-000000000002");
 CHECK(!PXWMDiagnosticSameWindow(other,event(400,1,YES,session)));
 CHECK(!PXWMDiagnosticValidArchive(@{@"schema":@1,@"incidents":@[@42]}));
 CHECK(!PXWMDiagnosticValidRecent(@[@42]));
 CHECK(!PXWMDiagnosticValidEvent(@{@"event":@"bad",@"state":@{@"token":@"secret"}}));
 printf("PASS history checks=%u\n",checks);return 0;
}
int main(int argc,const char **argv) { @autoreleasepool {
 if(argc!=2)return 2;
 if(!strcmp(argv[1],"history"))return history();
 PXWMDiagnosticTestStore *store=[PXWMDiagnosticTestStore new];
 spin(^BOOL{return store.isLoaded || store.errorText.length>0;});CHECK(store.isLoaded);
 NSString *action=[NSString stringWithUTF8String:argv[1]];
 NSString *root=[PXCloneCurrentPrefsPath(NULL) stringByDeletingLastPathComponent];
 NSString *log=[root stringByAppendingPathComponent:@"com.niubiprass.clonex.window-memory-diagnostics.plist"];
 NSString *inc=[root stringByAppendingPathComponent:@"com.niubiprass.clonex.window-memory-incidents.plist"];
 if([action isEqual:@"rollover"]) {
  for(unsigned i=0;i<350;i++) [store diagnostic:@"fixture" details:@{@"appHash":@10,@"openSerial":@1,@"index":@(i),@"diagIncident":@(i==20)}];
  CHECK(barrier(store));
  NSArray *recent=[NSArray arrayWithContentsOfFile:log];NSDictionary *archive=[NSDictionary dictionaryWithContentsOfFile:inc];
  CHECK(recent.count==256);CHECK([archive[@"incidents"] count]==1);
  CHECK([archive[@"incidents"][0][@"trigger"][@"state"][@"index"] unsignedIntValue]==20);
  CHECK([archive[@"incidents"][0][@"after"] count]==12);CHECK((store.observedHealth&255)==PXWMDiagnosticVerified);
 } else if([action hasPrefix:@"fault"]) {
  unsigned mode=(unsigned)[[action substringFromIndex:5] intValue];CHECK(mode>=1 && mode<=7);
  NSDictionary *snapshot=store.snapshot;store.fault=mode;
  [store diagnostic:@"fixture" details:@{@"appHash":@10,@"openSerial":@1,@"diagIncident":@YES}];
  spin(^BOOL{return (store.observedHealth&255)>1;});
  unsigned expected[]={0,2,3,4,5,6,8,9};CHECK((store.observedHealth&255)==expected[mode]);
  CHECK(store.isLoaded);CHECK([store.snapshot isEqual:snapshot]);CHECK(store.errorText.length==0);
  store.fault=0;[store diagnostic:@"fixture_recovered" details:@{@"appHash":@10,@"openSerial":@1}];CHECK(barrier(store));
  CHECK((store.observedHealth&255)==1);CHECK(((store.observedHealth>>8)&255)==expected[mode]);
 } else if([action isEqual:@"corrupt"]) {
  NSData *bad=[@"not-plist" dataUsingEncoding:NSUTF8StringEncoding];CHECK([bad writeToFile:inc atomically:YES]);
  [store diagnostic:@"fixture" details:@{@"appHash":@10,@"openSerial":@1,@"diagIncident":@YES}];CHECK(barrier(store));
  CHECK((store.observedHealth&255)==PXWMDiagnosticArchiveReadFailed);
  CHECK([[NSData dataWithContentsOfFile:inc] isEqual:bad]);CHECK(store.isLoaded);
  CHECK([NSArray arrayWithContentsOfFile:log].count>0);
 } else if([action isEqual:@"fifo"]) {
  CHECK(mkfifo(inc.fileSystemRepresentation,0600)==0);
  [store diagnostic:@"fixture" details:@{@"appHash":@10,@"openSerial":@1,@"diagIncident":@YES}];CHECK(barrier(store));
  CHECK((store.observedHealth&255)==PXWMDiagnosticArchiveReadFailed);CHECK(store.isLoaded);
 } else if([action isEqual:@"symlink"]) {
  NSString *outside=[root stringByAppendingPathComponent:@"outside.fixture"];
  NSData *original=[@"keep" dataUsingEncoding:NSUTF8StringEncoding];CHECK([original writeToFile:outside atomically:YES]);
  CHECK(symlink(outside.fileSystemRepresentation,inc.fileSystemRepresentation)==0);
  [store diagnostic:@"fixture" details:@{@"appHash":@10,@"openSerial":@1,@"diagIncident":@YES}];CHECK(barrier(store));
  CHECK((store.observedHealth&255)==PXWMDiagnosticArchiveReadFailed);
  CHECK([[NSData dataWithContentsOfFile:outside] isEqual:original]);
 } else return 2;
 printf("PASS %s checks=%u\n",argv[1],checks);return 0;
} }
