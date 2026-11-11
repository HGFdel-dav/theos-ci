#include "../Common/RDGeckoABI.h"
__attribute__((noinline)) int32_t RDTestRawVTableCall(void *object, void *argument) {
    return RDGeckoCallUnsignedVTable3(object, argument);
}
__attribute__((noinline)) void *RDTestRawMethod0(void *object, uintptr_t function) {
    return RDGeckoCallUnsignedMethod0(object, function);
}
__attribute__((noinline)) int32_t RDTestRawClick(void *fn, void *a, void *b,
    void *c, uintptr_t d, void *e) {
    return RDGeckoCallOnLinkClickSync(fn, a, b, c, d, e);
}
