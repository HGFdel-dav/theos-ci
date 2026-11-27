#pragma once
#include <stdbool.h>
#include <stdint.h>
#include <math.h>
/* Only passive diagnostics. No time here controls application startup. */
typedef struct { double start; unsigned used, suppressed; bool initialized; } PXInputRate;
static inline bool PXInputRateTake(PXInputRate *r,double now) {
    if (!r || !isfinite(now) || now<0) return false;
    if (!r->initialized || now<r->start || now-r->start>=10) { r->start=now;r->used=0;r->initialized=true; }
    if (r->used>=8) { if(r->suppressed<65535)r->suppressed++;return false; }
    r->used++;return true;
}
static inline bool PXInputScopeCurrent(bool registered,bool exactWindow,bool exactCanvas,
                                      bool exactBundle,uint64_t observedSerial,uint64_t currentSerial) {
    return registered && exactWindow && exactCanvas && exactBundle && observedSerial &&
           observedSerial==currentSerial;
}
static inline bool PXInputSameGeneration(uint64_t scheduled,uint64_t current,bool registered) {
    return registered && scheduled && scheduled==current;
}
static inline double PXInputMilliseconds(double start,double end) {
    return isfinite(start)&&isfinite(end)&&start>=0&&end>=start ? (end-start)*1000 : -1;
}
