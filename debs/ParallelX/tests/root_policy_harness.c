#include "../Common/PXCloneRootPolicy.h"
#include <assert.h>
#include <stdio.h>
static unsigned checks;
#define CHECK(x) do { assert(x); ++checks; } while (0)
int main(void) {
    const char *root = "/rootfs/private/var/mobile/Containers/Shared/AppGroup/.jbroot-CURRENT";
    CHECK(PXCloneRootIsAppGroup(root));
    CHECK(PXCloneRootIsAppGroup("/var/mobile/Containers/Shared/AppGroup/.jbroot-OTHER"));
    CHECK(!PXCloneRootIsAppGroup("/"));
    CHECK(!PXCloneRootIsAppGroup("//"));
    CHECK(!PXCloneRootIsAppGroup("/var/mobile/Library/Preferences"));
    CHECK(!PXCloneRootIsAppGroup("/var/containers/Bundle/Application/.jbroot-ALIAS"));
    CHECK(!PXCloneRootIsAppGroup("/rootfs/var/containers/Bundle/Application/.jbroot-ALIAS"));
    CHECK(!PXCloneRootIsAppGroup("/var/mobile/Containers/Shared/AppGroup/.jbroot-"));
    CHECK(!PXCloneRootIsAppGroup("/var/mobile/Containers/Shared/AppGroup/.jbroot-A/subdir"));
    CHECK(!PXCloneRootIsAppGroup(NULL));
    for (unsigned i = 0; i < 100; i++) {
        CHECK(PXCloneRootRank(true, false, false) == 3);
        CHECK(PXCloneRootRank(false, true, false) == 2);
        CHECK(PXCloneRootRank(false, false, true) == 1);
        CHECK(PXCloneRootRank(false, false, false) == 0);
        CHECK(PXCloneRootOutranks(3, 10, 2, 100000));
        CHECK(!PXCloneRootOutranks(2, 100000, 3, 10));
        CHECK(PXCloneRootOutranks(2, 20, 2, 10));
        CHECK(!PXCloneRootOutranks(2, 10, 2, 20));
        CHECK(!PXCloneRootOutranks(0, 100000, 0, 0));
    }
    CHECK(PXClonePathIsContained(root, "/rootfs/private/var/mobile/Containers/Shared/AppGroup/.jbroot-CURRENT/var/mobile/Library/Preferences"));
    CHECK(!PXClonePathIsContained(root, "/var/mobile/Library/Preferences"));
    CHECK(!PXClonePathIsContained(root, "/rootfs/private/var/mobile/Containers/Shared/AppGroup/.jbroot-CURRENT-OTHER/var/mobile/Library/Preferences"));
    CHECK(!PXClonePathIsContained(root, root));
    CHECK(!PXClonePathIsContained("/", "/var/mobile/Library/Preferences"));
    CHECK(!PXClonePathIsContained(NULL, root));
    printf("root_policy_checks=%u\n", checks);
    return 0;
}
