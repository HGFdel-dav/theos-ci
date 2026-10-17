#!/usr/bin/env python3
"""给 Mach-O 主二进制添加 LC_LOAD_DYLIB（DebsBatch IPA 组装用）

用法:
  patch_macho.py <主二进制路径> <dylib 加载路径>

示例:
  patch_macho.py Payload/Debs.app/Debs @executable_path/Frameworks/libDebsBatch.dylib
"""
import sys


def _macho_slices(parsed):
    """返回 Mach-O slice 列表，兼容 lief 0.13~0.17 各版本 API。"""
    # 老版本 parse 直接返回 list
    if isinstance(parsed, list):
        return parsed
    # FatBinary: 优先 at(i) + size（nanobind 版本稳定 API）
    try:
        n = parsed.size
        if n > 0:
            return [parsed.at(i) for i in range(n)]
    except Exception:
        pass
    # 其次迭代器属性/方法（it_binaries / fat_binaries / binaries）
    for name in ("it_binaries", "fat_binaries", "binaries"):
        try:
            attr = getattr(parsed, name)
            if callable(attr):
                attr = attr()
            return list(attr)
        except Exception:
            continue
    # 单 slice 兜底
    return [parsed]


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__)
        return 2
    binary_path, dylib_load_path = sys.argv[1], sys.argv[2]

    import lief

    parsed = lief.MachO.parse(binary_path)
    if parsed is None:
        print("ERROR: MachO parse failed:", binary_path)
        return 1

    slices = _macho_slices(parsed)
    # 避免同一个 slice 被重复处理（FatBinary.at(i) 可能返回同一对象）
    seen = set()
    for b in slices:
        key = id(b)
        if key in seen:
            continue
        seen.add(key)
        try:
            b.add_dylib(dylib_load_path)
        except AttributeError:
            # 新版 LIEF (0.16+/nanobind) 改用 add_library
            b.add_library(dylib_load_path)

    n = len(seen)
    print("patched slices:", n)
    if n == 0:
        print("ERROR: no slices patched")
        return 1

    if isinstance(parsed, list):
        for b in slices:
            b.write(binary_path)
    else:
        parsed.write(binary_path)
    print("written:", binary_path)
    return 0


if __name__ == "__main__":
    sys.exit(main())