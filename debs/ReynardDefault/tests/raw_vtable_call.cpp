#include "../Common/RDGeckoABI.h"

/* Compile the exact production vtable-dispatch helper for arm64e. The
   disassembly gate verifies it emits ordinary BLR rather than PAC BLRAA. */
__attribute__((noinline)) int32_t RDTestRawVTableCall(void *object, void *argument) {
    return RDGeckoCallUnsignedVTable3(object, argument);
}
