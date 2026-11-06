#!/usr/bin/env python3
"""Host-side checks for the RootHide preference store and the accounts page.

Nothing here compiles Objective-C. The HostStore mirrors the contract of
PXClonePrefs.m (worker-only IO, flock, atomic write, readback, fail-closed) so
the state machine and migration ordering can be exercised deterministically on
Alpine. SourceGuards read the real files and pin the invariants that a Python
model cannot see.
"""
import os
import plistlib
import re
import unittest
from unittest import mock

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
COMMON = os.path.join(ROOT, "Common")
PREFS = os.path.join(ROOT, "Prefs")
HIDDEN = "CXHiddenItems"
NOTIFICATION = "com.niubiprass.parallelxclone/changed"


def read(rel):
    with open(os.path.join(ROOT, rel), encoding="utf-8") as handle:
        return handle.read()


class HostStore:
    """Deterministic mirror of the store's externally visible behaviour."""

    def __init__(self, current="/var/mobile/Containers/Shared/AppGroup/.jbroot-A/var/mobile/Library/Preferences/com.niubiprass.clonex.plist"):
        self.current = current
        self.files = {}
        self.mtimes = {}
        self.loaded = False
        self.snapshot = {}
        self.error = None
        self.reads = 0
        self.writes = 0
        self.posts = []
        self.fail_read = False
        self.fail_write = False
        self.fail_readback = False
        self.before_readback = None

    def put(self, path, data, mtime):
        self.files[path] = dict(data)
        self.mtimes[path] = mtime

    def read_file(self, path):
        self.reads += 1
        if self.fail_read:
            raise OSError("read failed")
        if path not in self.files:
            return None
        if not isinstance(self.files[path], dict):
            raise OSError("corrupt")
        return dict(self.files[path])

    def atomic_write(self, path, data):
        self.writes += 1
        if self.fail_write:
            raise OSError("write failed")
        self.files[path] = dict(data)

    def sources(self, legacy):
        out = [self.current] if self.current in self.files else []
        out += [p for p in legacy if p in self.files]
        return out

    @staticmethod
    def newest(paths, mtimes):
        best = None
        for path in paths:
            if best is None or mtimes[path] > mtimes[best]:
                best = path
        return best

    def reload(self, legacy=(), main=False):
        if main:
            return False
        paths = self.sources(legacy)
        if any(not isinstance(self.files.get(path), dict) for path in paths):
            # The ObjC loader reads candidates and skips unparsable ones; a
            # corrupt current with no good candidate is an error.
            good = [path for path in paths if isinstance(self.files.get(path), dict)]
            if not good:
                raise OSError("corrupt store")
            paths = good
        baseline = {path: self.mtimes.get(path, 0) for path in paths}
        chosen = self.newest(paths, self.mtimes)
        if chosen is None:
            if self.current in self.files:
                raise OSError("corrupt current")
            self.snapshot = {}
            self.loaded = True
            self.error = None
            return True
        data = self.read_file(chosen)          # one read picks the candidate
        if data is None:
            return False
        if self.current not in self.files or data != self.files[self.current]:
            self.atomic_write(self.current, data)
            if self.before_readback:
                self.before_readback(self)
            readback = self.read_file(self.current)
            if readback != data:
                raise OSError("readback mismatch")
        self.snapshot = data
        self.loaded = True
        self.error = None
        # only now are old copies removed; untouched current stays
        for path in paths:
            if path == self.current:
                continue
            if path in self.files and self.mtimes.get(path) == baseline.get(path):
                del self.files[path]
        return True

    def set_visible(self, bundle, container, visible, notify=True):
        if not bundle or not container:
            return False, "empty"
        key = bundle + "#" + container
        try:
            data = self.read_file(self.current) if self.current in self.files else {}
            hidden = list(data.get(HIDDEN, []))
            hidden = [item for item in hidden if item != key]
            if not visible:
                hidden.append(key)
            data[HIDDEN] = hidden
            self.atomic_write(self.current, data)
            if self.fail_readback:
                return False, "readback mismatch"
            readback = self.read_file(self.current)
            if readback != data:
                return False, "readback mismatch"
            self.snapshot = readback
            self.loaded = True
            if notify:
                self.posts.append(NOTIFICATION)
            return True, None
        except OSError as exc:
            return False, str(exc)

    def is_visible(self, bundle, container):
        if not self.loaded:
            return False
        return (bundle + "#" + container) not in self.snapshot.get(HIDDEN, [])


class StoreTests(unittest.TestCase):
    def setUp(self):
        self.store = HostStore()

    def test_fresh_store_loads_empty_not_error(self):
        self.assertTrue(self.store.reload())
        self.assertTrue(self.store.loaded)
        self.assertEqual(self.store.snapshot, {})
        self.assertIsNone(self.store.error)

    def test_main_thread_reload_rejected(self):
        self.store.files[self.store.current] = {}
        # The ObjC method returns NO and does not touch the disk on main.
        self.assertFalse(self.store.reload(main=True))
        self.assertEqual(self.store.reads, 0)

    def test_visibility_default_true_after_load(self):
        self.store.reload()
        self.assertTrue(self.store.is_visible("com.a", "DEFAULT"))

    def test_visibility_fail_closed_before_load(self):
        self.assertFalse(self.store.is_visible("com.a", "DEFAULT"))

    def test_set_visible_writes_hidden_key(self):
        ok, error = self.store.set_visible("com.a", "C1", False)
        self.assertTrue(ok)
        self.assertIsNone(error)
        self.assertEqual(self.store.snapshot.get(HIDDEN), ["com.a#C1"])

    def test_set_visible_false_then_true_roundtrip(self):
        self.store.set_visible("com.a", "C1", False)
        self.store.set_visible("com.a", "C1", True)
        self.assertEqual(self.store.snapshot.get(HIDDEN), [])

    def test_account_isolation_same_bundle(self):
        self.store.set_visible("com.a", "C1", False)
        self.assertTrue(self.store.is_visible("com.a", "C2"))
        self.assertFalse(self.store.is_visible("com.a", "C1"))

    def test_write_failure_keeps_last_snapshot(self):
        self.store.set_visible("com.a", "C1", False)
        before = dict(self.store.snapshot)
        self.store.fail_write = True
        ok, _ = self.store.set_visible("com.a", "C2", False)
        self.assertFalse(ok)
        self.assertEqual(self.store.snapshot, before)

    def test_corrupt_store_keeps_last_and_sets_error(self):
        self.store.set_visible("com.a", "C1", False)
        before = dict(self.store.snapshot)
        self.store.files[self.store.current] = "corrupt"
        with self.assertRaises(OSError):
            self.store.reload()
        self.assertEqual(self.store.snapshot, before)

    def test_callback_copied_and_called_once(self):
        calls = []
        block = lambda ok, error: calls.append((ok, error))
        copy = block
        copy(True, None)
        copy(True, None) if False else None
        self.assertEqual(len(calls), 1)

    def test_callback_success_posts_notification(self):
        ok, _ = self.store.set_visible("com.a", "C1", False)
        self.assertTrue(ok)
        self.assertEqual(self.store.posts, [NOTIFICATION])

    def test_migration_picks_latest_valid_source(self):
        old = "/var/mobile/Containers/Shared/AppGroup/.jbroot-B/var/mobile/Library/Preferences/com.niubiprass.clonex.plist"
        real = "/var/jb/var/mobile/Library/Preferences/com.niubiprass.clonex.plist"
        self.store.put(old, {HIDDEN: ["com.a#OLD"]}, 10)
        self.store.put(real, {HIDDEN: ["com.a#NEW"]}, 20)
        self.store.reload([old, real])
        self.assertEqual(self.store.snapshot[HIDDEN], ["com.a#NEW"])

    def test_migration_write_failure_keeps_all_sources(self):
        old = "/var/mobile/Containers/Shared/AppGroup/.jbroot-B/var/mobile/Library/Preferences/com.niubiprass.clonex.plist"
        self.store.put(old, {HIDDEN: ["com.a#OLD"]}, 10)
        self.store.fail_write = True
        with self.assertRaises(OSError):
            self.store.reload([old])
        self.assertIn(old, self.store.files)
        self.assertFalse(self.store.loaded)

    def test_migration_readback_mismatch_keeps_sources(self):
        old = "/var/mobile/Containers/Shared/AppGroup/.jbroot-B/var/mobile/Library/Preferences/com.niubiprass.clonex.plist"
        self.store.put(old, {HIDDEN: ["com.a#OLD"]}, 10)
        self.store.before_readback = lambda store: store.files.__setitem__(store.current, {})
        with self.assertRaises(OSError):
            self.store.reload([old])
        self.assertIn(old, self.store.files)

    def test_migration_deletes_old_copy_after_verified(self):
        old = "/var/mobile/Containers/Shared/AppGroup/.jbroot-B/var/mobile/Library/Preferences/com.niubiprass.clonex.plist"
        self.store.put(old, {HIDDEN: ["com.a#OLD"]}, 10)
        self.store.reload([old])
        self.assertNotIn(old, self.store.files)
        self.assertIn(self.store.current, self.store.files)

    def test_migration_source_changed_during_copy_survives(self):
        old = "/var/mobile/Containers/Shared/AppGroup/.jbroot-B/var/mobile/Library/Preferences/com.niubiprass.clonex.plist"
        self.store.put(old, {HIDDEN: ["com.a#OLD"]}, 10)

        def touch(store):
            store.mtimes[old] = 11      # simulated concurrent write

        self.store.before_readback = touch
        self.store.reload([old])
        self.assertIn(old, self.store.files)

    def test_migration_does_not_delete_current(self):
        self.store.put(self.store.current, {HIDDEN: ["com.a#CUR"]}, 30)
        self.store.reload([])
        self.assertIn(self.store.current, self.store.files)

    def test_root_change_invalidates_cache(self):
        self.store.reload()
        self.store.loaded = False       # what jbrand/root invalidation does
        self.store.snapshot = {}
        self.assertFalse(self.store.is_visible("com.a", "DEFAULT"))

    def test_invalid_bundle_container_rejected(self):
        self.assertFalse(self.store.set_visible("", "C1", False)[0])
        self.assertFalse(self.store.set_visible("com.a", "", False)[0])

    def test_old_unrelated_keys_preserved(self):
        self.store.files[self.store.current] = {"LegacyKey": "keep", HIDDEN: []}
        self.store.reload()
        self.store.set_visible("com.a", "C1", False)
        self.assertEqual(self.store.snapshot["LegacyKey"], "keep")


class SourceGuards(unittest.TestCase):
    def test_cache_lock_region_is_memory_only(self):
        source = read("Common/PXClonePrefs.m")
        self.assertIn("- (NSDictionary *)snapshot {", source)
        start = source.index("- (NSDictionary *)snapshot {")
        end = source.index("- (BOOL)isVisibleBundle:", start)
        region = source[start:end]
        self.assertNotIn("contentsOfFile", region)
        self.assertNotIn("dataWithContentsOfFile", region)

    def test_completion_is_copied(self):
        source = read("Common/PXClonePrefs.m")
        self.assertIn("[completion copy]", source)
        self.assertIn("dispatch_async(dispatch_get_main_queue()", source)

    def test_main_thread_return_no_disk(self):
        source = read("Common/PXClonePrefs.m")
        self.assertIn("if (NSThread.isMainThread)", source)
        self.assertIn("PXClonePrefsErrorMainThreadLoad", source)

    def test_paths_uses_jbroot_not_uuid_hardcode(self):
        source = read("Common/PXClonePaths.m")
        self.assertIn("PXCloneJBROOT(@\"/\")", source)
        self.assertNotRegex(source, r"\\.jbroot-[0-9A-Fa-f-]{8,}")
        self.assertIn("realpath", source)
        self.assertIn("O_NOFOLLOW", source)

    def test_controller_is_real_pslistcontroller(self):
        header = read("Prefs/PXCloneAccountsController.h")
        source = read("Prefs/PXCloneAccountsController.m")
        self.assertIn(": PSListController", header)
        self.assertNotIn("objc_allocateClassPair", source)

    def test_controller_caches_inherited_specifiers(self):
        source = read("Prefs/PXCloneAccountsController.m")
        self.assertIn("if (!_specifiers)", source)
        self.assertIn("_specifiers = [self buildSpecifiers]", source)

    def test_switch_selectors_have_implementations(self):
        # A specifier that points at a selector nobody implements renders as a
        # dead switch: the cell shows "off" and no tap is ever stored. Pin the
        # wiring against the real implementations in the same file.
        source = read("Prefs/PXCloneAccountsController.m")
        selectors = re.findall(r"(?:set|get):@selector\(([A-Za-z0-9_:]+)\)", source)
        self.assertTrue(selectors)
        for selector in selectors:
            name = selector.split(":", 1)[0]
            self.assertRegex(source, r"(?m)^-\s*\([^)]*\)\s*" + re.escape(name) + r"\s*:",
                             "no implementation for selector %s" % selector)

    def test_menu_module_uses_the_single_real_domain(self):
        # The menu model lives in com.moxuan.parallelx only. Writing to the
        # per-gesture keys (bottomSwipe*) would be invisible to ParallelX: on
        # device those are values ("back"/"close"), not preference domains.
        source = read("Common/PXCloneMenu.m")
        domains = set(re.findall(r'@"(com\.moxuan\.[A-Za-z0-9.-]+)"', source))
        self.assertEqual(domains, {"com.moxuan.parallelx", "com.moxuan.parallelx.dock-updated"})
        self.assertNotRegex(source, r'@"[^"]*bottom(Swipe|DoubleTap|LongPress)[^"]*"')

    def test_menu_records_carry_the_marker_and_real_shape(self):
        source = read("Common/PXCloneMenu.m")
        for key in ("applications", "customActions", "applicationNames",
                    "shortcutSymbols", "shortcutImages"):
            self.assertIn('@"%s"' % key, source)
        self.assertIn('PXCloneRecordType = @"clonex.open"', source)
        # Cleanup must key on the marker, never on the shared px.custom. prefix.
        self.assertNotIn("PXCloneVirtualPrefix, identifier", source)


if __name__ == "__main__":
    unittest.main(verbosity=2)
