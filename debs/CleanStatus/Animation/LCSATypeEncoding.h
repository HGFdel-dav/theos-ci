#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <string.h>

// Compare ABI shapes, ignoring private aggregate names and quoted field/class names.
// Keep nesting, element types, array lengths and block markers: same byte size alone is not enough.
static inline bool LCSAEncodingShape(const char **input, char *out, size_t cap, size_t *used) {
    const char *p = *input;
    while (*p && strchr("rnNoORV", *p)) ++p;
    if (!*p || *used + 2 >= cap) return false;
    char c = *p++;
    out[(*used)++] = c;
    if (c == '{' || c == '(') {
        char end = c == '{' ? '}' : ')';
        while (*p && *p != '=' && *p != end) ++p;
        if (*p++ != '=') return false; // opaque aggregate cannot prove a by-value layout
        while (*p && *p != end) {
            if (*p == '"') { ++p; while (*p && *p != '"') ++p; if (*p++ != '"') return false; continue; }
            if (!LCSAEncodingShape(&p, out, cap, used)) return false;
        }
        if (*p++ != end || *used + 2 >= cap) return false;
        out[(*used)++] = end;
    } else if (c == '[') {
        if (*p < '0' || *p > '9') return false;
        while (*p >= '0' && *p <= '9') { if (*used + 2 >= cap) return false; out[(*used)++] = *p++; }
        if (!LCSAEncodingShape(&p, out, cap, used) || *p++ != ']' || *used + 2 >= cap) return false;
        out[(*used)++] = ']';
    } else if (c == '^') {
        if (!LCSAEncodingShape(&p, out, cap, used)) return false;
    } else if (c == '@') {
        if (*p == '?') { out[(*used)++] = *p++; }
        else if (*p == '"') { ++p; while (*p && *p != '"') ++p; if (*p++ != '"') return false; }
    } else if (c == 'b') {
        while (*p >= '0' && *p <= '9') { if (*used + 2 >= cap) return false; out[(*used)++] = *p++; }
    } else if (!strchr("cislqCISLQfdDBv*#:?", c)) return false;
    out[*used] = '\0'; *input = p; return true;
}
static inline bool LCSAEncodingMatches(const char *actual, const char *expected) {
    if (!actual || !expected) return false;
    // BOOL signed-char and bool are both one-byte values on supported arm64 targets.
    if ((!strcmp(actual, "B") || !strcmp(actual, "c")) &&
        (!strcmp(expected, "B") || !strcmp(expected, "c"))) return true;
    char a[512], b[512]; size_t na = 0, nb = 0;
    return LCSAEncodingShape(&actual, a, sizeof(a), &na) && !*actual &&
           LCSAEncodingShape(&expected, b, sizeof(b), &nb) && !*expected && !strcmp(a, b);
}
