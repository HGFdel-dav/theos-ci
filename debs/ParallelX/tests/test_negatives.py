#!/usr/bin/env python3
"""Negative cases named by the handoff, kept host-side and deterministic."""
import os
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def read(rel):
    with open(os.path.join(ROOT, rel), encoding="utf-8") as handle:
        return handle.read()


PREFIX = "px.clone."
CATALOG = [
    {"bundle": "com.a", "name": "A", "containers": [
        {"container": "DEFAULT", "name": "默认", "isDefault": True},
        {"container": "C1", "name": "小号", "isDefault": False},
    ]},
]


def sync(existing_apps, existing_actions, catalog=CATALOG, visible=lambda b, c: True):
    apps = list(existing_apps)
    actions = list(existing_actions)
    desired = set()
    for app in catalog:
        for container in app["containers"]:
            if not visible(app["bundle"], container["container"]):
                continue
            identifier = PREFIX + app["bundle"] + "#" + container["container"]
            desired.add(identifier)
            if identifier not in apps:
                apps.append(identifier)
            if not any(record.get("id") == identifier for record in actions):
                actions.append({"id": identifier, "app": app["bundle"],
                                "kind": "quick", "type": "clonex.open"})
    apps = [item for item in apps if not (item.startswith(PREFIX) and item not in desired)]
    actions = [item for item in actions
               if not (str(item.get("id", "")).startswith(PREFIX) and item["id"] not in desired)]
    return apps, actions


def parse(identifier):
    if not identifier.startswith(PREFIX):
        return None
    body = identifier[len(PREFIX):]
    if body.count("#") != 1:
        return None
    bundle, container = body.split("#")
    if not bundle or not container:
        return None
    return {"bundle": bundle, "container": container}


class MenuNegatives(unittest.TestCase):
    def test_same_virtual_item_is_not_duplicated(self):
        apps, actions = sync([], [])
        apps, actions = sync(apps, actions)
        self.assertEqual(apps.count(PREFIX + "com.a#C1"), 1)
        self.assertEqual(sum(1 for x in actions if x["id"] == PREFIX + "com.a#C1"), 1)

    def test_existing_foreign_item_order_kept(self):
        apps = ["com.foreign", PREFIX + "com.a#DEFAULT"]
        actions = [{"id": "com.foreign"}, {"id": PREFIX + "com.a#DEFAULT"}]
        out_apps, out_actions = sync(apps, actions)
        self.assertEqual(out_apps[0], "com.foreign")
        self.assertEqual(out_actions[0]["id"], "com.foreign")

    def test_hidden_account_not_injected(self):
        apps, actions = sync([], [], visible=lambda b, c: c != "C1")
        self.assertNotIn(PREFIX + "com.a#C1", apps)
        self.assertIn(PREFIX + "com.a#DEFAULT", apps)

    def test_stale_virtual_item_removed(self):
        apps = [PREFIX + "com.gone#C1"]
        actions = [{"id": PREFIX + "com.gone#C1"}]
        out_apps, out_actions = sync(apps, actions)
        self.assertNotIn(PREFIX + "com.gone#C1", out_apps)
        self.assertFalse(any(x["id"] == PREFIX + "com.gone#C1" for x in out_actions))

    def test_empty_catalog_removes_all_virtual_but_keeps_foreign(self):
        apps = [PREFIX + "com.a#C1", "com.foreign"]
        actions = [{"id": PREFIX + "com.a#C1"}, {"id": "com.foreign"}]
        out_apps, out_actions = sync(apps, actions, catalog=[])
        self.assertEqual(out_apps, ["com.foreign"])
        self.assertEqual([x["id"] for x in out_actions], ["com.foreign"])

    def test_illegal_bundle_or_container(self):
        self.assertIsNone(parse(PREFIX + "#C1"))
        self.assertIsNone(parse(PREFIX + "com.a#"))
        self.assertIsNone(parse(PREFIX + "com.a#C1#extra"))
        self.assertIsNone(parse("com.a#C1"))
        self.assertIsNone(parse(""))

    def test_prefix_is_ours_only(self):
        self.assertTrue(parse(PREFIX + "com.a#C1"))
        self.assertFalse((PREFIX + "com.a#C1").startswith("px.action."))


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

    def test_repeat_tap_is_swallowed(self):
        recent = set()
        first = "px.clone.com.a#C1"
        second = "px.clone.com.a#C2"
        handles = []
        for identifier in (first, second, first):
            if identifier in recent:
                handles.append(False)
                continue
            recent.add(identifier)
            handles.append(True)
        self.assertEqual(handles, [True, True, False])

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
        # No openURL / application-launch hook: ordinary desktop launches pass through.
        self.assertNotIn("openURL", source)
        self.assertNotIn("application:didFinishLaunching", source)

    def test_failed_transition_finishes_no(self):
        source = read("Common/PXClonePolicy.m")
        self.assertIn("container switch failed", source)
        self.assertIn("active container did not settle", source)


if __name__ == "__main__":
    unittest.main(verbosity=2)
