#ifndef RD_REPLY_GATE_H
#define RD_REPLY_GATE_H
/* Only accessed on the main queue; late callbacks must not answer twice. */
typedef struct { int finished; int result; } RDReplyGate;
static inline int RDReplyFinish(RDReplyGate *state, int result) {
    if (state->finished) return 0;
    state->finished = 1;
    state->result = result != 0;
    return 1;
}
#endif
