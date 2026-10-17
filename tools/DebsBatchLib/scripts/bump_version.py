#!/usr/bin/env python3
"""把 App 的 Info.plist 版本号改为 8.0.1 / 2（TrollStore 覆盖安装用）

用法: bump_version.py <Info.plist 路径>
"""
import plistlib
import sys


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__)
        return 2
    path = sys.argv[1]
    with open(path, "rb") as f:
        d = plistlib.load(f)
    d["CFBundleShortVersionString"] = "8.0.1"
    d["CFBundleVersion"] = "2"
    with open(path, "wb") as f:
        plistlib.dump(d, f)
    print("bumped:", path, "->", d["CFBundleShortVersionString"], d["CFBundleVersion"])
    return 0


if __name__ == "__main__":
    sys.exit(main())