#!/usr/bin/env python3
"""Specification mirror for the clone-account visibility store.

On device the store is a preferences domain written through CFPreferences, so
cfprefsd places the file in the active root's Library/Preferences and the store
never assembles or canonicalises a path. The 0.6 build did assemble one and had
every write refused ("prefs escaped active root"), which also left the dock menu
with nothing to inject.

The model below mirrors the C contract: read the domain once, default to
visible, fail closed before the first load, keep the last good snapshot when a
write or readback fails, and import an older file-based copy exactly once.

Static/behavioural mirror only: passing says the documented contract holds, not
that the switch works on a phone.
"""
import os
import re
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
COMMON = os.path.join(ROOT, "Common")
PREFS = os.path.join(ROOT, "Prefs")

HIDDEN = "CXHiddenItems"
DOMAIN = "com.niubiprass.clonex"
NOTIFICATION = "com.niubiprass.parallelxclone/changed"
STORE_BASENAME = DOMAIN + ".plist"
TAG = "clonex.open"
CURRENT = ("/var/containers/Bundle/Application/.jbroot-CUR/var/mobile/Library/"
           "Preferences/" + STORE_BASENAME)
LEGACY_B = ("/var/mobile/Containers/Shared/AppGroup/.jbroot-B/var/mobile/Library/"
            "Preferences/" + STORE_BASENAME)
LEGACY_C = "/var/jb/var/mobile/Library/Preferences/" + STORE_BASENAME


def read(rel):
    with open(rel, "r", encoding="utf-8") as handle:
        return handle.read()


class Store(object):
    """Mirror of PXClonePrefs: one preferences domain, no paths of our own."""

    def __init__(self, domain=None, files=None, mtimes=None, fail_write=False,
                 fail_readback=False, before_readback=None):
        self.domain = domain            # what cfprefsd holds (None = never written)
        self.files = dict(files or {})  # older file-based copies, by path
        self.mtimes = dict(mtimes or {})
        self.current = CURRENT
        self.fail_write = fail_write
        self.fail_readback = fail_readback
        self.before_readback = before_readback
        self.snapshot = {}
        self.loaded = False
        self.error = None
        self.posts = []
        self.reads = 0
        self.writes = 0

    # -- primitives -------------------------------------------------------
    def read_domain(self):
        self.reads += 1
        if isinstance(self.domain, dict):
            return dict(self.domain)
        return self.domain            # None, or a corrupt non-dict

    def write_domain(self, data):
        self.writes += 1
        if self.fail_write:
            raise OSError("domain write failed")
        self.domain = dict(data)
        if self.fail_readback:
            raise OSError("domain readback mismatch")

    def normalize(self, data):
        hidden = data.get(HIDDEN, [])
        if not isinstance(hidden, list):
            raise OSError("hidden list is not an array")
        for item in hidden:
            if not isinstance(item, str):
                raise OSError("hidden list holds a non-string")
        out = dict(data)
        out[HIDDEN] = sorted(set(hidden))
        return out

    def sources(self, legacy):
        seen, out = set(), []
        for path in [self.current] + list(legacy):
            if path not in seen:
                seen.add(path)
                out.append(path)
        return out

    # -- public API -------------------------------------------------------
    def reload(self, legacy=(), main=False):
        if main:                      # the store refuses to touch disk on main
            raise OSError("main-thread load")
        data = self.read_domain()
        if data is not None:
            if not isinstance(data, dict):
                self.error = "corrupt store"
                raise OSError("corrupt store")
            snapshot = self.normalize(data)
            self.snapshot, self.loaded, self.error = snapshot, True, None
            return True
        return self._import(legacy)

    def _import(self, legacy):
        readable = [p for p in self.sources(legacy)
                    if isinstance(self.files.get(p), dict)]
        valid = []
        for path in readable:
            try:
                self.normalize(self.files[path])
            except OSError:
                continue
            valid.append(path)
        if not valid:                 # fresh install: defaults, nothing written
            self.snapshot, self.loaded, self.error = {}, True, None
            return True
        chosen = max(valid, key=lambda p: self.mtimes.get(p, 0))
        baseline = {p: self.mtimes.get(p) for p in valid}
        data = self.normalize(self.files[chosen])
        try:
            self.write_domain(data)
            if self.before_readback:
                self.before_readback(self)
            readback = self.domain
            if readback != data:
                raise OSError("migration readback mismatch")
        except OSError as exc:
            self.error = str(exc)
            raise OSError(str(exc))
        for path in valid:            # verified: drop the stale copies
            if path == self.current:
                continue
            if path in self.files and self.mtimes.get(path) == baseline.get(path):
                del self.files[path]
        self.snapshot, self.loaded, self.error = dict(readback), True, None
        return True

    def is_visible(self, bundle, container):
        if not self.loaded:
            return False              # fail closed
        return bundle + "#" + container not in self.snapshot.get(HIDDEN, [])

    def set_visible(self, bundle, container, visible, notify=True):
        if not bundle or not container:
            return False, "empty identifier"
        key = bundle + "#" + container
        current = self.read_domain()
        data = dict(current) if isinstance(current, dict) else {}
        hidden = [i for i in data.get(HIDDEN, []) if i != key]
        if not visible:
            hidden.append(key)
        data[HIDDEN] = sorted(set(hidden))
        try:
            self.write_domain(data)
            readback = self.domain
            if readback != data:
                raise OSError("write readback mismatch")
        except OSError as exc:
            self.error = str(exc)     # last snapshot stays published
            return False, str(exc)
        self.snapshot, self.loaded, self.error = dict(readback), True, None
        if notify:
            self.posts.append(NOTIFICATION)
        return True, None


class StoreTests(unittest.TestCase):
    def test_fresh_store_is_empty_and_clean(self):
        store = Store()
        self.assertTrue(store.reload())
        self.assertEqual(store.snapshot, {})
        self.assertIsNone(store.error)
        self.assertIsNone(store.domain, "a fresh install must not write the domain")
        self.assertTrue(store.is_visible("m.qidian.QDReaderAppStore", "default"))

    def test_main_thread_reload_is_refused(self):
        store = Store()
        with self.assertRaises(OSError):
            store.reload(main=True)
        self.assertEqual(store.reads, 0, "main thread must not read the domain")

    def test_visibility_defaults_true_after_load(self):
        store = Store(domain={})
        store.reload()
        self.assertTrue(store.is_visible("com.tencent.xin", "clone-a"))

    def test_fail_closed_before_load(self):
        store = Store(domain={HIDDEN: ["com.tencent.xin#clone-a"]})
        self.assertFalse(store.is_visible("com.tencent.xin", "clone-a"))

    def test_set_hidden_and_reset(self):
        store = Store(domain={HIDDEN: []})
        store.reload()
        ok, error = store.set_visible("com.tencent.xin", "clone-a", False)
        self.assertTrue(ok, error)
        self.assertFalse(store.is_visible("com.tencent.xin", "clone-a"))
        self.assertEqual(store.domain[HIDDEN], ["com.tencent.xin#clone-a"])
        ok, error = store.set_visible("com.tencent.xin", "clone-a", True)
        self.assertTrue(ok, error)
        self.assertTrue(store.is_visible("com.tencent.xin", "clone-a"))
        self.assertEqual(store.domain[HIDDEN], [])
        self.assertEqual(len(store.posts), 2)

    def test_accounts_are_isolated(self):
        store = Store(domain={HIDDEN: []})
        store.reload()
        store.set_visible("com.tencent.xin", "clone-a", False)
        self.assertFalse(store.is_visible("com.tencent.xin", "clone-a"))
        self.assertTrue(store.is_visible("com.tencent.xin", "clone-b"))
        self.assertTrue(store.is_visible("m.qidian.QDReaderAppStore", "clone-a"))

    def test_write_failure_keeps_last_snapshot(self):
        store = Store(domain={HIDDEN: []})
        store.reload()
        store.fail_write = True
        ok, error = store.set_visible("com.tencent.xin", "clone-a", False)
        self.assertFalse(ok)
        self.assertTrue(error)
        self.assertTrue(store.is_visible("com.tencent.xin", "clone-a"))
        self.assertEqual(store.posts, [], "a failed write must not notify")

    def test_corrupt_store_keeps_last_snapshot(self):
        store = Store(domain={HIDDEN: ["com.tencent.xin#clone-a"]})
        store.reload()
        before = dict(store.snapshot)
        store.domain = ["not", "a", "dictionary"]
        with self.assertRaises(OSError):
            store.reload()
        self.assertEqual(store.snapshot, before)
        self.assertIsNotNone(store.error)

    def test_successful_write_posts_notification(self):
        store = Store(domain={HIDDEN: []})
        store.reload()
        store.posts = []
        store.set_visible("com.tencent.xin", "clone-a", False)
        self.assertEqual(store.posts, [NOTIFICATION])

    def test_unrelated_keys_are_preserved(self):
        store = Store(domain={"CXStoreVersion": 2, HIDDEN: []})
        store.reload()
        store.set_visible("com.tencent.xin", "clone-a", False)
        self.assertEqual(store.domain["CXStoreVersion"], 2)

    def test_invalid_identifiers_are_rejected(self):
        store = Store(domain={HIDDEN: []})
        store.reload()
        self.assertFalse(store.set_visible("", "clone-a", False)[0])
        self.assertFalse(store.set_visible("com.tencent.xin", "", False)[0])

    def test_reload_picks_up_an_external_change(self):
        store = Store(domain={HIDDEN: []})
        store.reload()
        store.set_visible("com.tencent.xin", "clone-a", False)
        store.domain = {HIDDEN: ["com.tencent.xin#clone-a",
                                 "m.qidian.QDReaderAppStore#clone-a"]}
        store.reload()
        self.assertFalse(store.is_visible("m.qidian.QDReaderAppStore", "clone-a"))


class MigrationTests(unittest.TestCase):
    """One-time import of an older file-based copy into the domain."""

    def legacy(self, **kwargs):
        files = {LEGACY_B: {HIDDEN: ["com.tencent.xin#clone-a"]}}
        files.update(kwargs.pop("files", {}))
        mtimes = {LEGACY_B: 1000}
        mtimes.update(kwargs.pop("mtimes", {}))
        return Store(files=files, mtimes=mtimes, **kwargs)

    def test_picks_the_newest_valid_source(self):
        store = self.legacy(files={LEGACY_C: {HIDDEN: [legacy_key_small()]}},
                            mtimes={LEGACY_C: 5000})
        store.reload(legacy=[LEGACY_B, LEGACY_C])
        self.assertEqual(store.domain[HIDDEN], [legacy_key_small()])
        bundle, container = legacy_key_small().split("#")
        self.assertFalse(store.is_visible(bundle, container))
        self.assertTrue(store.is_visible("com.tencent.xin", "clone-a"))

    def test_corrupt_source_is_skipped(self):
        store = self.legacy(files={LEGACY_C: ["not", "a", "dictionary"]},
                            mtimes={LEGACY_C: 5000})
        store.reload(legacy=[LEGACY_B, LEGACY_C])
        self.assertEqual(store.domain[HIDDEN], ["com.tencent.xin#clone-a"])
        self.assertIn(LEGACY_C, store.files, "an unreadable source is left alone")

    def test_write_failure_keeps_every_source(self):
        store = self.legacy(fail_write=True)
        with self.assertRaises(OSError):
            store.reload(legacy=[LEGACY_B])
        self.assertIn(LEGACY_B, store.files)
        self.assertIsNone(store.domain)

    def test_readback_mismatch_keeps_every_source(self):
        store = self.legacy(before_readback=lambda s: setattr(s, "domain", {}))
        with self.assertRaises(OSError):
            store.reload(legacy=[LEGACY_B])
        self.assertIn(LEGACY_B, store.files)

    def test_verified_source_is_removed(self):
        store = self.legacy()
        store.reload(legacy=[LEGACY_B])
        self.assertNotIn(LEGACY_B, store.files)
        self.assertEqual(store.domain[HIDDEN], ["com.tencent.xin#clone-a"])

    def test_source_changed_during_copy_survives(self):
        def touch(store):
            store.mtimes[LEGACY_B] = 4242

        store = self.legacy(before_readback=touch)
        store.reload(legacy=[LEGACY_B])
        self.assertIn(LEGACY_B, store.files, "a changed copy is never deleted")

    def test_current_file_is_never_deleted(self):
        store = self.legacy(files={CURRENT: {HIDDEN: ["com.tencent.xin#clone-a"]}},
                            mtimes={CURRENT: 9000})
        store.reload(legacy=[LEGACY_B])
        self.assertIn(CURRENT, store.files)
        self.assertEqual(store.domain[HIDDEN], ["com.tencent.xin#clone-a"])


def legacy_key_small():
    return "m.qidian.QDReaderAppStore#clone-a"
class SourceGuards(unittest.TestCase):
    """Pins the mechanism, so a future edit cannot bring the path back."""

    def test_store_uses_the_preferences_domain(self):
        source = read("Common/PXClonePrefs.m")
        self.assertIn("PXClonePrefsStoreDomain", source)
        self.assertIn("CFPreferencesCopyAppValue", source)
        self.assertIn("CFPreferencesSetAppValue", source)
        self.assertIn("CFPreferencesAppSynchronize", source)
        for banned in ("PXCloneEnsureStorage", "flock(", "O_NOFOLLOW",
                       "escaped active root", "writeToFile"):
            self.assertNotIn(banned, source, banned)

    def test_store_domain_matches_the_prefs_file_name(self):
        source = read("Common/PXClonePrefs.m")
        match = re.search(r'PXClonePrefsStoreDomain = @"([^"]+)"', source)
        self.assertIsNotNone(match)
        self.assertEqual(match.group(1), "com.niubiprass.clonex")
        self.assertIn("/Preferences/%s.plist" % match.group(1),
                      read("Common/PXClonePaths.m"))

    def test_write_is_read_back_before_publishing(self):
        source = read("Common/PXClonePrefs.m")
        start = source.index("- (BOOL)_mutateVisibility")
        region = source[start:]
        self.assertIn("PXReadDomainStore", region)
        self.assertIn("PXClonePrefsErrorReadbackMismatch", region)

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

    def test_main_thread_reload_stays_memory_only(self):
        source = read("Common/PXClonePrefs.m")
        self.assertIn("if (NSThread.isMainThread)", source)
        self.assertIn("PXClonePrefsErrorMainThreadLoad", source)

    def test_paths_uses_jbroot_not_uuid_hardcode(self):
        source = read("Common/PXClonePaths.m")
        self.assertIn("PXCloneJBROOT(@\"/\")", source)
        self.assertNotRegex(source, r"\.jbroot-[0-9A-Fa-f-]{8,}")
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
        self.assertEqual(domains, {"com.moxuan.parallelx",
                                   "com.moxuan.parallelx.dock-updated"})
        self.assertNotRegex(source, r'@"[^"]*bottom(Swipe|DoubleTap|LongPress)[^"]*"')

    def test_menu_records_carry_the_marker_and_real_shape(self):
        source = read("Common/PXCloneMenu.m")
        for key in ("applications", "customActions", "applicationNames",
                    "shortcutSymbols", "shortcutImages"):
            self.assertIn('@"%s"' % key, source)
        self.assertIn('PXCloneRecordType = @"clonex.open"', source)
        self.assertNotIn("PXCloneVirtualPrefix, identifier", source)


def read(relative_path):
    """Read a repo file as text, relative to the debs/ParallelX directory."""
    here = os.path.dirname(os.path.abspath(__file__))
    with open(os.path.join(here, os.pardir, relative_path), encoding="utf-8") as handle:
        return handle.read()


if __name__ == "__main__":
    unittest.main(verbosity=2)
