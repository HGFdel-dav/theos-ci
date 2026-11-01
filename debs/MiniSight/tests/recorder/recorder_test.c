#define _POSIX_C_SOURCE 200809L
#include "../../tools/recorder/MiniSightRecorderCore.h"
#include "../../tools/recorder/MiniSightRecorderFile.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>

static unsigned checks;
#define CHECK(x) do { ++checks; assert(x); } while (0)
static MSRSnapshot idle(void) {
    return (MSRSnapshot){ .valid=true, .available=true, .destination=true, .continuous=true };
}
static MSRSnapshot live(void) {
    MSRSnapshot s = idle(); s.recording=s.system=s.captured=true; return s;
}
static MSRMachine enabled(void) {
    MSRMachine m; MSRInit(&m);
    CHECK(!MSRConfigure(&m, true, true, 0, idle())); return m;
}
static MSRMachine recording(void) {
    MSRMachine m = enabled();
    CHECK(MSRBegin(&m, MiniSightRecorderSourceManual, 1, idle()) == MSRStart);
    CHECK(m.pendingStart && !m.owned && m.state == MiniSightRecorderStarting);
    CHECK(!MSRStartReply(&m, m.epoch, true, 2, live()));
    CHECK(m.owned && m.state == MiniSightRecorderRecording); return m;
}
static MSRMachine saving(void) {
    MSRMachine m = recording();
    CHECK(MSRRequestStop(&m, MiniSightRecorderSourceManual, 3, live()) == MSRStop);
    CHECK(!MSRRequestStop(&m, MiniSightRecorderSourceManual, 3.1, live()));
    CHECK(MSRStopReply(&m, m.epoch, true, true, 4) == MSRSave);
    CHECK(m.state == MiniSightRecorderSaving && !m.owned && !m.reported); return m;
}
static void scenarios(void) {
    MSRMachine m; MSRInit(&m);
    CHECK(MSRBegin(&m, MiniSightRecorderSourceManual, 0, idle()) == MSRReport);
    CHECK(m.issue == MiniSightRecorderIssueDisabled && !MSRBusy(&m));
    m = enabled(); MSRSnapshot s = idle(); s.valid=false;
    CHECK(MSRBegin(&m, MiniSightRecorderSourceManual, 0, s) == MSRReport);
    CHECK(m.issue == MiniSightRecorderIssueUnavailable && !m.owned);
    s=idle(); s.destination=false; m=enabled();
    CHECK(MSRBegin(&m, MiniSightRecorderSourceManual, 0, s) == MSRReport);
    CHECK(m.issue == MiniSightRecorderIssueDestination);
    s=idle(); s.available=false; m=enabled();
    CHECK(MSRBegin(&m, MiniSightRecorderSourceManual, 0, s) == MSRReport);
    CHECK(m.issue == MiniSightRecorderIssueUnavailable);
    for (unsigned i=1; i<4; ++i) {
        m=enabled(); s=idle(); s.recording=(i&1)!=0; s.captured=(i&2)!=0;
        CHECK(MSRBegin(&m, MiniSightRecorderSourceManual, 0, s) == MSRReport);
        CHECK(m.issue == MiniSightRecorderIssueExternalSession && !m.owned);
        CHECK(!MSRRequestStop(&m, MiniSightRecorderSourceManual, 1, s));
        CHECK(!MSRRequestStop(&m, MiniSightRecorderSourceAutomatic, 1, s));
    }
    m=enabled(); s=idle(); s.system=true; /* Leftover mode after a failed start. */
    CHECK(MSRBegin(&m, MiniSightRecorderSourceManual, 0, s) == MSRStart);
    CHECK(MSRStartReply(&m, m.epoch, false, 1, s) == MSRReport);
    CHECK(m.issue == MiniSightRecorderIssueStartFailed && !MSRBusy(&m));
    uint64_t old=m.epoch;
    CHECK(MSRBegin(&m, MiniSightRecorderSourceManual, 2, s) == MSRStart);
    CHECK(!MSRStartReply(&m, old, true, 3, live()));
    CHECK(!m.owned && m.pendingStart);
    m=saving();
    CHECK(MSRSaved(&m, m.epoch, true, 5) == MSRReport);
    CHECK(m.state == MiniSightRecorderIdle && m.issue == MiniSightRecorderIssueNone);
    CHECK(!MSRSaved(&m, m.epoch, true, 6));
    m=saving(); CHECK(MSRSaved(&m, m.epoch, false, 5) == MSRReport);
    CHECK(m.issue == MiniSightRecorderIssueSaveFailed);
    m=recording(); CHECK(MSRRequestStop(&m, MiniSightRecorderSourceManual, 3, live()) == MSRStop);
    CHECK(MSRStopReply(&m, m.epoch, true, false, 4) == MSRReport);
    CHECK(m.issue == MiniSightRecorderIssueMissingArtifact && !m.saving);
    m=recording(); CHECK(MSRRequestStop(&m, MiniSightRecorderSourceManual, 3, live()) == MSRStop);
    CHECK(MSRStopReply(&m, m.epoch, false, true, 4) == MSRReport);
    CHECK(m.issue == MiniSightRecorderIssueStopFailed);
    m=enabled(); CHECK(MSRToggle(&m, 0, idle()) == MSRStart);
    CHECK(!MSRToggle(&m, 0.1, idle()) && !m.stopWanted);
    CHECK(!MSRToggle(&m, 0.4, idle()) && m.stopWanted);
    CHECK(MSRStartReply(&m, m.epoch, true, 1, live()) == MSRStop);
    CHECK(!m.cancelled);
    CHECK(MSRStopReply(&m, m.epoch, true, true, 2) == MSRSave);
    CHECK(MSRSaved(&m, m.epoch, true, 2.1) == MSRReport);
    m=enabled(); CHECK(MSRAutomaticActive(&m, true, 0, idle()) == MSRStart);
    CHECK(!MSRAutomaticActive(&m, true, 0.2, idle()));
    CHECK(!MSRBegin(&m, MiniSightRecorderSourceManual, 0.5, idle()));
    CHECK(m.owner == MiniSightRecorderSourceAutomatic); /* Long press cannot adopt MCP capture. */
    CHECK(!MSRToggle(&m, 0.5, live()) && m.owner == MiniSightRecorderSourceAutomatic);
    CHECK(!MSRAutomaticActive(&m, false, 0.6, idle()) && m.stopWanted);
    CHECK(MSRStartReply(&m, m.epoch, true, 1, live()) == MSRStop);
    CHECK(m.owner == MiniSightRecorderSourceAutomatic && m.pendingStop);
    CHECK(!MSRRequestStop(&m, MiniSightRecorderSourceManual, 1.1, live()));
    CHECK(!m.cancelled);
    CHECK(MSRStopReply(&m, m.epoch, true, true, 2) == MSRSave);
    CHECK(MSRSaved(&m, m.epoch, true, 2.1) == MSRReport);
    m=enabled(); CHECK(MSRAutomaticActive(&m, true, 0, idle()) == MSRStart);
    CHECK(!MSRStartReply(&m, m.epoch, true, 1, live()));
    CHECK(MSRConfigure(&m, false, true, 2, live()) == MSRStop);
    CHECK(m.pendingStop && m.owner == MiniSightRecorderSourceAutomatic);
    CHECK(!MSRRequestStop(&m, MiniSightRecorderSourceManual, 2.1, live()));
    CHECK(!MSRConfigure(&m, false, true, 3, live()));
    m=enabled(); CHECK(MSRToggle(&m, 0, idle()) == MSRStart); /* Manual still starts. */
    CHECK(!MSRStartReply(&m, m.epoch, true, 1, live()));
    CHECK(MSRToggle(&m, 1, live()) == MSRStop); /* Manual still stops its own session. */
    m=enabled(); CHECK(!MSRConfigure(&m, true, false, 0, idle()));
    CHECK(MSRAutomaticActive(&m, true, 0, idle()) == MSRStart);
    CHECK(!MSRBegin(&m, MiniSightRecorderSourceManual, 0.5, idle()));
    CHECK(m.owner == MiniSightRecorderSourceAutomatic); /* Disabled cannot promote. */
    CHECK(!MSRConfigure(&m, false, false, 0.8, idle()) && !m.cancelled && m.stopWanted);
    CHECK(MSRStartReply(&m, m.epoch, true, 1, live()) == MSRStop);
    m=recording();
    CHECK(!MSRRequestStop(&m, (MiniSightRecorderSource)999, 3, live()));
    CHECK(!MSRTick(&m, 600.9, live()));
    CHECK(MSRTick(&m, 601, live()) == MSRStop);
    CHECK(!MSRTick(&m, 601.1, live()));
    CHECK(MSRStopReply(&m, m.epoch, true, true, 602) == MSRSave);
    CHECK(MSRSaved(&m, m.epoch, true, 603) == MSRReport);
    m=enabled(); CHECK(MSRBegin(&m, MiniSightRecorderSourceManual, 0, idle()) == MSRStart);
    CHECK(MSRTick(&m, 15, idle()) == MSRReport);
    CHECK(m.pendingStart && m.state == MiniSightRecorderError && m.stopWanted);
    old=m.epoch; CHECK(!MSRBegin(&m, MiniSightRecorderSourceManual, 15.1, idle()));
    CHECK(m.epoch == old && m.pendingStart);
    CHECK(MSRStartReply(&m, old, true, 16, live()) == MSRStop);
    CHECK(MSRTick(&m, 46, live()) == MSRNoAction);
    CHECK(m.pendingStop && m.state == MiniSightRecorderError); /* No endless stopping. */
    CHECK(!MSRStopReply(&m, old, true, true, 47));
    CHECK(!MSRBusy(&m) && m.issue == MiniSightRecorderIssueStartTimeout);
    m=enabled(); CHECK(MSRBegin(&m, MiniSightRecorderSourceManual, 0, idle()) == MSRStart);
    CHECK(MSRStartReply(&m, m.epoch, true, 15, live()) == (MSRReport|MSRStop));
    CHECK(m.issue == MiniSightRecorderIssueStartTimeout);
    m=enabled(); CHECK(MSRBegin(&m, MiniSightRecorderSourceManual, 0, idle()) == MSRStart);
    CHECK(MSRTick(&m, 15, idle()) == MSRReport);
    s=live(); s.continuous=false;
    CHECK(!MSRStartReply(&m, m.epoch, true, 16, s));
    CHECK(!MSRBusy(&m)); /* Late callback cannot stop an observed replacement. */
    m=recording(); CHECK(MSRRequestStop(&m, MiniSightRecorderSourceManual, 3, live()) == MSRStop);
    CHECK(MSRTick(&m, 33, idle()) == MSRReport);
    CHECK(m.pendingStop && m.issue == MiniSightRecorderIssueStopTimeout);
    CHECK(!MSRBegin(&m, MiniSightRecorderSourceManual, 34, idle()));
    CHECK(!MSRStopReply(&m, m.epoch, true, true, 35) && !m.saving);
    m=recording(); CHECK(MSRRequestStop(&m, MiniSightRecorderSourceManual, 3, live()) == MSRStop);
    CHECK(MSRStopReply(&m, m.epoch, true, true, 33) == MSRReport);
    CHECK(m.issue == MiniSightRecorderIssueStopTimeout); /* Timer-starvation path. */
    m=saving(); CHECK(MSRTick(&m, 64, idle()) == (MSRCancelSave|MSRReport));
    CHECK(!MSRSaved(&m, m.epoch, true, 65) && m.issue == MiniSightRecorderIssueSaveTimeout);
    m=saving(); CHECK(MSRSaved(&m, m.epoch, true, 64) == (MSRCancelSave|MSRReport));
    CHECK(m.issue == MiniSightRecorderIssueSaveTimeout);
    m=saving(); old=m.epoch;
    CHECK(MSRCancel(&m, 5, idle()) == (MSRCancelSave|MSRReport));
    CHECK(!MSRSaved(&m, old, true, 6));
    CHECK(MSRBegin(&m, MiniSightRecorderSourceManual, 7, idle()) == MSRStart);
    CHECK(!MSRSaved(&m, old, true, 8) && m.pendingStart);
    for (unsigned i=0; i<4; ++i) {
        m=recording(); s=live();
        if (i==0) s.continuous=false;
        if (i==1) s.captured=false;
        if (i==2) s.recording=false;
        if (i==3) s.valid=false;
        CHECK(MSRRequestStop(&m, MiniSightRecorderSourceManual, 3, s) == MSRReport);
        CHECK(!m.owned && !m.pendingStop && m.issue == MiniSightRecorderIssueOwnershipLost);
        CHECK(!MSRRequestStop(&m, MiniSightRecorderSourceManual, 4, live()));
    }
    m=enabled(); CHECK(MSRBegin(&m, MiniSightRecorderSourceManual, 0, idle()) == MSRStart);
    s=live(); s.system=false;
    CHECK(MSRStartReply(&m, m.epoch, true, 1, s) == MSRReport);
    CHECK(!m.owned && m.issue == MiniSightRecorderIssueOwnershipLost);
    m=enabled(); CHECK(MSRAutomaticActive(&m, true, 0, idle()) == MSRStart);
    CHECK(!MSRStartReply(&m, m.epoch, true, 1, live()));
    CHECK(MSRTick(&m, 600, live()) == MSRStop);
    CHECK(MSRStopReply(&m, m.epoch, true, true, 601) == MSRSave);
    CHECK(MSRSaved(&m, m.epoch, true, 602) == MSRReport);
    CHECK(!MSRAutomaticActive(&m, true, 603, idle()));
    CHECK(!MSRConfigure(&m, true, true, 604, idle())); /* No automatic restart after limit. */
    CHECK(!MSRAutomaticActive(&m, false, 605, idle()));
    CHECK(MSRAutomaticActive(&m, true, 606, idle()) == MSRStart);
}

static void short_clips(void) {
    const double lengths[] = {0.05, 0.5, 1.0, 2.0, 3.0};
    for (unsigned owner=1; owner<=2; ++owner) {
        for (unsigned pending=0; pending<2; ++pending) {
            for (unsigned i=0; i<sizeof(lengths)/sizeof(lengths[0]); ++i) {
                MSRMachine m=enabled();
                MiniSightRecorderSource source=(MiniSightRecorderSource)owner;
                CHECK(MSRBegin(&m, source, 0, idle())==MSRStart);
                double now=lengths[i];
                if (pending) {
                    CHECK(!MSRRequestStop(&m, source, now, idle()));
                    CHECK(m.stopWanted && !m.cancelled);
                    CHECK(MSRStartReply(&m, m.epoch, true, now+0.01, live())==MSRStop);
                } else {
                    CHECK(!MSRStartReply(&m, m.epoch, true, 0.01, live()));
                    CHECK(MSRRequestStop(&m, source, now, live())==MSRStop);
                }
                CHECK(MSRStopReply(&m, m.epoch, true, true, now+0.02)==MSRSave);
                CHECK(MSRSaved(&m, m.epoch, true, now+0.03)==MSRReport);
                CHECK(!MSRBusy(&m) && m.state==MiniSightRecorderIdle);
            }
        }
    }
    MSRMachine m; MSRInit(&m);
    CHECK(!MSRConfigure(&m, false, true, 0, idle()));
    CHECK(!MSRAutomaticActive(&m, true, 0, idle()) && !MSRBusy(&m));
    CHECK(MSRToggle(&m, 1, idle())==MSRStart); // auto off still allows manual capture
    CHECK(!MSRStartReply(&m, m.epoch, true, 1.1, live()));
    CHECK(!MSRAutomaticActive(&m, false, 1.2, live()) && m.owned);
    CHECK(MSRToggle(&m, 2, live())==MSRStop);
    CHECK(MSRStopReply(&m, m.epoch, true, true, 2.1)==MSRSave);
    CHECK(MSRSaved(&m, m.epoch, true, 2.2)==MSRReport);
    m=enabled(); CHECK(MSRBegin(&m, MiniSightRecorderSourceAutomatic, 0, idle())==MSRStart);
    CHECK(!MSRCancel(&m, 0.1, idle()) && m.cancelled);
    CHECK(MSRStartReply(&m, m.epoch, true, 0.2, live())==MSRStop);
    CHECK(MSRStopReply(&m, m.epoch, true, true, 0.3)==MSRReport);
    CHECK(m.issue==MiniSightRecorderIssueCancelled && !m.saving);
}

static uint32_t rng=0x58031555;
static uint32_t random32(void) { rng^=rng<<13; rng^=rng>>17; rng^=rng<<5; return rng; }
static void fuzz(void) {
    MSRMachine m=enabled(); double now=0; unsigned reports=0;
    for (unsigned i=0; i<100000; ++i) {
        MSRMachine before=m; now+=(random32()%1000)/100.0;
        unsigned bits=random32();
        MSRSnapshot s={ .valid=(bits&1)!=0, .available=(bits&2)!=0,
            .recording=(bits&4)!=0, .system=(bits&8)!=0, .captured=(bits&16)!=0,
            .destination=(bits&32)!=0, .continuous=(bits&64)!=0 };
        unsigned event=random32()%10; bool ok=(random32()&1)!=0;
        uint64_t token=(random32()%4) ? m.epoch : m.epoch-1;
        MiniSightRecorderSource source=(random32()&1) ? MiniSightRecorderSourceManual : MiniSightRecorderSourceAutomatic;
        MSRAction a=0;
        switch (event) {
        case 0: a=MSRBegin(&m, source, now, s); break;
        case 1: a=MSRRequestStop(&m, source, now, s); break;
        case 2: a=MSRStartReply(&m, token, ok, now, s); break;
        case 3: a=MSRStopReply(&m, token, ok, (bits&128)!=0, now); break;
        case 4: a=MSRSaved(&m, token, ok, now); break;
        case 5: a=MSRTick(&m, now, s); break;
        case 6: a=MSRConfigure(&m, ok, (bits&128)!=0, now, s); break;
        case 7: a=MSRAutomaticActive(&m, ok, now, s); break;
        case 8: a=MSRToggle(&m, now, s); break;
        case 9: a=MSRCancel(&m, now, s); break;
        }
        if (m.epoch!=before.epoch) reports=0;
        if (a&MSRReport) { ++reports; CHECK(reports==1); }
        if (a&MSRStop) {
            CHECK(s.valid && s.continuous && s.recording && s.system);
            CHECK(m.owned && m.pendingStop && !m.interrupted);
            CHECK(before.owned || (event==2 && before.pendingStart && token==before.epoch && ok));
        }
        if (a&MSRStart) CHECK(s.valid && s.available && s.destination && !s.recording && !s.captured);
        if (a&MSRSave) CHECK(m.saving && !m.reported && m.state==MiniSightRecorderSaving);
        if ((a&MSRReport) && m.state==MiniSightRecorderIdle) CHECK(event==4 && ok && token==before.epoch);
        CHECK(!(m.pendingStart && m.pendingStop));
        CHECK(!m.saving || (!m.owned && !m.pendingStart && !m.pendingStop));
    }
}

static void write_pattern(const char *path, size_t length) {
    int fd=open(path, O_WRONLY|O_CREAT|O_TRUNC, 0600); CHECK(fd>=0);
    char block[4064]; for (size_t i=0;i<sizeof(block);++i) block[i]=(char)(i%127);
    while (length) {
        size_t n=length<sizeof(block) ? length : sizeof(block);
        CHECK(write(fd,block,n)==(ssize_t)n); length-=n;
    }
    CHECK(!close(fd));
}
static void files(void) {
    char root[]="/tmp/minisight-recorder-XXXXXX"; CHECK(mkdtemp(root));
    char source[180], directory[180], target[200], link[200];
    snprintf(source,sizeof(source),"%s/source.mp4",root);
    snprintf(directory,sizeof(directory),"%s/output",root); CHECK(!mkdir(directory,0700));
    write_pattern(source,8192);
    atomic_bool cancelled; atomic_init(&cancelled,false);
    uint64_t bytes=0; int dir=-1; bool published=false;
    CHECK(MSRFileCopy(source,directory,"one.partial.mp4",&cancelled,&bytes,&dir));
    CHECK(bytes==8192 && dir>=0);
    CHECK(MSRFilePublish(dir,"one.partial.mp4","one.mp4",bytes,&cancelled,&published));
    CHECK(published);
    MSRFileCleanup(dir,"one.partial.mp4","one.mp4",false);
    snprintf(target,sizeof(target),"%s/one.mp4",directory);
    struct stat before,after; CHECK(!stat(target,&before));
    CHECK(before.st_size==8192 && (before.st_mode&0777)==0600);
    int fd=open(target,O_RDONLY); CHECK(fd>=0);
    char block[8192]; CHECK(read(fd,block,sizeof(block))==(ssize_t)sizeof(block)); CHECK(!close(fd));
    for (size_t i=0;i<sizeof(block);++i) CHECK(block[i]==(char)(i%127));
    CHECK(MSRFileCopy(source,directory,"two.partial.mp4",&cancelled,&bytes,&dir));
    CHECK(!MSRFilePublish(dir,"two.partial.mp4","one.mp4",bytes,&cancelled,&published));
    CHECK(!published); MSRFileCleanup(dir,"two.partial.mp4","one.mp4",false);
    CHECK(!stat(target,&after) && before.st_ino==after.st_ino);
    snprintf(link,sizeof(link),"%s/source-link.mp4",root); CHECK(!symlink(source,link));
    CHECK(!MSRFileCopy(link,directory,"bad.partial.mp4",&cancelled,&bytes,&dir));
    CHECK(dir==-1);
    CHECK(!MSRFileCopy(directory,directory,"bad.partial.mp4",&cancelled,&bytes,&dir));
    CHECK(!MSRFileCopy(source,directory,"../escape.mp4",&cancelled,&bytes,&dir));
    char directoryLink[180]; snprintf(directoryLink,sizeof(directoryLink),"%s/output-link",root);
    CHECK(!symlink(directory,directoryLink));
    CHECK(!MSRFileCopy(source,directoryLink,"bad.partial.mp4",&cancelled,&bytes,&dir));
    atomic_store(&cancelled,true);
    CHECK(!MSRFileCopy(source,directory,"cancel.partial.mp4",&cancelled,&bytes,&dir));
    atomic_store(&cancelled,false);
    CHECK(MSRFileCopy(source,directory,"cancel.partial.mp4",&cancelled,&bytes,&dir));
    atomic_store(&cancelled,true);
    CHECK(!MSRFilePublish(dir,"cancel.partial.mp4","cancel.mp4",bytes,&cancelled,&published));
    CHECK(!published); MSRFileCleanup(dir,"cancel.partial.mp4","cancel.mp4",false);
    atomic_store(&cancelled,false);
    CHECK(MSRFileCopy(source,directory,"truncated.partial.mp4",&cancelled,&bytes,&dir));
    fd=openat(dir,"truncated.partial.mp4",O_WRONLY); CHECK(fd>=0);
    CHECK(!ftruncate(fd,512)); CHECK(!close(fd));
    CHECK(!MSRFilePublish(dir,"truncated.partial.mp4","truncated.mp4",bytes,&cancelled,&published));
    MSRFileCleanup(dir,"truncated.partial.mp4","truncated.mp4",false);
    write_pattern(source,100);
    CHECK(!MSRFileCopy(source,directory,"empty.partial.mp4",&cancelled,&bytes,&dir));
    CHECK(!MSRLeaf(".") && !MSRLeaf("..") && !MSRLeaf("a/b") && !MSRLeaf(""));
    CHECK(!unlink(target)); CHECK(!unlink(link)); CHECK(!unlink(directoryLink));
    CHECK(!unlink(source)); CHECK(!rmdir(directory)); CHECK(!rmdir(root));
}
int main(void) {
    scenarios(); short_clips(); fuzz(); files();
    printf("PASS: %u checks; 100000 reducer events; real POSIX artifact cases\n",checks);
    return 0;
}
