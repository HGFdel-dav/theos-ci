#!/usr/bin/env python3
"""Offline, fail-closed arm64e Objective-C class PAC acceptance gate.

Only reads binaries; no execution, signing, compilation or device access.
Other fat slices are range/header checked, then explicitly skipped. PAC rules
are the supplied Apple objc4 ABI contract, not inferred from CPU subtype.
"""
import argparse
import json
import mmap
import os
import struct
import sys

sys.dont_write_bytecode = True
ARM64 = 0x0100000C
LIMIT = 100000
FORMATS = (1, 9, 12)
DEPENDENCIES = {12: "load", 0x80000018: "weak", 0x8000001F: "reexport",
                0x20: "lazy", 0x80000023: "upward"}


class Invalid(ValueError):
    def __init__(self, code, message):
        super().__init__(message)
        self.code = code


def check(ok, code, message):
    if not ok:
        raise Invalid(code, message)


def version(n):
    return "%d.%d.%d" % (n >> 16, (n >> 8) & 255, n & 255)


def fixed_name(b):
    try:
        return b.split(b"\0", 1)[0].decode("ascii")
    except UnicodeError:
        raise Invalid("name", "non-ASCII Mach-O segment/section name")


class View:
    def __init__(self, buf, base=0, size=None):
        self.buf, self.base = buf, base
        self.size = len(buf) - base if size is None else size
        check(0 <= base <= len(buf) and 0 <= self.size <= len(buf) - base,
              "bounds", "invalid bounded view")

    def bounds(self, off, size):
        check(0 <= off <= self.size and 0 <= size <= self.size - off,
              "bounds", "range outside binary/view: offset=0x%x size=0x%x" % (off, size))

    def u(self, fmt, off):
        self.bounds(off, struct.calcsize(fmt))
        return struct.unpack_from(fmt, self.buf, self.base + off)

    def string(self, off, end, limit=4096):
        check(0 <= off < end <= self.size, "string_bounds", "string outside its owning range")
        stop = min(end, off + limit + 1)
        pos = self.buf.find(b"\0", self.base + off, self.base + stop)
        check(pos >= 0, "string", "unterminated or overlong string")
        try:
            text = self.buf[self.base + off:pos].decode("utf-8")
        except UnicodeError:
            raise Invalid("string", "invalid UTF-8 string")
        check(text and not any(ord(c) < 32 or ord(c) == 127 for c in text),
              "string", "empty/control-character string")
        return text


def slices(v):
    v.bounds(0, 8)
    magic = v.buf[v.base:v.base + 4]
    kinds = {b"\xca\xfe\xba\xbe": (">", False), b"\xbe\xba\xfe\xca": ("<", False),
             b"\xca\xfe\xba\xbf": (">", True), b"\xbf\xba\xfe\xca": ("<", True)}
    if magic not in kinds:
        check(magic == b"\xcf\xfa\xed\xfe", "magic", "not a supported little-endian 64-bit Mach-O")
        h = v.u("<8I", 0)
        return "thin", [(0, v.size, h[1], h[2])]
    endian, wide = kinds[magic]
    count = v.u(endian + "I", 4)[0]
    check(0 < count <= 64, "fat_count", "invalid/excessive fat slice count")
    stride = 32 if wide else 20
    table_end = 8 + count * stride
    v.bounds(0, table_end)
    result, seen = [], set()
    for i in range(count):
        a = v.u(endian + ("IIQQII" if wide else "IIIII"), 8 + i * stride)
        cpu, sub, off, size, align = a[:5]
        check(not wide or a[5] == 0, "fat_reserved", "nonzero fat64 reserved field")
        check(align <= 63 and off % (1 << align) == 0, "fat_alignment", "invalid fat slice alignment")
        v.bounds(off, size)
        check(off >= table_end and size >= 32, "fat_bounds", "fat slice intersects header or is too small")
        h = v.u("<8I", off)
        check(h[0] == 0xFEEDFACF and h[1:3] == (cpu, sub),
              "fat_header", "fat architecture disagrees with 64-bit slice header")
        key = (cpu, sub & 0xFFFFFF)
        check(key not in seen, "fat_duplicate", "duplicate fat architecture")
        seen.add(key)
        result.append((off, size, cpu, sub))
    ranges = sorted((a[0], a[0] + a[1]) for a in result)
    check(all(a[1] <= b[0] for a, b in zip(ranges, ranges[1:])),
          "fat_overlap", "overlapping fat slices")
    return "fat64" if wide else "fat32", result


class Image:
    def __init__(self, v, out):
        self.v, self.out = v, out
        self.segments, self.sections, self.deps, self.fixups = [], [], [], {}
        self.build, self.fixcmd = None, None

    def load(self):
        h = self.v.u("<8I", 0)
        check(h[0] == 0xFEEDFACF and h[7] == 0, "header", "invalid 64-bit Mach-O header")
        self.out["filetype"] = h[3]
        ncmds, sizecmds = h[4:6]
        check(0 < ncmds <= 4096, "commands", "invalid/excessive load command count")
        self.v.bounds(32, sizecmds)
        cursor, end = 32, 32 + sizecmds
        rpaths = []
        for _ in range(ncmds):
            check(cursor + 8 <= end, "commands", "truncated load command header")
            cmd, size = self.v.u("<II", cursor)
            check(size >= 8 and size % 8 == 0 and size <= end - cursor,
                  "commands", "invalid load command size")
            if cmd == 0x19:
                check(size >= 72, "segment", "truncated LC_SEGMENT_64")
                a = self.v.u("<16sQQQQIIII", cursor + 8)
                name, vm, vs, fo, fs, _, _, ns, flags = a
                name = fixed_name(name)
                check(size == 72 + ns * 80 and len(self.segments) < 256,
                      "segment", "invalid segment section count/size")
                check(vm + vs <= 1 << 64 and fs <= vs and not flags & 4,
                      "segment", "invalid/unsupported segment mapping")
                self.v.bounds(fo, fs)
                check(name not in [s["name"] for s in self.segments], "segment", "duplicate segment name")
                seg = dict(name=name, vmaddr=vm, vmsize=vs, fileoff=fo, filesize=fs)
                self.segments.append(seg)
                for j in range(ns):
                    s = self.v.u("<16s16sQQIIIIIIII", cursor + 72 + j * 80)
                    sn, sg, addr, length, offset, align, rel, nr, sf = s[:9]
                    check(fixed_name(sg) == name and vm <= addr <= vm + vs and length <= vm + vs - addr,
                          "section", "section outside its segment")
                    check(align <= 63 and addr % (1 << align) == 0,
                          "section", "invalid section alignment")
                    self.v.bounds(rel, nr * 8)
                    if sf & 255 not in (1, 12, 18):
                        self.v.bounds(offset, length)
                        check(offset == fo + addr - vm and offset >= fo and length <= fo + fs - offset,
                              "section", "section file/VM mappings disagree")
                    self.sections.append(dict(name=fixed_name(sn), addr=addr, size=length, flags=sf))
            elif cmd == 0x32:
                check(size >= 24 and self.build is None, "build_version", "invalid/duplicate LC_BUILD_VERSION")
                platform, minimum, sdk, tools = self.v.u("<4I", cursor + 8)
                check(size == 24 + tools * 8, "build_version", "truncated build tool table")
                self.build = dict(platform=platform, minos=version(minimum), sdk=version(sdk),
                                  tools=[dict(tool=t, version=version(ver)) for t, ver in
                                         (self.v.u("<II", cursor + 24 + j * 8) for j in range(tools))])
                self.out["build"] = self.build
            elif cmd in DEPENDENCIES or cmd == 13:
                check(size >= 24, "dylib", "truncated dylib command")
                no = self.v.u("<I", cursor + 8)[0]
                check(24 <= no < size, "dylib", "invalid dylib name offset")
                name = self.v.string(cursor + no, cursor + size)
                if cmd == 13:
                    self.out["install_name"] = name
                else:
                    self.deps.append(dict(ordinal=len(self.deps) + 1, name=name, kind=DEPENDENCIES[cmd]))
            elif cmd == 0x8000001C:
                check(size >= 16, "rpath", "truncated rpath command")
                no = self.v.u("<I", cursor + 8)[0]
                check(12 <= no < size, "rpath", "invalid rpath offset")
                rpaths.append(self.v.string(cursor + no, cursor + size))
            elif cmd == 0x80000034:
                check(size == 16 and self.fixcmd is None, "fixups_command", "invalid/duplicate LC_DYLD_CHAINED_FIXUPS")
                self.fixcmd = self.v.u("<II", cursor + 8)
            cursor += size
        check(cursor == end, "commands", "load commands do not fill sizeofcmds")
        for key, length in (("vmaddr", "vmsize"), ("fileoff", "filesize")):
            ranges = sorted((s[key], s[key] + s[length]) for s in self.segments if s[length])
            check(all(a[1] <= b[0] for a, b in zip(ranges, ranges[1:])), "segment_overlap", "overlapping segments")
        text = [s for s in self.segments if s["name"] == "__TEXT"]
        check(len(text) == 1 and text[0]["fileoff"] == 0 and text[0]["filesize"] >= end,
              "image_base", "missing/invalid __TEXT image base")
        self.base = text[0]["vmaddr"]
        self.out.update(image_base=hex(self.base), segments=self.segments, dependencies=self.deps, rpaths=rpaths)

    def mapped(self, address, size):
        for s in self.segments:
            delta = address - s["vmaddr"]
            if 0 <= delta <= s["filesize"] and size <= s["filesize"] - delta:
                return s["fileoff"] + delta, s["fileoff"] + s["filesize"]
        raise Invalid("target_bounds", "target is outside file-backed segments: " + hex(address))

    def decode(self, raw, fmt):
        auth, bind = raw >> 63, (raw >> 62) & 1
        p = dict(raw="0x%016x" % raw, pointer_format=fmt, auth=auth, bind=bind,
                 next=(raw >> 51) & 2047)
        if auth:
            p.update(diversity=(raw >> 32) & 65535, addrDiv=(raw >> 48) & 1,
                     key=(raw >> 49) & 3)
        if bind:
            bits = 24 if fmt == 12 else 16
            ordinal = raw & ((1 << bits) - 1)
            check(((raw >> bits) & ((1 << (32 - bits)) - 1)) == 0,
                  "pointer_reserved", "nonzero chained bind reserved bits")
            check(ordinal < len(self.imports), "bind_ordinal", "chained bind import index out of range")
            imp = self.imports[ordinal]
            addend = 0 if auth else (raw >> 32) & 0x7FFFF
            if addend & 0x40000:
                addend -= 0x80000
            p.update(import_index=ordinal, symbol=imp["symbol"], library_ordinal=imp["library_ordinal"],
                     library=imp["library"], weak_import=imp["weak_import"],
                     addend=imp["addend"] + addend)
        else:
            if auth:
                target = self.base + (raw & 0xFFFFFFFF)
            else:
                target = (raw & ((1 << 43) - 1)) + (0 if fmt == 1 else self.base)
                target |= ((raw >> 43) & 255) << 56
            check(target < 1 << 64, "target_bounds", "overflowed chained rebase target")
            address = target & 0x00FFFFFFFFFFFFFF
            check(any(s["vmaddr"] <= address < s["vmaddr"] + s["vmsize"] for s in self.segments),
                  "target_bounds", "rebase target is outside image VM segments")
            p["target"] = target
        return p

    def chains(self):
        check(self.fixcmd is not None, "missing_fixups", "LC_DYLD_CHAINED_FIXUPS is required")
        off, size = self.fixcmd
        self.v.bounds(off, size)
        link = [s for s in self.segments if s["name"] == "__LINKEDIT"]
        check(len(link) == 1 and link[0]["fileoff"] <= off and size >= 28 and
              size <= link[0]["fileoff"] + link[0]["filesize"] - off,
              "fixups_location", "chained fixups payload is not wholly in __LINKEDIT")
        f = View(self.v.buf, self.v.base + off, size)
        ver, starts, imports, symbols, count, form, symform = f.u("<7I", 0)
        check(ver == 0 and symform == 0, "fixups_format", "unsupported fixups version/compressed symbols")
        check(form in (1, 2, 3), "imports_format", "unsupported chained imports format")
        stride = {1: 4, 2: 8, 3: 16}[form]
        check(28 <= starts < imports <= symbols <= size and count <= LIMIT and
              count * stride <= symbols - imports,
              "imports_bounds", "invalid chained metadata offsets/count")
        self.imports = []
        for i in range(count):
            pos = imports + i * stride
            if form == 3:
                raw, addend = f.u("<Qq", pos)
                check((raw >> 17) & 0x7FFF == 0, "imports_reserved", "nonzero import3 reserved bits")
                ordinal, weak, nameoff = raw & 65535, (raw >> 16) & 1, raw >> 32
                if ordinal > 0xFFF0:
                    ordinal -= 65536
            else:
                raw = f.u("<I", pos)[0]
                ordinal, weak, nameoff = raw & 255, (raw >> 8) & 1, raw >> 9
                if ordinal > 0xF0:
                    ordinal -= 256
                addend = f.u("<i", pos + 4)[0] if form == 2 else 0
            check(ordinal in (-3, -2, -1, 0) or 1 <= ordinal <= len(self.deps),
                  "import_library", "chained import library ordinal out of range")
            symbol = f.string(symbols + nameoff, size)
            self.imports.append(dict(symbol=symbol, library_ordinal=ordinal,
                                     library=self.deps[ordinal - 1]["name"] if ordinal > 0 else None,
                                     weak_import=weak, addend=addend))
        self.out["chained_fixups"] = dict(slice_offset=off, file_offset=self.v.base + off, size=size,
                                          imports_count=count, imports_format=form, complete=False, segments=[])
        report = self.out["chained_fixups"]
        nseg = f.u("<I", starts)[0]
        check(nseg == len(self.segments) and starts + 4 + 4 * nseg <= imports,
              "starts_bounds", "chained segment count/table size disagrees with LC_SEGMENT_64")
        table_end = starts + 4 + 4 * nseg
        used = [(starts, table_end)]
        for i, seg in enumerate(self.segments):
            rel = f.u("<I", starts + 4 + 4 * i)[0]
            if not rel:
                continue
            pos = starts + rel
            check(table_end <= pos and pos + 22 <= imports, "starts_bounds", "segment starts header outside starts area")
            length, page_size, fmt, seg_offset, maximum, pages = f.u("<IHHQIH", pos)
            check(length >= 22 + 2 * pages and (length - 22) % 2 == 0 and length <= imports - pos,
                  "starts_bounds", "invalid chained segment starts length/page count")
            check(all(pos + length <= a or pos >= b for a, b in used), "starts_overlap", "overlapping chained starts tables")
            used.append((pos, pos + length))
            check(page_size in (4096, 16384) and fmt in FORMATS and maximum == 0,
                  "pointer_format", "unsupported chained pointer format/page size/max_valid_pointer")
            check(seg["vmaddr"] >= self.base and seg_offset == seg["vmaddr"] - self.base and
                  0 < pages <= (seg["vmsize"] + page_size - 1) // page_size,
                  "starts_mapping", "chained starts do not match segment VM/page mapping")
            entries = (length - 22) // 2
            values = f.u("<%dH" % entries, pos + 22)
            detail = dict(name=seg["name"], pointer_format=fmt, page_size=page_size,
                          page_count=pages, chain_count=0, fixup_count=0)
            report["segments"].append(detail)
            overflow_used = set()
            for page in range(pages):
                start = values[page]
                if start == 0xFFFF:
                    continue
                heads = []
                if start & 0x8000:
                    index = start & 0x7FFF
                    check(pages <= index < entries, "starts_multi", "invalid multi-start overflow index")
                    while True:
                        check(index < entries and index not in overflow_used, "starts_multi", "unterminated/reused overflow starts")
                        overflow_used.add(index)
                        value = values[index]
                        heads.append(value & 0x7FFF)
                        index += 1
                        if value & 0x8000:
                            break
                else:
                    heads = [start]
                for head in heads:
                    detail["chain_count"] += 1
                    cursor = head
                    while True:
                        check(cursor % 8 == 0 and cursor + 8 <= page_size,
                              "chain_bounds", "unaligned/cross-page chained pointer")
                        delta = page * page_size + cursor
                        check(delta + 8 <= seg["filesize"], "chain_bounds", "chain leaves file-backed segment")
                        address = seg["vmaddr"] + delta
                        check(address not in self.fixups and len(self.fixups) < LIMIT,
                              "chain_duplicate", "duplicate chain slot or fixup resource limit")
                        raw = self.v.u("<Q", seg["fileoff"] + delta)[0]
                        pointer = self.decode(raw, fmt)
                        self.fixups[address] = pointer
                        detail["fixup_count"] += 1
                        if pointer["next"] == 0:
                            break
                        cursor += pointer["next"] * 8
        report.update(complete=True, fixup_count=len(self.fixups))

    def local(self, slot, mask=0):
        p = self.fixups.get(slot)
        check(p is not None, "field_not_chained", "required discovery pointer is not in a traversed chain: " + hex(slot - self.base))
        check(not p["bind"], "class_target", "class discovery requires an in-image rebase")
        target = p["target"] & ~mask
        self.mapped(target, 1)
        return target

    def ro(self, address):
        self.mapped(address, 40)
        data = self.local(address + 32, 7)
        offset, _ = self.mapped(data, 72)
        flags = self.v.u("<I", offset)[0]
        name_address = self.local(data + 24)
        name_offset, end = self.mapped(name_address, 1)
        return flags, self.v.string(name_offset, end, 1024)

    def find_class(self):
        lists = [s for s in self.sections if s["name"] == "__objc_classlist"]
        check(lists and sum(s["size"] for s in lists) > 0, "classlist", "missing/empty __objc_classlist")
        found, total = [], 0
        for section in lists:
            check(section["flags"] & 255 == 0 and section["size"] % 8 == 0,
                  "classlist", "invalid __objc_classlist section type/size")
            total += section["size"] // 8
            check(total <= 16384, "classlist", "classlist resource limit")
            for delta in range(0, section["size"], 8):
                address = self.local(section["addr"] + delta)
                flags, name = self.ro(address)
                if name == "SMCSSHandler":
                    check(not flags & 1, "class_ro", "classlist points to a metaclass")
                    found.append(address)
        check(len(found) == 1, "class_name", "expected exactly one SMCSSHandler via class_ro_t.name")
        address = found[0]
        meta = self.local(address)
        flags, name = self.ro(meta)
        check(meta != address and flags & 1 and name == "SMCSSHandler", "metaclass", "invalid SMCSSHandler metaclass/name")
        self.out["objc"] = dict(name="SMCSSHandler", discovery="__objc_classlist -> class.data & ~7 -> class_ro_t.name",
                                class_image_offset=hex(address - self.base),
                                metaclass_image_offset=hex(meta - self.base), fields={})
        return address, meta

    def pac(self, address, meta, report, index):
        rules = [("class.isa", address, 0x6AE1, None),
                 ("class.superclass", address + 8, 0xB5AB, "_OBJC_CLASS_$_NSObject"),
                 ("metaclass.isa", meta, 0x6AE1, "_OBJC_METACLASS_$_NSObject"),
                 ("metaclass.superclass", meta + 8, 0xB5AB, "_OBJC_METACLASS_$_NSObject")]
        fields = self.out["objc"]["fields"]
        for name, slot, diversity, symbol in rules:
            p = self.fixups.get(slot)
            field = dict(image_offset=hex(slot - self.base), in_chain=p is not None)
            fields[name] = field
            if p is None:
                error(report, "field_not_chained", name + " is not in a traversed chain", index)
                continue
            field.update({k: v for k, v in p.items() if k != "target"})
            field["file_offset"] = self.v.base + self.mapped(slot, 8)[0]
            if "target" in p:
                field["target_vmaddr"] = hex(p["target"])
            if p["auth"] != 1:
                error(report, "pac_auth", name + " is UNAUTH; AUTH is required", index)
            else:
                for key, value in (("key", 2), ("addrDiv", 1), ("diversity", diversity)):
                    if p[key] != value:
                        error(report, "pac_" + key, name + " requires %s=%s" %
                              (key, hex(value) if key == "diversity" else value), index)
            if symbol is None:
                good = not p["bind"] and p["target"] == meta
            else:
                good = (p["bind"] and p["symbol"] == symbol and p["library_ordinal"] > 0 and
                        not p["weak_import"] and p["addend"] == 0)
            if not good:
                error(report, "pac_target", name + " has an invalid local/external NSObject target", index)


def error(report, code, message, index=None):
    item = dict(code=code, message=message)
    if index is not None:
        item["slice"] = index
    report["errors"].append(item)


def verify(path, allow_other_slices=False, inspect_only=False):
    report = dict(schema_version=1, path=os.fspath(path), mode="inspect-only" if inspect_only else "strict",
                  passed=False, errors=[], slices=[],
                  requirements=dict(architecture="arm64e", allow_other_slices=allow_other_slices,
                                    platform="iOS", minos="15.0.0", sdk="15.5.0",
                                    pointer_formats=list(FORMATS), key="DA (2)", addrDiv=1,
                                    isa_diversity="0x6AE1", superclass_diversity="0xB5AB"),
                  notes=["Static metadata/PAC gate only; does not prove Apple clang/Theos/RootHide provenance, signing, loading or runtime compatibility.",
                         "Extra slices are header/range checked but not PAC-validated; allow-other-slices relaxes only their presence."])
    try:
        with open(path, "rb") as handle:
            check(os.fstat(handle.fileno()).st_size >= 32, "bounds", "file is empty/truncated")
            with mmap.mmap(handle.fileno(), 0, access=mmap.ACCESS_READ) as buf:
                v = View(buf)
                kind, descriptors = slices(v)
                report["container"] = kind
                target_count = 0
                for index, (off, size, cpu, sub) in enumerate(descriptors):
                    target = cpu == ARM64 and sub & 0xFFFFFF == 2
                    out = dict(index=index, offset=off, size=size, cputype="0x%08x" % cpu,
                               cpusubtype_raw="0x%08x" % sub, cpusubtype_base=sub & 0xFFFFFF,
                               arch="arm64e" if target else ("arm64" if cpu == ARM64 else "other"))
                    report["slices"].append(out)
                    if not target:
                        out["skipped"] = "not an arm64e target; no PAC claim"
                        if not allow_other_slices:
                            error(report, "extra_slice", "strict candidate permits only arm64e slices", index)
                        continue
                    target_count += 1
                    try:
                        image = Image(View(buf, off, size), out)
                        image.load()
                        if out["filetype"] != 6:
                            error(report, "filetype", "candidate must be MH_DYLIB", index)
                        if image.build is None:
                            error(report, "build_version", "LC_BUILD_VERSION is required", index)
                        else:
                            for key, expected in (("platform", 2), ("minos", "15.0.0"), ("sdk", "15.5.0")):
                                if image.build[key] != expected:
                                    error(report, "build_" + key, "requires %s=%s; found %s" %
                                          (key, expected, image.build[key]), index)
                        image.chains()
                        address, meta = image.find_class()
                        image.pac(address, meta, report, index)
                        out["validated"] = not any(e.get("slice") == index for e in report["errors"])
                    except Invalid as exc:
                        error(report, exc.code, str(exc), index)
                        out["validated"] = False
                if not target_count:
                    error(report, "missing_arm64e", "at least one arm64e slice is required")
    except Invalid as exc:
        error(report, exc.code, str(exc))
    except (OSError, ValueError) as exc:
        error(report, "io", "cannot read/map input: " + str(exc))
    report["passed"] = not report["errors"]
    return report


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("path")
    parser.add_argument("--json", metavar="OUTPUT", help="also write JSON report to OUTPUT")
    parser.add_argument("--allow-other-slices", action="store_true")
    parser.add_argument("--inspect-only", action="store_true", help="retain failure report but return zero")
    args = parser.parse_args(argv)
    report = verify(args.path, args.allow_other_slices, args.inspect_only)
    if args.json:
        try:
            # Never permit an output path to overwrite the inspected input.
            check(os.path.realpath(args.json) != os.path.realpath(args.path), "output", "JSON output must not overwrite input")
            if os.path.exists(args.json):
                check(not os.path.samefile(args.json, args.path), "output", "JSON output aliases input")
            with open(args.json, "w", encoding="utf-8") as output:
                json.dump(report, output, ensure_ascii=True, indent=2)
                output.write("\n")
        except (Invalid, OSError) as exc:
            error(report, "output", str(exc))
            report["passed"] = False
    print(json.dumps(report, ensure_ascii=True, indent=2))
    print(("PASS" if report["passed"] else "FAIL") + " static Mach-O PAC: " + args.path, file=sys.stderr)
    for s in report["slices"]:
        b = s.get("build", {})
        c = s.get("chained_fixups", {})
        print("  slice %d %s offset=0x%x minOS=%s SDK=%s chain_complete=%s fixups=%s" %
              (s["index"], s["arch"], s["offset"], b.get("minos", "n/a"), b.get("sdk", "n/a"),
               c.get("complete", False), c.get("fixup_count", "n/a")), file=sys.stderr)
    for e in report["errors"]:
        print("  [%s] %s" % (e["code"], e["message"]), file=sys.stderr)
    if args.inspect_only:
        print("  inspect-only: exit 0; report.passed is authoritative", file=sys.stderr)
    return 0 if args.inspect_only or report["passed"] else 1


if __name__ == "__main__":
    sys.exit(main())
