// SPDX-License-Identifier: MIT
// MiniSight local admission policy. Pure values only: no AudioUnit, clock, IO,
// microphone, Objective-C, allocation, locks or sockets. Used by production.
#pragma once
#include <cmath>
#include <cstdint>
namespace MSRhythmAdmission {
constexpr uint32_t FourCC(char a,char b,char c,char d) {
    return (uint32_t(a)<<24)|(uint32_t(b)<<16)|(uint32_t(c)<<8)|uint32_t(d);
}
constexpr uint32_t kMixer=FourCC('a','u','m','x');
constexpr uint32_t kMultiChannel=FourCC('m','c','m','x');
constexpr uint32_t kApple=FourCC('a','p','p','l');
constexpr uint32_t kPCM=FourCC('l','p','c','m');
constexpr uint32_t kFloat=1u, kPacked=8u, kNonInterleaved=32u;
enum class Layout : uint8_t { Unsupported=0, MonoFloat32,
    InterleavedStereoFloat32, NonInterleavedStereoFloat32 };
struct Format {
    uint32_t id,flags,bits,channels,bytesPerFrame,bytesPerPacket,framesPerPacket;
    double rate;
};
inline bool AppleOutputMixer(uint32_t type,uint32_t subtype,uint32_t manufacturer,
                             uint32_t outputScope,uint32_t bus) {
    // AudioUnit output scope is 2 (global=0, input=1). Never RemoteIO/VoiceIO.
    return type==kMixer && subtype==kMultiChannel && manufacturer==kApple &&
           outputScope==2 && bus==0;
}
inline Layout SelectFormat(const Format &f,uint32_t maximumFrames) {
    const uint32_t allowed=kFloat|kPacked|kNonInterleaved;
    if(f.id!=kPCM || (f.flags&(kFloat|kPacked))!=(kFloat|kPacked) ||
       (f.flags&~allowed)!=0 || f.bits!=32 || !std::isfinite(f.rate) ||
       f.rate<8000 || f.rate>192000 || f.framesPerPacket!=1 ||
       f.bytesPerPacket!=f.bytesPerFrame || maximumFrames==0 || maximumFrames>4096)
        return Layout::Unsupported;
    if(!(f.flags&kNonInterleaved) && f.channels==1 && f.bytesPerFrame==4)
        return Layout::MonoFloat32;
    if(!(f.flags&kNonInterleaved) && f.channels==2 && f.bytesPerFrame==8)
        return Layout::InterleavedStereoFloat32;
    if((f.flags&kNonInterleaved) && f.channels==2 && f.bytesPerFrame==4)
        return Layout::NonInterleavedStereoFloat32;
    return Layout::Unsupported;
}
inline bool LoopbackEndpoint(bool ipv4,uint32_t hostAddress,uint16_t port,
                              bool fromService=false) {
    return ipv4 && hostAddress==0x7f000001u && port!=0 &&
           (!fromService || port==44334);
}
inline bool RenderMayCopy(bool originalAvailable,int32_t originalStatus,
                           bool captureEnabled,bool generationCurrent,
                           bool unitAndBusMatch) {
    // captureEnabled is control-queue demand: false with zero/expired leases.
    return originalAvailable && originalStatus==0 && captureEnabled &&
           generationCurrent && unitAndBusMatch;
}
} // namespace MSRhythmAdmission
