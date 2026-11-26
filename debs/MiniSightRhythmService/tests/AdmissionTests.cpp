// SPDX-License-Identifier: MIT
// Pure host executable. NO Tweak/AudioToolbox/socket/constructor is linked.
#include "CaptureAdmission.h"
#include "ActiveSourceToken.h"
#include "MiniSightRhythmReceivePolicy.h"
#include <cassert>
#include <cstdio>
#include <limits>
using namespace MSRhythmAdmission;
int main() {
 assert(AppleOutputMixer(kMixer,kMultiChannel,kApple,2,0));
 assert(!AppleOutputMixer(FourCC('a','u','o','u'),kMultiChannel,kApple,2,0)); // IO
 assert(!AppleOutputMixer(kMixer,FourCC('r','i','o','c'),kApple,2,0)); // mic/RemoteIO
 assert(!AppleOutputMixer(kMixer,kMultiChannel,FourCC('x','x','x','x'),2,0));
 assert(!AppleOutputMixer(kMixer,kMultiChannel,kApple,1,0)); // input
 assert(!AppleOutputMixer(kMixer,kMultiChannel,kApple,0,0)); // global != output
 assert(!AppleOutputMixer(kMixer,kMultiChannel,kApple,2,1));
 Format f{kPCM,kFloat|kPacked,32,2,8,8,1,48000};
 assert(SelectFormat(f,4096)==Layout::InterleavedStereoFloat32);
 f.channels=1;f.bytesPerFrame=f.bytesPerPacket=4;assert(SelectFormat(f,128)==Layout::MonoFloat32);
 f.channels=2;f.flags|=kNonInterleaved;assert(SelectFormat(f,128)==Layout::NonInterleavedStereoFloat32);
 auto reject=[&](Format g){assert(SelectFormat(g,128)==Layout::Unsupported);};
 auto bad=f;bad.flags=0;reject(bad);bad=f;bad.flags|=2;reject(bad); // big endian
 bad=f;bad.flags|=4;reject(bad);bad=f;bad.bits=16;reject(bad);
 bad=f;bad.channels=6;reject(bad);bad=f;bad.framesPerPacket=2;reject(bad);
 bad=f;bad.bytesPerPacket=8;reject(bad);bad=f;bad.rate=7999;reject(bad);
 bad=f;bad.rate=192001;reject(bad);bad=f;bad.rate=std::numeric_limits<double>::quiet_NaN();reject(bad);
 assert(SelectFormat(f,0)==Layout::Unsupported && SelectFormat(f,4097)==Layout::Unsupported);
 assert(LoopbackEndpoint(true,0x7f000001,10000));
 assert(LoopbackEndpoint(true,0x7f000001,44334,true));
 assert(!LoopbackEndpoint(true,0x7f000002,44334,true));
 assert(!LoopbackEndpoint(true,0xc0a80101,44334));assert(!LoopbackEndpoint(false,0x7f000001,44334));
 assert(!LoopbackEndpoint(true,0x7f000001,44335,true));assert(!LoopbackEndpoint(true,0x7f000001,0));
 assert(RenderMayCopy(true,0,true,true,true));
 assert(!RenderMayCopy(false,0,true,true,true)); // original guard
 assert(!RenderMayCopy(true,-1,true,true,true)); // original failure
 assert(!RenderMayCopy(true,0,false,true,true)); // zero subscriber / expired demand
 assert(!RenderMayCopy(true,0,true,false,true)); // old source generation
 assert(!RenderMayCopy(true,0,true,true,false)); // wrong unit / bus
 MSRhythmReceiveState rx{};MSRhythmEnvelope e{7,8,1};
 MSRhythmFrame q{1,1,1.,.5,.2,.9,.2,.6,MSRhythmFlagValid|MSRhythmFlagBeat};
 assert(MSRhythmReceive(&rx,&e,&q,100)==MSRhythmReceiveReset);
 e.sequence++;q.sequence++;q.sampleTime+=.02;
 assert(MSRhythmReceive(&rx,&e,&q,100.02)==MSRhythmReceiveUpdate);
 assert(!MSRhythmReceiveFresh(&rx,100.5)); // <=.35 second lease on motion evidence
 assert(MSRhythmReceive(&rx,&e,&q,100.03)==MSRhythmReceiveReject); // duplicate
 e.sequence++;q.sequence++;q.sampleTime+=.8;
 assert(MSRhythmReceive(&rx,&e,&q,100.04)==MSRhythmReceiveReset); // dropped sample clock
 e.server=9;e.sequence=1;q.epoch=2;q.sequence=1;q.sampleTime=0;
 assert(MSRhythmReceive(&rx,&e,&q,100.05)==MSRhythmReceiveReset); // server/epoch flip
 e.server=8;e.sequence=999;
 assert(MSRhythmReceive(&rx,&e,&q,100.06)==MSRhythmReceiveReject); // retired server
 puts("PASS: production pure format/output/loopback/original/demand/generation + drop/timeout/sessionflip; no audio/socket");
}
