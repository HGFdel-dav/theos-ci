#pragma once
#include <stdbool.h>
#include <string.h>

// Shared, host-executable part of RootHide discovery. No UUID or real-/var
// fallback is accepted. Bundle/Application aliases cannot pass this predicate.
static inline bool PXCloneRootIsAppGroup(const char *canonical) {
    if (!canonical || canonical[0] != '/') return false;
    const char *marker = "/Containers/Shared/AppGroup/.jbroot-";
    const char *match = strstr(canonical, marker);
    while (match) {
        const char *tail = match + strlen(marker);
        if (*tail && !strchr(tail, '/')) return true;
        match = strstr(match + 1, marker);
    }
    return false;
}

// PXCloneRootIsAppGroup() above only accepts the root itself: the candidate
// must END at ".jbroot-<uuid>". Judging a DIRECTORY BELOW that root (for
// example "<root>/var/mobile/Library/Preferences") with it is always false,
// which used to make storage and trace initialization fail on every respring.
// This variant accepts the root and every descendant of it, and nothing less.
static inline bool PXClonePathIsUnderAppGroup(const char *canonical) {
    if (!canonical || canonical[0] != '/') return false;
    const char *marker = "/Containers/Shared/AppGroup/.jbroot-";
    const char *match = strstr(canonical, marker);
    while (match) {
        const char *tail = match + strlen(marker);
        const char *scan = tail;
        while (*scan && *scan != '/') ++scan;
        if (scan > tail) return true;
        match = strstr(match + 1, marker);
    }
    return false;
}

static inline int PXCloneRootRank(bool hasModule, bool hasSubstrate, bool hasLibraries) {
    return hasModule ? 3 : (hasSubstrate ? 2 : (hasLibraries ? 1 : 0));
}

static inline bool PXCloneRootOutranks(int candidateRank, double candidateMtime,
                                       int chosenRank, double chosenMtime) {
    if (candidateRank <= 0) return false;
    return candidateRank > chosenRank ||
           (candidateRank == chosenRank && candidateMtime > chosenMtime);
}

static inline bool PXClonePathIsContained(const char *root, const char *path) {
    if (!root || !path || root[0] != '/' || !root[1]) return false;
    size_t count = strlen(root);
    size_t length = strlen(path);
    return length > count && strncmp(root, path, count) == 0 && path[count] == '/';
}
