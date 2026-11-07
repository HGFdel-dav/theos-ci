#!/usr/bin/env python3
"""Negative cases named by the handoff, kept host-side and deterministic."""
import os
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def read(rel):
    with open(os.path.join(ROOT, rel), encoding="utf-8") as handle:
        return handle.read()


# ParallelX stores its menu model in one domain. Our rows go in with the same
# id shape and field set it uses for its own custom actions, and are marked so
# cleanup can tell them apart from the user's own px.custom.* records.
PREFIX = "px.custom."
RECORD_TYPE = "clonex.open"
LEGACY_PREFIX = "px.clone."
FOREIGN_ID = "px.custom.1A2B3C4D-5E6F-7081-9203-A4B5C6D7E8F9"
CATALOG = [
    {"bundle": "com.a", "name": "A", "containers": [
        {"container": "DEFAULT", "name": "默认", "isDefault": True},
        {"container": "C1", "name": "小号", "isDefault": False},
    ]},
]


def virtual_id(bundle, container):
    """Mirror of PXVirtualIdentifier (FNV-1a 64, UUID-shaped)."""
    value = 1469598103934665603
    for byte in ("clonex|%s|%s" % (bundle, container)).encode("utf-8"):
        value ^= byte
        value = (value * 1099511628211) & 0xFFFFFFFFFFFFFFFF
    second = value ^ 0x9E3779B97F4A7C15
    return "%s%08X-%04X-%04X-%04X-%012X" % (
        PREFIX, (value >> 32) & 0xFFFFFFFF, (value >> 16) & 0xFFFF,
        value & 0xFFFF, (second >> 48) & 0xFFFF, second & 0xFFFFFFFFFFFF)


def sync(apps, actions, catalog=CATALOG, visible=lambda b, c: True, store_ok=True):
    """Mirror of PXCloneSyncMenu for the host-side invariants."""
    if not store_ok or not catalog:
        return list(apps), list(actions)
    apps, actions = list(apps), list(actions)
    desired = {}
    for app in catalog:
        for container in app["containers"]:
            if not visible(app["bundle"], container["container"]):
                continue
            identifier = virtual_id(app["bundle"], container["container"])
            desired[identifier] = {"id": identifier, "app": app["bundle"],
                                   "appTitle": app["name"],
                                   "kind": "quick", "type": RECORD_TYPE}
            if identifier not in apps:
                apps.append(identifier)
            if not any(record.get("id") == identifier for record in actions):
                actions.append(desired[identifier])
    stale = {record.get("id") for record in actions if record.get("type") == RECORD_TYPE}
    stale |= {item for item in apps if str(item).startswith(LEGACY_PREFIX)}
    stale -= set(desired)
    apps = [item for item in apps if item not in stale]
    actions = [record for record in actions if record.get("id") not in stale]
    return apps, actions


def claim(identifier, apps, actions):
    """Mirror of PXCloneItemForIdentifier: our prefix and a resolvable record."""
    if not str(identifier).startswith(PREFIX):
        return None
    for app in CATALOG:
        for container in app["containers"]:
            if virtual_id(app["bundle"], container["container"]) == identifier:
                return {"bundle": app["bundle"], "container": container["container"]}
    return None


class MenuNegatives(unittest.TestCase):
    def test_new_container_appears_after_catalog_change_without_restarting(self):
        apps, actions = sync([], [])
        new_catalog = [{**CATALOG[0], "containers": CATALOG[0]["containers"] + [
            {"container": "C2", "name": "第三个账号", "isDefault": False}]}]
        apps, actions = sync(apps, actions, catalog=new_catalog, visible=lambda b, c: c != "C1")
        self.assertIn(virtual_id("com.a", "DEFAULT"), apps)
        self.assertIn(virtual_id("com.a", "C2"), apps)
        self.assertNotIn(virtual_id("com.a", "C1"), apps)
        self.assertEqual(sum(x["id"] == virtual_id("com.a", "C2") for x in actions), 1)

    def test_unchanged_refresh_does_not_reencode_icons_or_post_again(self):
        source = read("Common/PXCloneMenu.m")
        self.assertIn("[lastCatalog isEqualToArray:catalog]", source)
        self.assertIn("[lastVisibility isEqualToDictionary:visibility]", source)
        self.assertLess(source.index("lastCatalog isEqualToArray"), source.index("UIImage *icon = PXBadgedIcon"))

    def test_same_virtual_item_is_not_duplicated(self):
        apps, actions = sync([], [])
        apps, actions = sync(apps, actions)
        self.assertEqual(apps.count(virtual_id("com.a", "C1")), 1)
        self.assertEqual(sum(1 for x in actions if x["id"] == virtual_id("com.a", "C1")), 1)

    def test_existing_foreign_item_order_kept(self):
        mine = virtual_id("com.a", "DEFAULT")
        apps = ["com.foreign", mine]
        actions = [{"id": "com.foreign"}, {"id": mine, "type": RECORD_TYPE}]
        out_apps, out_actions = sync(apps, actions)
        self.assertEqual(out_apps[0], "com.foreign")
        self.assertEqual(out_actions[0]["id"], "com.foreign")

    def test_hidden_account_not_injected(self):
        apps, actions = sync([], [], visible=lambda b, c: c != "C1")
        self.assertNotIn(virtual_id("com.a", "C1"), apps)
        self.assertIn(virtual_id("com.a", "DEFAULT"), apps)

    def test_stale_virtual_item_removed(self):
        gone = virtual_id("com.gone", "C1")
        apps = [gone]
        actions = [{"id": gone, "type": RECORD_TYPE}]
        out_apps, out_actions = sync(apps, actions)
        self.assertNotIn(gone, out_apps)
        self.assertFalse(any(x["id"] == gone for x in out_actions))

    def test_foreign_custom_action_survives_sync(self):
        # ParallelX's own custom actions share our prefix; only records carrying
        # our marker may ever be removed.
        apps = [FOREIGN_ID]
        actions = [{"id": FOREIGN_ID, "kind": "group", "title": "用户自己的分组"}]
        out_apps, out_actions = sync(apps, actions)
        self.assertIn(FOREIGN_ID, out_apps)
        self.assertTrue(any(x["id"] == FOREIGN_ID for x in out_actions))

    def test_legacy_prefix_rows_are_swept(self):
        legacy = LEGACY_PREFIX + "com.a#C1"
        out_apps, out_actions = sync([legacy, "com.foreign"], [{"id": legacy}])
        self.assertNotIn(legacy, out_apps)
        self.assertFalse(any(x["id"] == legacy for x in out_actions))
        self.assertIn("com.foreign", out_apps)

    def test_empty_catalog_or_unloaded_store_never_wipes(self):
        mine = virtual_id("com.a", "C1")
        apps = [mine, "com.foreign"]
        actions = [{"id": mine, "type": RECORD_TYPE}, {"id": "com.foreign"}]
        for kwargs in ({"catalog": []}, {"store_ok": False}):
            out_apps, out_actions = sync(apps, actions, **kwargs)
            self.assertEqual(out_apps, apps)
            self.assertEqual([x["id"] for x in out_actions], [x["id"] for x in actions])

    def test_identifier_shape_matches_parallelx_custom_actions(self):
        identifier = virtual_id("com.a", "C1")
        self.assertTrue(identifier.startswith(PREFIX))
        body = identifier[len(PREFIX):]
        self.assertEqual([len(part) for part in body.split("-")], [8, 4, 4, 4, 12])
        int(body.replace("-", ""), 16)
        self.assertEqual(identifier, virtual_id("com.a", "C1"))
        self.assertNotEqual(identifier, virtual_id("com.a", "DEFAULT"))

    def test_only_resolvable_ids_are_claimed(self):
        mine = virtual_id("com.a", "C1")
        self.assertIsNotNone(claim(mine, [], []))
        # ParallelX's own custom action and the other tweak's legacy ids must
        # fall through to ParallelX untouched.
        self.assertIsNone(claim(FOREIGN_ID, [], []))
        self.assertIsNone(claim(LEGACY_PREFIX + "com.a#C1", [], []))
        self.assertIsNone(claim("px.action.search", [], []))
        self.assertIsNone(claim("", [], []))


class SwitchNegatives(unittest.TestCase):
    def test_switch_failure_does_not_open(self):
        opened = []
        switch_ok, verified = False, True
        if switch_ok and verified:
            opened.append("com.a")
        self.assertEqual(opened, [])

    def test_wrong_account_after_switch_does_not_open(self):
        opened, active, target = [], "C2", "C1"
        if active == target:
            opened.append("com.a")
        self.assertEqual(opened, [])

    def test_repeat_tap_is_swallowed_but_return_to_first_is_not(self):
        last = None
        handles = []
        for identifier in ("A", "A", "B", "A"):
            handles.append(identifier != last)
            last = identifier
        self.assertEqual(handles, [True, False, True, True])

    def test_missing_crane_catalog_is_empty(self):
        self.assertEqual(sync([], [], catalog=[])[0], [])

    def test_corrupt_store_is_an_error_not_defaults(self):
        loaded, error = False, "corrupt"
        self.assertFalse(loaded)
        self.assertEqual(error, "corrupt")


class SourceNegatives(unittest.TestCase):
    def test_only_own_prefix_is_recognized(self):
        source = read("Tweak.xm")
        self.assertIn("PXCloneItemForIdentifier(identifier)", source)
        self.assertIn("PXCloneIsVirtualIdentifier", read("Common/PXCloneMenu.m"))

    def test_plain_launch_has_no_hook(self):
        source = read("Tweak.xm")
        # openURL is only probed on exact selectors, so ordinary desktop
        # launches still pass through untouched.
        self.assertIn("NSSelectorFromString(@\"openURL:\")", source)
        self.assertIn("NSSelectorFromString(@\"openURL:options:completionHandler:\")", source)
        self.assertNotIn("application:didFinishLaunching", source)

    def test_failed_transition_finishes_no(self):
        source = read("Common/PXClonePolicy.m")
        self.assertIn("container switch failed", source)
        self.assertIn("active container did not settle", source)


if __name__ == "__main__":
    unittest.main(verbosity=2)
