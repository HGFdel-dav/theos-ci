/* Host-only display parser. Input bytes are NEVER passed to a shell. */
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include "MiniSightApprovalSummaryCore.h"

static const char *const names[] = {
    "screenshot", "tap", "swipe", "record", "launch", "key", "mute", "setting",
    "install", "uninstall", "userspace", "respring", "reboot", "log", "appinfo",
    "dir", "read", "ui", "clipread", "clipwrite", "copy", "move", "delete",
    "edit", "write", "network", "output"
};
static void quoted(const char *text) {
    putchar('"');
    for (const unsigned char *p = (const unsigned char *)text; *p; p++) {
        if (*p == '"' || *p == '\\') { putchar('\\'); putchar(*p); }
        else if (*p < 32) printf("\\u%04x", *p);
        else putchar(*p);
    }
    putchar('"');
}
static void describe(const char *command) {
    MSApprovalSummary s = MSApprovalDescribe(command);
    printf("{\"unknown\":%d,\"is_write\":%d,\"temp_copy_edit\":%d,\"original_write\":%d,\"effects\":[",
           s.unknown, s.is_write, s.temp_copy_edit, s.original_write);
    int first = 1;
    for (int i = 0; i < MSA_EFFECT_COUNT; i++) if (s.effects & (UINT64_C(1) << i)) {
        if (!first) putchar(',');
        quoted(names[i]); first = 0;
    }
    printf("],\"title\":"); quoted(s.title);
    printf(",\"purpose\":"); quoted(s.purpose);
    printf(",\"risk\":"); quoted(s.risk); puts("}");
}
int main(int argc, char **argv) {
    if (argc == 2 && strcmp(argv[1], "--batch") == 0) {
        unsigned char header[4];
        while (fread(header, 1, sizeof(header), stdin) == sizeof(header)) {
            uint32_t length = (uint32_t)header[0] | ((uint32_t)header[1] << 8) |
                ((uint32_t)header[2] << 16) | ((uint32_t)header[3] << 24);
            if (length > 2 * MSA_INPUT_LIMIT) return 2;
            char *input = (char *)calloc((size_t)length + 1, 1);
            if (!input) return 3;
            if (fread(input, 1, length, stdin) != length) { free(input); return 4; }
            describe(input); free(input);
        }
        return ferror(stdin) ? 5 : 0;
    }
    if (argc == 2) { describe(argv[1]); return 0; }
    fputs("usage: summary_cli COMMAND | --batch (little-endian length + bytes)\n", stderr);
    return 1;
}
