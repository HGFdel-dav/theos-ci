#!/usr/bin/env python3
"""给 Mach-O 主二进制添加 LC_LOAD_DYLIB（DebsBatch IPA 组装用）

用法:
  patch_macho.py <主二进制路径> <dylib 加载路径>

示例:
  patch_macho.py Payload/Debs.app/Debs @executable_path/Frameworks/libDebsBatch.dylib
"""
import sys

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

    n = 0
    if isinstance(parsed, lief.MachO.FatBinary):
        for b in parsed.fat_binaries:
            b.add_dylib(dylib_load_path)
            n += 1
        parsed.write(binary_path)
    elif isinstance(parsed, list):
        for b in parsed:
            b.add_dylib(dylib_load_path)
            b.write(binary_path)
            n += 1
    else:
        parsed.add_dylib(dylib_load_path)
        parsed.write(binary_path)
        n = 1

    print("patched slices:", n)
    if n == 0:
        print("ERROR: no slices patched")
        return 1
    return 0

if __name__ == "__main__":
    sys.exit(main())