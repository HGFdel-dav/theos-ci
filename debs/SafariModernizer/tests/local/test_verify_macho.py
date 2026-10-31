"""Synthetic parser/PAC tests only: no compilation or runtime/load claim."""
import contextlib
import importlib.util
import itertools
import json
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent
TOOL = HERE.parents[1] / "tools" / "verify_macho.py"
SPEC = importlib.util.spec_from_file_location("verify_macho", TOOL)
VERIFY = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(VERIFY)
SAMPLE = Path("/var/minis/workspace/SafariModernizer-audit/reference/rh/data/Library/MobileSubstrate/DynamicLibraries/SafariModernizer.dylib")
BASE = 0x100000000
SLOTS = (0x1000, 0x1100, 0x1108, 0x1120, 0x1140, 0x1148, 0x1160, 0x1218, 0x1268)


def command(kind, payload):
    size = (8 + len(payload) + 7) & ~7
    return struct.pack("<II", kind, size) + payload + bytes(size - 8 - len(payload))


def rebase(target, fmt=12, auth=False, diversity=0x6AE1):
    if auth:
        return (1 << 63) | target | (diversity << 32) | (1 << 48) | (2 << 49)
    return target + (BASE if fmt == 1 else 0)


def bind(index, auth=True, diversity=0xB5AB):
    raw = (1 << 62) | index
    return raw | ((1 << 63) | (diversity << 32) | (1 << 48) | (2 << 49) if auth else 0)


def synthetic(fmt=12, import_format=1, unauth=False):
    b = bytearray(0x3000)
    symbols = b"_OBJC_CLASS_$_NSObject\0_OBJC_METACLASS_$_NSObject\0"
    offset2 = symbols.index(b"_OBJC_METACLASS_")
    imports = bytearray()
    for nameoff in (0, offset2):
        if import_format == 3:
            imports += struct.pack("<Qq", 1 | (nameoff << 32), 0)
        else:
            imports += struct.pack("<I", 1 | (nameoff << 9))
            if import_format == 2:
                imports += struct.pack("<i", 0)
    starts = struct.pack("<4I", 3, 0, 16, 0)
    starts += struct.pack("<IHHQIH", 24, 4096, fmt, 0x1000, 0, 1) + struct.pack("<H", 0)
    import_off = 32 + len(starts)
    symbol_off = import_off + len(imports)
    payload = struct.pack("<7I", 0, 32, import_off, symbol_off, 2, import_format, 0)
    payload += bytes(4) + starts + imports + symbols
    b[0x2000:0x2000 + len(payload)] = payload
    cmds = []
    for name, off, section in (("__TEXT", 0, False), ("__DATA", 0x1000, True), ("__LINKEDIT", 0x2000, False)):
        segment = struct.pack("<16sQQQQIIII", name.encode(), BASE + off, 0x1000, off, 0x1000, 3, 3, int(section), 0)
        if section:
            segment += struct.pack("<16s16sQQIIIIIIII", b"__objc_classlist", b"__DATA", BASE + 0x1000,
                                   8, 0x1000, 3, 0, 0, 0, 0, 0, 0)
        cmds.append(command(0x19, segment))
    build_command = 32 + sum(map(len, cmds))
    cmds.append(command(0x32, struct.pack("<6I", 2, 0xF0000, 0xF0500, 1, 3, 0x7110000)))
    cmds.append(command(12, struct.pack("<4I", 24, 0, 0, 0) + b"/usr/lib/libobjc.A.dylib\0"))
    cmds.append(command(0x8000001C, struct.pack("<I", 12) + b"@loader_path\0"))
    fix_command = 32 + sum(map(len, cmds))
    cmds.append(command(0x80000034, struct.pack("<II", 0x2000, len(payload))))
    commands = b"".join(cmds)
    struct.pack_into("<8I", b, 0, 0xFEEDFACF, VERIFY.ARM64, 0x80000002, 6, len(cmds), len(commands), 0, 0)
    b[32:32 + len(commands)] = commands
    pointers = {0x1000: rebase(0x1100, fmt), 0x1100: rebase(0x1140, fmt, not unauth),
                0x1108: bind(0, not unauth), 0x1120: rebase(0x1203, fmt),
                0x1140: bind(1, not unauth, 0x6AE1), 0x1148: bind(1, not unauth),
                0x1160: rebase(0x1257, fmt), 0x1218: rebase(0x1300, fmt), 0x1268: rebase(0x1300, fmt)}
    for i, slot in enumerate(SLOTS):
        step = (SLOTS[i + 1] - slot) // 8 if i + 1 < len(SLOTS) else 0
        struct.pack_into("<Q", b, slot, pointers[slot] | (step << 51))
    struct.pack_into("<I", b, 0x1200, 0)
    struct.pack_into("<I", b, 0x1250, 1)
    b[0x1300:0x130D] = b"SMCSSHandler\0"
    return b, dict(build=build_command, fix=fix_command, imports=0x2000 + import_off,
                   symbols=0x2000 + symbol_off, starts=0x2020)


def word(b, off):
    return struct.unpack_from("<Q", b, off)[0]


def set_word(b, off, value):
    struct.pack_into("<Q", b, off, value)


@contextlib.contextmanager
def fixture(b):
    # Every temporary artifact is under the explicitly permitted tests/local.
    with tempfile.TemporaryDirectory(prefix="pac-fixture-", dir=HERE) as folder:
        path = Path(folder) / "synthetic.dylib"
        path.write_bytes(b)
        yield path


def result(b, **kwargs):
    with fixture(b) as path:
        return VERIFY.verify(path, **kwargs)


def codes(report):
    return {e["code"] for e in report["errors"]}


class VerifyMachOTests(unittest.TestCase):
    def test_auth_formats_and_imports(self):
        for fmt, imports in itertools.product((1, 9, 12), (1, 2, 3)):
            with self.subTest(pointer_format=fmt, imports_format=imports):
                r = result(synthetic(fmt, imports)[0])
                self.assertTrue(r["passed"], r["errors"])
                s = r["slices"][0]
                self.assertEqual(s["objc"]["class_image_offset"], "0x1100")
                self.assertEqual(s["chained_fixups"]["fixup_count"], 9)
                self.assertTrue(s["chained_fixups"]["complete"])
                self.assertEqual(s["dependencies"][0]["name"], "/usr/lib/libobjc.A.dylib")
                self.assertEqual(s["rpaths"], ["@loader_path"])

    def test_unauthed_original_style(self):
        r = result(synthetic(unauth=True)[0])
        self.assertFalse(r["passed"])
        self.assertEqual(sum(e["code"] == "pac_auth" for e in r["errors"]), 4)
        f = r["slices"][0]["objc"]["fields"]["class.superclass"]
        self.assertEqual((f["auth"], f["bind"], f["symbol"]), (0, 1, "_OBJC_CLASS_$_NSObject"))

    def test_wrong_pac_parameters(self):
        for code, mask, replace in (("pac_key", 3 << 49, 3 << 49),
                                    ("pac_addrDiv", 1 << 48, 0),
                                    ("pac_diversity", 65535 << 32, 0xB5AA << 32)):
            with self.subTest(code=code):
                b, _ = synthetic()
                set_word(b, 0x1108, (word(b, 0x1108) & ~mask) | replace)
                r = result(b)
                self.assertFalse(r["passed"])
                self.assertIn(code, codes(r))

    def test_missing_required_chain_slot(self):
        b, _ = synthetic()
        set_word(b, 0x1100, (word(b, 0x1100) & ~(2047 << 51)) | (4 << 51))
        self.assertIn("field_not_chained", codes(result(b)))

    def test_missing_fixups(self):
        b, m = synthetic()
        struct.pack_into("<I", b, m["fix"], 0x80000033)
        self.assertIn("missing_fixups", codes(result(b)))

    def test_bad_class_name(self):
        b, _ = synthetic()
        b[0x1300] = ord("X")
        self.assertIn("class_name", codes(result(b)))

    def test_bad_external_target(self):
        b, _ = synthetic()
        set_word(b, 0x1140, word(b, 0x1140) & ~65535)
        self.assertIn("pac_target", codes(result(b)))

    def test_build_constraints(self):
        for delta, value, code in ((8, 7, "build_platform"), (12, 0xF0100, "build_minos"), (16, 0x100000, "build_sdk")):
            with self.subTest(code=code):
                b, m = synthetic()
                struct.pack_into("<I", b, m["build"] + delta, value)
                self.assertIn(code, codes(result(b)))

    def test_truncated_and_out_of_bounds(self):
        for length in (0, 4, 31, 40, 0x2005, 0x2FFF):
            with self.subTest(length=length):
                b, _ = synthetic()
                self.assertFalse(result(b[:length])["passed"])
        b, m = synthetic()
        struct.pack_into("<II", b, m["fix"] + 8, 0xFFFFFFF0, 1024)
        self.assertIn("bounds", codes(result(b)))

    def test_bad_load_command_size(self):
        b, _ = synthetic()
        struct.pack_into("<I", b, 36, 0xFFFFFFF8)
        self.assertIn("commands", codes(result(b)))

    def test_malformed_imports(self):
        for kind in ("count", "name", "reserved", "ordinal", "format"):
            with self.subTest(kind=kind):
                b, m = synthetic(import_format=3 if kind == "reserved" else 1)
                if kind == "count":
                    struct.pack_into("<I", b, 0x2010, 0xFFFFFFFF)
                elif kind == "name":
                    struct.pack_into("<I", b, m["imports"], 1 | (0x7FFFFF << 9))
                elif kind == "reserved":
                    set_word(b, m["imports"], word(b, m["imports"]) | (1 << 17))
                elif kind == "ordinal":
                    struct.pack_into("<I", b, m["imports"], 7)
                else:
                    struct.pack_into("<I", b, 0x2014, 99)
                self.assertFalse(result(b)["passed"])

    def test_unsupported_pointer_format(self):
        b, m = synthetic()
        struct.pack_into("<H", b, m["starts"] + 16 + 6, 6)
        self.assertIn("pointer_format", codes(result(b)))

    def test_entire_chain_checked(self):
        b, _ = synthetic()
        set_word(b, 0x1268, word(b, 0x1268) | (((0x1400 - 0x1268) // 8) << 51))
        set_word(b, 0x1400, rebase(0x9000))
        self.assertIn("target_bounds", codes(result(b)))

    def test_chain_page_boundary(self):
        b, _ = synthetic()
        set_word(b, 0x1268, word(b, 0x1268) | (2047 << 51))
        self.assertIn("chain_bounds", codes(result(b)))

    def test_unterminated_name(self):
        b, _ = synthetic()
        b[0x1300:0x2000] = b"A" * 0xD00
        self.assertIn("string", codes(result(b)))

    def test_fat64_and_extra_slice_policy(self):
        a, _ = synthetic()
        other = bytearray(a)
        struct.pack_into("<I", other, 8, 0)
        for endian, wide in ((">", True), ("<", True), (">", False), ("<", False)):
            with self.subTest(endian=endian, fat64=wide):
                magic = 0xCAFEBABF if wide else 0xCAFEBABE
                header = struct.pack(endian + "II", magic, 2)
                for offset, subtype in ((0x1000, 0x80000002), (0x4000, 0)):
                    values = (VERIFY.ARM64, subtype, offset, len(a), 12) + ((0,) if wide else ())
                    header += struct.pack(endian + ("IIQQII" if wide else "IIIII"), *values)
                b = bytearray(0x7000)
                b[:len(header)] = header
                b[0x1000:0x4000] = a
                b[0x4000:] = other
                self.assertIn("extra_slice", codes(result(b)))
                r = result(b, allow_other_slices=True)
                self.assertTrue(r["passed"], r["errors"])
                self.assertIn("skipped", r["slices"][1])
                # Relaxing extra slices must not relax target SDK validation.
                struct.pack_into("<I", b, 0x1000 + synthetic()[1]["build"] + 16, 0xE0500)
                self.assertIn("build_sdk", codes(result(b, allow_other_slices=True)))

    def test_fat64_out_of_bounds(self):
        b = bytearray(64)
        struct.pack_into(">II", b, 0, 0xCAFEBABF, 1)
        struct.pack_into(">IIQQII", b, 8, VERIFY.ARM64, 2, 0xFFFFFFFFFFFFF000, 0x1000, 12, 0)
        self.assertIn("bounds", codes(result(b)))

    def cli(self, path, *options):
        p = subprocess.run([sys.executable, "-B", str(TOOL), str(path), *map(str, options)],
                           capture_output=True, text=True, timeout=20)
        return p, json.loads(p.stdout)

    def test_cli_positive_and_json(self):
        with fixture(synthetic()[0]) as path:
            destination = path.with_suffix(".json")
            p, r = self.cli(path, "--json", destination)
            self.assertEqual(p.returncode, 0, p.stderr)
            self.assertTrue(r["passed"])
            self.assertEqual(json.loads(destination.read_text()), r)
            self.assertIn("PASS static Mach-O PAC", p.stderr)

    def test_cli_negative_and_inspect_only(self):
        with fixture(synthetic(unauth=True)[0]) as path:
            p, r = self.cli(path)
            self.assertEqual(p.returncode, 1)
            self.assertFalse(r["passed"])
            p, r = self.cli(path, "--inspect-only")
            self.assertEqual(p.returncode, 0)
            self.assertFalse(r["passed"])
            self.assertEqual(r["mode"], "inspect-only")

    def test_cli_does_not_overwrite_input(self):
        b, _ = synthetic()
        with fixture(b) as path:
            p, r = self.cli(path, "--json", path)
            self.assertEqual(p.returncode, 1)
            self.assertIn("output", codes(r))
            self.assertEqual(path.read_bytes(), b)

    @unittest.skipUnless(SAMPLE.is_file(), "original release sample not present")
    def test_original_release_rejected(self):
        r = VERIFY.verify(SAMPLE)
        self.assertFalse(r["passed"])
        target = next(s for s in r["slices"] if s["arch"] == "arm64e")
        self.assertEqual(target["offset"], 786432)
        self.assertEqual(target["objc"]["class_image_offset"], "0xb4a50")
        f = target["objc"]["fields"]["class.superclass"]
        self.assertEqual(f["raw"], "0x4008000000000044")
        self.assertEqual((f["auth"], f["bind"], f["import_index"], f["symbol"]),
                         (0, 1, 68, "_OBJC_CLASS_$_NSObject"))
        self.assertIn("pac_auth", codes(r))
        p, r = self.cli(SAMPLE, "--allow-other-slices")
        self.assertEqual(p.returncode, 1)
        self.assertFalse(r["passed"])
        p, r = self.cli(SAMPLE, "--inspect-only")
        self.assertEqual(p.returncode, 0)
        self.assertFalse(r["passed"])


if __name__ == "__main__":
    unittest.main()
