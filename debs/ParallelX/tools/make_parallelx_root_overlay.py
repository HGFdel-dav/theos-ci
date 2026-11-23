#!/usr/bin/env python3
"""Build the Root.plist row using the old verified Preferences injection path."""
from pathlib import Path
import plistlib

root = Path(__file__).resolve().parents[1]
original = root / "vendor/alpha451/Library/PreferenceBundles/ParallelXPrefs.bundle/Root.plist"
out = root / "layout/Library/PreferenceBundles/ParallelXPrefs.bundle/Root.plist"
data = plistlib.loads(original.read_bytes())
items = data.setdefault("items", [])
entry = {
    "cell": "PSLinkCell",
    "label": "分身账号",
    "detail": "PXCloneAccountsController",
    "isController": True,
    "sfColor": "orange",
    "sfSymbol": "person.2",
}
if not any(item.get("detail") == entry["detail"]
           for item in items if isinstance(item, dict)):
    insert_at = next((i + 1 for i, item in enumerate(items)
                      if isinstance(item, dict) and item.get("id") == "launcher"), len(items))
    items.insert(insert_at, entry)
out.parent.mkdir(parents=True, exist_ok=True)
memory_entry = {
    "cell": "PSLinkCell", "label": "窗口大小与位置记忆",
    "detail": "PXWindowMemoryController", "isController": True,
    "sfColor": "blue", "sfSymbol": "arrow.up.left.and.arrow.down.right",
}
if not any(isinstance(item, dict) and item.get("detail") == memory_entry["detail"] for item in items):
    insert_at = next((i + 1 for i, item in enumerate(items)
                      if isinstance(item, dict) and item.get("id") == "window"), len(items))
    items.insert(insert_at, memory_entry)
out.write_bytes(plistlib.dumps(data, fmt=plistlib.FMT_BINARY, sort_keys=False))
print(out)
