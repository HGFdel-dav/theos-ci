"""Regression checks from the UUID-matched clone0.4 SpringBoard crash.
These host tests inspect code/fixtures only; no target image is executed.
"""
import importlib.util
from pathlib import Path
import struct
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("px_pac_check", ROOT / "tools/check_pac.py")
PAC = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PAC)


def words(*values):
    return b"".join(struct.pack("<I", value) for value in values)


def thin_fixture(instructions, subtype=0x80000002):
    text_offset = 32 + 72 + 80
    header = struct.pack("<8I", 0xFEEDFACF, 0x100000C, subtype, 6, 1, 152, 0, 0)
    segment = struct.pack("<II16sQQQQIIII", 0x19, 152, b"__TEXT", 0, 0x4000,
                          0, text_offset + len(instructions), 5, 5, 1, 0)
    section = struct.pack("<16s16sQQIIIIIIII", b"__text", b"__TEXT", 0x4000,
                          len(instructions), text_offset, 2, 0, 0, 0x80000400, 0, 0, 0)
    return header + segment + section + instructions


class PACRegression(unittest.TestCase):
    def test_real_fault_pattern_rejects_double_sign(self):
        # CI PXCloneClassResponds+0x10 from UUID e53a1dc3... .
        result = PAC.scan_text(words(0xD503237F, 0xD503237F, 0xA9BF7BFD), 0xC238)
        self.assertEqual(result["issues"][0],
                         {"kind": "double-sign", "address": "0xc238", "next": "0xc23c"})

    def test_real_fault_pattern_rejects_double_auth(self):
        result = PAC.scan_text(words(0xD50323FF, 0xD50323FF, 0x12000000, 0xD65F03C0))
        self.assertEqual(result["issues"][0]["kind"], "double-authenticate")

    def test_rejects_auth_then_authenticating_return(self):
        result = PAC.scan_text(words(0xD50323FF, 0xD65F0FFF))
        self.assertEqual(result["issues"][0]["kind"], "double-authenticate")

    def test_nop_cannot_hide_duplicate(self):
        self.assertTrue(PAC.scan_text(words(0xD503237F, 0xD503201F, 0xD503237F))["issues"])

    def test_bti_cannot_hide_duplicate(self):
        self.assertTrue(PAC.scan_text(words(0xD503237F, 0xD503245F, 0xD503237F))["issues"])

    def test_standard_arm64e_return_passes(self):
        result = PAC.scan_text(words(0xD503237F, 0xA9BF7BFD, 0xA8C17BFD, 0xD65F0FFF))
        self.assertEqual(result["issues"], [])
        self.assertEqual(result["signs"], 1)

    def test_standard_tail_call_auth_passes(self):
        result = PAC.scan_text(words(0xD503237F, 0xA9BF7BFD, 0xA8C17BFD,
                                     0xD50323FF, 0x14000001))
        self.assertEqual(result["issues"], [])

    def test_thin_macho_uses_text_section_and_subtype(self):
        with tempfile.NamedTemporaryFile() as fixture:
            fixture.write(thin_fixture(words(0xD503237F, 0xA9BF7BFD, 0xD65F0FFF)))
            fixture.flush()
            self.assertEqual(PAC.inspect(fixture.name, "arm64e")[0]["issues"], [])
            with self.assertRaises(ValueError):
                PAC.inspect(fixture.name, "arm64")

    def test_arm64e_label_without_pac_is_rejected(self):
        with tempfile.NamedTemporaryFile() as fixture:
            fixture.write(thin_fixture(words(0xD65F03C0)))
            fixture.flush()
            result = PAC.inspect(fixture.name, "arm64e")[0]
            self.assertEqual(result["issues"][0]["kind"], "arm64e-without-return-pac")

    def test_old_crash_sequence_in_macho_is_rejected(self):
        with tempfile.NamedTemporaryFile() as fixture:
            fixture.write(thin_fixture(words(0xD503237F, 0xD503237F, 0xD50323FF, 0xD65F0FFF)))
            fixture.flush()
            self.assertEqual(len(PAC.inspect(fixture.name)[0]["issues"]), 2)

    def test_invalid_image_fails_closed(self):
        with tempfile.NamedTemporaryFile() as fixture:
            fixture.write(b"not a Mach-O")
            fixture.flush()
            with self.assertRaises(ValueError):
                PAC.inspect(fixture.name)


class StartupRegression(unittest.TestCase):
    def test_apple_build_has_no_generic_return_signing_flags(self):
        make = (ROOT / "Makefile").read_text()
        self.assertNotIn("-mbranch-protection", make)
        self.assertNotIn("-fptrauth-calls", make)
        self.assertNotIn("-fuse-ld", make)
        self.assertIn("Darwin", make)

    def test_local_ptrauth_stub_cannot_shadow_apple_header(self):
        self.assertFalse((ROOT / "ptrauth.h").exists())

    def test_constructor_only_enqueues_bootstrap(self):
        source = (ROOT / "Tweak.xm").read_text()
        ctor = source.split("%ctor {", 1)[1].split("%dtor", 1)[0]
        self.assertNotIn("prepareManager", ctor)
        self.assertNotIn("PXClonePrefs.shared", ctor)
        self.assertIn("dispatch_async(dispatch_get_main_queue()", ctor)
        self.assertIn("PXBootstrap(0)", ctor)

    def test_retry_no_longer_schedules_weak_recursive_block(self):
        source = (ROOT / "Tweak.xm").read_text()
        self.assertNotIn("weakInstall", source)
        self.assertIn("PXBootstrap(attempt + 1)", source)
        self.assertIn("attempt >= 25", source)

    def test_paths_use_the_official_overload_not_cast_c_function(self):
        compat = (ROOT / "Common/PXRootHideCompat.h").read_text()
        self.assertIn("#import <roothide.h>", compat)
        self.assertIn("return jbroot(path);", compat)
        self.assertIn("return rootfs(path);", compat)
        self.assertNotIn("dlsym", compat)
        self.assertNotIn("PXClonePathFn", compat)


if __name__ == "__main__":
    unittest.main()
